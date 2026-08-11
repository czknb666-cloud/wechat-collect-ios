import Foundation
import AVFoundation
import Speech
import UIKit
import UserNotifications

/// 检测记录：一次成功识别出的微信到账播报
struct Detection: Identifiable, Codable {
    var id = UUID()
    var amount: Double
    var text: String
    var at: Date = Date()
    var uploaded: Bool = false
    var verified: Bool? = nil      // nil=未核销  true/false=已核销结果
    var verifyNote: String = ""

    func amountText() -> String {
        return String(format: "¥%.2f", amount)
    }
}

/// 核心引擎：后台音频保活 + 麦克风采集 + 语音识别「微信收款到账播报」
final class MonitorEngine: NSObject, ObservableObject {
    static let shared = MonitorEngine()

    // UI 状态
    @Published var isRunning = false
    @Published var authMic: Bool = false
    @Published var authSpeech: Bool = false
    @Published var lastDetected: Detection?
    @Published var detections: [Detection] = []
    @Published var statusText = "未监听"
    @Published var debugLog: [String] = []

    private var audioEngine: AVAudioEngine?
    private var recRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recTask: SFSpeechRecognitionTask?
    private var silencePlayer: AVAudioPlayer?
    private var watchdog: Timer?
    private var sessionActive = false

    // 去重：同一金额 45 秒内只算一笔
    private var dedupAmount: Double = 0
    private var dedupAt: TimeInterval = 0
    private var pendingCache: String = ""

    private var saved: [Detection] {
        get { (try? JSONDecoder().decode([Detection].self, from: UserDefaults.standard.data(forKey: "detections") ?? Data())) ?? [] }
        set { if let d = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(d, forKey: "detections") } }
    }

    private override init() {
        super.init()
        detections = saved
        addLog("引擎初始化")
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resumeFromRouteChange), name: AVAudioSession.routeChangeNotification, object: nil)
    }

    // MARK: - 权限

    func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] ok in
            DispatchQueue.main.async { self?.authMic = ok }
        }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async { self?.authSpeech = (status == .authorized) }
        }
    }

    // MARK: - 启动 / 停止

    @discardableResult
    func start() -> Bool {
        stop()
        requestPermissions()

        do {
            let session = AVAudioSession.sharedInstance()
            // playAndRecord：后台音频（静音占位）+ 麦克风采集共存；measurement 模式排除回声消除干扰
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker])
            try session.setActive(true, options: [])
            sessionActive = true
        } catch {
            addLog("音频会话失败: \(error.localizedDescription)")
            statusText = "音频会话失败"
            return false
        }

        startSilenceLoop()

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), recognizer.isAvailable else {
            addLog("语音识别不可用")
            statusText = "语音识别不可用"
            return false
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        recRequest = req

        recTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                self.processTranscript(result.bestTranscription.formattedString, final: result.isFinal)
            }
            if error != nil {
                self.addLog("识别错误: \(error!.localizedDescription)")
                // 自动重启识别循环
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if self.isRunning { self.start() }
                }
            }
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1536, format: format) { [weak self] buffer, _ in
            self?.recRequest?.append(buffer)
        }
        do {
            try engine.start()
        } catch {
            addLog("引擎启动失败: \(error.localizedDescription)")
            return false
        }
        audioEngine = engine
        isRunning = true
        statusText = "监听中 · 等待到账播报"
        addLog("开始监听")
        startWatchdog()
        return true
    }

    func stop() {
        isRunning = false
        statusText = "已停止"
        watchdog?.invalidate(); watchdog = nil
        recTask?.cancel(); recTask = nil
        recRequest?.endAudio(); recRequest = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        stopSilenceLoop()
        pendingCache = ""
        addLog("已停止监听")
    }

    // MARK: - 语音解析

    /// 微信到账播报文案（收款方手机 微信→收款小账本 播报）：
    /// 「微信支付收款 12.00 元」「收款到账 0.50 元」「你的收款到账 100.00 元」等
    private func processTranscript(_ text: String, final: Bool) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if final { pendingCache = "" }
        var buf = pendingCache + t
        if buf.count > 80 { buf = String(buf.suffix(80)) }
        pendingCache = buf

        guard let amount = parseAmount(buf) else { return }
        let now = Date().timeIntervalSince1970
        if abs(amount - dedupAmount) < 0.001 && now - dedupAt < 45 { return }

        dedupAmount = amount
        dedupAt = now

        let det = Detection(amount: amount, text: t)
        detections.insert(det, at: 0)
        if detections.count > 50 { detections.removeLast(detections.count - 50) }
        saved = detections
        lastDetected = det

        statusText = "已检测到收款 \(det.amountText())"
        addLog("检测到收款 \(det.amountText())：\(t)")
        notify(det)
        upload(det)
    }

    /// 兼容常见播报句式：X（元）前有 到账/收款
    private func parseAmount(_ text: String) -> Double? {
        let patterns = [
            #"收款到账[^\d]*([0-9]+(?:\.[0-9]{1,2})?)\s*元"#,
            #"到账[^\d]*([0-9]+(?:\.[0-9]{1,2})?)\s*元"#,
            #"收款[^\d]*([0-9]+(?:\.[0-9]{1,2})?)\s*元"#,
            #"收到[^\d]*([0-9]+(?:\.[0-9]{1,2})?)\s*元"#,
            #"微信支付收款[^\d]*([0-9]+(?:\.[0-9]{1,2})?)\s*元"#,
        ]
        for p in patterns {
            if let range = text.range(of: p, options: .regularExpression) {
                let sub = String(text[range])
                let amountPattern = #"[0-9]+(?:\.[0-9]{1,2})?"#
                if let aRange = sub.range(of: amountPattern, options: .regularExpression) {
                    if let v = Double(String(sub[aRange])) { return v }
                }
            }
        }
        return nil
    }

    // MARK: - 上报 + 通知

    private func upload(_ det: Detection) {
        guard !APIClient.shared.token.isEmpty else {
            addLog("未绑定账号，跳过上报")
            return
        }
        Task {
            do {
                try await APIClient.shared.reportDetect(amount: det.amount)
                if let idx = detections.firstIndex(where: { $0.id == det.id }) {
                    detections[idx].uploaded = true
                    saved = detections
                }
                addLog("已上报 \(det.amountText())")
            } catch {
                addLog("上报失败: \(error.localizedDescription)")
            }
        }
    }

    private func notify(_ det: Detection) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "检测到微信收款"
        content.body = "到账 \(det.amountText())"
        content.sound = .default
        content.badge = 1
        let req = UNNotificationRequest(identifier: det.id.uuidString, content: content, trigger: nil)
        center.add(req)
    }

    // MARK: - 后台保活

    /// 无声 WAV（1秒 16bit 44.1kHz 单声道）循环播放，激活后台音频模式
    private func startSilenceLoop() {
        guard let data = Self.zerosWav() else { return }
        do {
            let p = try AVAudioPlayer(data: data)
            p.numberOfLoops = -1
            p.volume = 0.0
            p.prepareToPlay()
            p.play()
            silencePlayer = p
        } catch {
            addLog("静音保活启动失败: \(error.localizedDescription)")
        }
    }

    private func stopSilenceLoop() {
        silencePlayer?.stop()
        silencePlayer = nil
    }

    private func startWatchdog() {
        let w = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if !(self.silencePlayer?.isPlaying ?? false) { self.startSilenceLoop() }
            if !(self.audioEngine?.isRunning ?? false) {
                // 音频引擎中断后尝试热重启
                try? self.audioEngine?.start()
            }
        }
        RunLoop.main.add(w, forMode: .common)
        watchdog = w
    }

    func keepAliveInBackground() {
        // 后台时保持音频会话 + 静音循环
        if isRunning {
            try? AVAudioSession.sharedInstance().setActive(true, options: [])
            if !(silencePlayer?.isPlaying ?? false) { startSilenceLoop() }
        }
    }

    func refreshOnForeground() {
        // 回前台或系统唤醒：重新激活会话并补认
        if isRunning {
            stop()
            start()
        }
    }

    @objc private func handleInterruption(_ n: Notification) {
        guard let info = n.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .ended {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.refreshOnForeground()
            }
        }
    }

    @objc private func resumeFromRouteChange() {
        if isRunning {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.refreshOnForeground()
            }
        }
    }

    // MARK: - 历史

    func history() -> [Detection] { detections }

    func markVerified(_ id: UUID, ok: Bool, note: String) {
        if let idx = detections.firstIndex(where: { $0.id == id }) {
            detections[idx].verified = ok
            detections[idx].verifyNote = note
            saved = detections
        }
    }

    func clearHistory() {
        detections.removeAll()
        saved = []
        lastDetected = nil
    }

    // MARK: - 工具

    private func addLog(_ s: String) {
        let line = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium) + " " + s
        debugLog.insert(line, at: 0)
        if debugLog.count > 60 { debugLog.removeLast(debugLog.count - 60) }
    }

    /// 生成 1 秒静音 WAV
    private static func zerosWav() -> Data? {
        let sampleRate = 44100
        let duration = 1
        let dataLen = sampleRate * duration * 2 // 16bit mono
        var data = Data()
        func w(_ s: String) { data.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { var v = v; data.append(Data(bytes: &v, count: 4)) }
        func u16(_ v: UInt16) { var v = v; data.append(Data(bytes: &v, count: 2)) }
        w("RIFF"); u32(UInt32(36 + dataLen)); w("WAVE")
        w("fmt "); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        w("data"); u32(UInt32(dataLen))
        data.append(Data(repeating: 0, count: dataLen))
        return data
    }
}