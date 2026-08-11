import SwiftUI

struct ContentView: View {
    @StateObject private var engine = MonitorEngine.shared
    @State private var bindSheet = false
    @State private var verifySerial: Detection? = nil

    var body: some View {
        NavigationView {
            List {
                statusSection
                guideSection
                bindSection
                historySection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("微信收款监控")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(engine.isRunning ? "停止" : "开始监听") {
                        toggleRun()
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: 状态

    private var statusSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Circle()
                        .fill(engine.isRunning ? Color.green : Color.gray)
                        .frame(width: 14, height: 14)
                    Text(engine.statusText)
                        .font(.body)
                }
                if let d = engine.lastDetected {
                    HStack {
                        Image(systemName: "yensign.circle.fill")
                            .foregroundColor(.orange)
                        Text("最近到账 " + d.amountText())
                            .font(.title3.bold())
                        Text(d.at, style: .time)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                HStack {
                    Label(engine.authMic ? "麦克风已授权" : "麦克风未授权", systemImage: engine.authMic ? "mic.fill" : "mic.slash.fill")
                    Spacer()
                    Label(engine.authSpeech ? "语音识别已授权" : "语音识别未授权", systemImage: engine.authSpeech ? "waveform" : "waveform.slash")
                }
                .font(.caption)
                .foregroundColor(.secondary)

                Button {
                    toggleRun()
                } label: {
                    Text(engine.isRunning ? "暂停监听" : "开始监听")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(engine.isRunning ? .orange : .green)

                Text("请在微信开启「收款到账语音提醒」，保持本 App 在前台启动一次后即可锁屏/后台运行；建议连接电源。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        } header: {
            Text("监听状态")
        }
    }

    // MARK: 引导

    private var guideSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                GuideRow(step: 1, text: "微信 → 我 → 服务 → 收付款 → 二维码收款，进入「收款小账本」")
                GuideRow(step: 2, text: "开启「收款到账语音提醒」（或 设置→通用→辅助功能→收款到账语音提醒）")
                GuideRow(step: 3, text: "付款方扫码付款后，微信会语音播报「微信支付收款 XX 元」")
                GuideRow(step: 4, text: "本 App 后台监听识别该播报 → 本地通知 + 自动上报网站")
                GuideRow(step: 5, text: "到 App「检测记录」粘贴付款方提交的付款单号 → 自动核销充值单")
            }
        } header: {
            Text("使用步骤")
        }
    }

    // MARK: 绑定

    private var bindSection: some View {
        Section {
            if APIClient.shared.token.isEmpty {
                HStack {
                    Text("未绑定账号")
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("绑定") { bindSheet = true }
                }
            } else {
                HStack {
                    Label("已绑定：" + APIClient.shared.boundNickname, systemImage: "checkmark.seal.fill")
                        .foregroundColor(.green)
                    Spacer()
                    Button("解绑") {
                        APIClient.shared.token = ""
                        APIClient.shared.boundNickname = ""
                    }
                    .foregroundColor(.red)
                }
                HStack {
                    Text("服务器")
                    Spacer()
                    TextField("https://ai-hub-6qn.pages.dev", text: Binding(
                        get: { APIClient.shared.baseURL },
                        set: { APIClient.shared.baseURL = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    ))
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                }
                Text("绑定码在网站「个人主页 → 收款监控 App 绑定」生成，10 分钟有效，每码仅用一次。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("账号绑定")
        }
        .sheet(isPresented: $bindSheet) {
            BindSheet()
        }
    }

    // MARK: 检测历史

    private var historySection: some View {
        Section {
            if engine.detections.isEmpty {
                Text("暂无检测记录，启动监听后自动生成")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                ForEach(engine.detections) { d in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(d.amountText())
                                .font(.headline)
                                .foregroundColor(.orange)
                            if d.uploaded { Label("已上报", systemImage: "icloud.and.arrow.up").font(.caption2).foregroundColor(.secondary) }
                            Spacer()
                            Text(d.at, style: .time).font(.caption).foregroundColor(.secondary)
                        }
                        if let v = d.verified {
                            Text(v ? "已核销" : "核销失败：" + d.verifyNote)
                                .font(.caption)
                                .foregroundColor(v ? .green : .red)
                        } else {
                            Button("用付款单号核销") { verifySerial = d }
                                .font(.caption)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Button("清空记录", role: .destructive) { engine.clearHistory() }
            }
        } header: {
            Text("检测记录（最近 \(engine.detections.count) 笔）")
        }
        .sheet(item: $verifySerial) { d in
            VerifySheet(detection: d)
        }
    }

    // MARK: 关于

    private var aboutSection: some View {
        Section {
            NavigationLink("运行日志") {
                LogView()
            }
            Text("自签应用，7 天签名需重新安装；请勿用于违法违规用途。检测成功率取决于微信语音播报与手机音量。")
                .font(.caption2)
                .foregroundColor(.secondary)
        } header: {
            Text("关于")
        }
    }

    private func toggleRun() {
        if engine.isRunning {
            engine.stop()
        } else {
            engine.requestPermissions()
            _ = engine.start()
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }
}

// MARK: - 引导行

struct GuideRow: View {
    let step: Int
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(step)").font(.caption.bold())
                .foregroundColor(.white).frame(width: 20, height: 20).background(Circle().fill(Color.blue))
            Text(text).font(.footnote)
        }
    }
}

// MARK: - 绑定弹窗

struct BindSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var busy = false
    @State private var errorText = ""

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("6 位绑定码", text: $code)
                        .keyboardType(.numberPad)
                } footer: {
                    Text(errorText)
                        .foregroundColor(.red)
                }
            }
            .navigationTitle("绑定账号")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("绑定") {
                        busy = true
                        Task {
                            do {
                                let r = try await APIClient.shared.bind(code: code.trimmingCharacters(in: .whitespaces))
                                APIClient.shared.token = r.token
                                APIClient.shared.boundNickname = r.user.nickname
                                dismiss()
                            } catch {
                                errorText = error.localizedDescription
                            }
                            busy = false
                        }
                    }
                    .disabled(busy || code.count != 6)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - 核销弹窗

struct VerifySheet: View {
    let detection: Detection
    @Environment(\.dismiss) private var dismiss
    @State private var serial = ""
    @State private var busy = false
    @State private var resultText = ""
    @State private var resultColor = Color.secondary
    @State private var done = false

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack {
                        Text("检测金额")
                        Spacer()
                        Text(detection.amountText()).bold().foregroundColor(.orange)
                    }
                    TextField("微信付款单号 / 商户单号", text: $serial)
                        .autocorrectionDisabled()
                } footer: {
                    if !resultText.isEmpty {
                        Text(resultText).foregroundColor(resultColor)
                    }
                }
                if !done {
                    Section {
                        Button("提交核销") {
                            busy = true
                            Task {
                                do {
                                    let r = try await APIClient.shared.verify(serial: serial.trimmingCharacters(in: .whitespaces))
                                    resultText = r.note ?? (r.approved == true ? "已自动到账" : "核验通过，等待开发者确认")
                                    resultColor = .green
                                    MonitorEngine.shared.markVerified(detection.id, ok: true, note: resultText)
                                } catch {
                                    resultText = error.localizedDescription
                                    resultColor = .red
                                    MonitorEngine.shared.markVerified(detection.id, ok: false, note: resultText)
                                }
                                busy = false
                                done = true
                            }
                        }
                        .disabled(busy || serial.count < 6)
                    }
                }
            }
            .navigationTitle("单号核销")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - 日志

struct LogView: View {
    @StateObject private var engine = MonitorEngine.shared
    var body: some View {
        List {
            ForEach(Array(engine.debugLog.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(.caption, design: .monospaced))
            }
        }
        .navigationTitle("运行日志")
    }
}