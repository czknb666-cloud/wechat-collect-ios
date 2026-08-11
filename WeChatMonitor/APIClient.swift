import Foundation
import UIKit

/// 与 AI Hub 站点对接的 API 客户端
final class APIClient {
    static let shared = APIClient()

    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct BindResponse: Decodable {
        let token: String
        let user: BindUser
        struct BindUser: Decodable { let nickname: String; let email: String }
    }

    struct VerifyResponse: Decodable {
        let matched: Bool
        let approved: Bool?
        let note: String?
        let amount: Double?
        let recordId: String?
        let earned: Int?
        let bonusChats: Int?
    }

    struct ProfileResponse: Decodable {
        let user: ProfileUser?
        struct ProfileUser: Decodable { let nickname: String?; let email: String? }
    }

    // MARK: - 配置

    var baseURL: String {
        get { UserDefaults.standard.string(forKey: "apiBase") ?? "https://ai-hub-6qn.pages.dev" }
        set { UserDefaults.standard.set(newValue, forKey: "apiBase") }
    }

    var token: String {
        get { UserDefaults.standard.string(forKey: "appToken") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "appToken") }
    }

    var boundNickname: String {
        get { UserDefaults.standard.string(forKey: "boundNickname") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "boundNickname") }
    }

    // MARK: - 请求

    private func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil, auth: Bool = false, as type: T.Type) async throws -> T {
        guard let url = URL(string: baseURL + path) else { throw APIError(message: "服务器地址无效") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if auth && !token.isEmpty {
            req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError(message: "网络异常") }
        if !(200...299).contains(http.statusCode) {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])??["message"] as? String ?? "请求失败（HTTP \(http.statusCode)）"
            throw APIError(message: msg)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError(message: "响应解析失败")
        }
    }

    // MARK: - 接口

    /// 绑定码换长期令牌
    func bind(code: String) async throws -> BindResponse {
        try await request("/app/bind", method: "POST", body: [
            "code": code,
            "deviceName": UIDevice.current.name,
        ], as: BindResponse.self)
    }

    /// 上报检测到的收款金额
    func reportDetect(amount: Double) async throws {
        struct R: Decodable { let ok: Bool }
        _ = try await request("/recharge/detect", method: "POST", body: ["amount": amount, "source": "voice"], auth: true, as: R.self)
    }

    /// 用微信支付单号核销待审核充值单
    func verify(serial: String) async throws -> VerifyResponse {
        try await request("/recharge/verify", method: "POST", body: ["serial": serial], auth: true, as: VerifyResponse.self)
    }

    /// 校验当前令牌有效性
    func profile() async throws -> ProfileResponse {
        try await request("/user/profile", method: "GET", auth: true, as: ProfileResponse.self)
    }
}