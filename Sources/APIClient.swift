//
//  APIClient.swift
//  虚拟身体（VirtualBody）
//
//  职责：与远端「虚现互通」服务通信的最小网络层（见 docs/PROTOCOL.md）。
//  只实现原生壳需要的四个接口：
//    GET  /api/hello   探活（免鉴权）
//    POST /api/bind    绑定码换 token（免鉴权）
//    GET  /api/state   token 校验 / 全量快照（Bearer）
//    POST /api/unbind  主动解绑（Bearer）
//  统一响应信封 {ok, data, error, message}；所有失败统一收敛成 APIError，
//  并附带一段可直接上屏的中文文案（userMessage）。
//

import Foundation

// MARK: - 错误

enum APIError: Error, LocalizedError {
    case badURL
    case transport(String)                  // 连不上 / 超时 / 被拒
    case decode(String)                     // 响应不是预期结构
    case server(code: String, message: String?)   // ok:false，或 HTTP 级错误

    /// 服务端语义错误码：bad_code / expired / rate_limited / unbound …
    var serverCode: String? {
        if case .server(let code, _) = self { return code }
        return nil
    }

    /// token 失效 → 调用方应清 token 回门禁页
    var isUnauthorized: Bool {
        guard let code = serverCode else { return false }
        return code == "unbound" || code == "unauthorized"
    }

    /// 给用户看的中文文案
    var userMessage: String {
        switch self {
        case .badURL:
            return "服务器地址不合法，请检查地址"
        case .transport:
            return "连不上服务器，请检查地址"
        case .decode:
            return "服务器返回的数据看不懂，请检查服务器版本"
        case .server(let code, let message):
            switch code {
            case "bad_code":
                return "绑定码错误或已过期"
            case "expired":
                return "绑定码已过期，请在 QQ 里重新发送「虚现 绑定码」"
            case "rate_limited":
                return "操作太频繁了，请稍后再试"
            case "unbound":
                return "登录已失效，请重新绑定"
            default:
                let text = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? "服务器返回错误：\(code)" : text
            }
        }
    }

    /// 排查用（日志里输出，不上屏）
    var debugDetail: String {
        switch self {
        case .badURL:                 return "badURL"
        case .transport(let detail):  return "transport: \(detail)"
        case .decode(let detail):     return "decode: \(detail)"
        case .server(let code, let message):
            return "server[\(code)]: \(message ?? "-")"
        }
    }

    var errorDescription: String? { userMessage }
}

extension Error {
    /// 统一的“给用户看”的中文文案
    var vbUserMessage: String {
        (self as? APIError)?.userMessage ?? localizedDescription
    }
}

// MARK: - 响应模型

/// 统一信封
struct VBEnvelope<T: Decodable>: Decodable {
    let ok: Bool
    let data: T?
    let error: String?
    let message: String?
}

/// GET /api/hello
struct VBHello: Decodable {
    let service: String?
    let version: String?
    let bound: Bool?
    let serverTime: Int?

    enum CodingKeys: String, CodingKey {
        case service, version, bound
        case serverTime = "server_time"
    }
}

/// POST /api/bind（成功分支的 data）
struct VBBind: Decodable {
    let token: String
    let qq: String
    let nickname: String?
    let character: VBCharacter?
}

/// GET /api/state（data）
struct VBState: Decodable {
    let bound: Bool?
    let muted: Bool?
    let serverTime: Int?
    let character: VBCharacter?

    enum CodingKeys: String, CodingKey {
        case bound, muted, character
        case serverTime = "server_time"
    }
}

/// 角色状态对象（只声明外壳真正会读到的字段，其余忽略；全部可选，抗服务端演进）
struct VBCharacter: Decodable, Identifiable {
    let id: String?
    let name: String?
    let ownerQQ: String?
    let level: Int?
    let exp: Int?
    let expNext: Int?
    let emotion: String?
    let action: String?
    let bubble: String?
    let outfit: String?
    let room: String?
    let muted: Bool?
    let stats: VBStats?

    enum CodingKeys: String, CodingKey {
        case id, name, level, exp, emotion, action, bubble, outfit, room, muted, stats
        case ownerQQ = "owner_qq"
        case expNext = "exp_next"
    }
}

struct VBStats: Decodable {
    let affection: Int?
    let mood: Int?
    let energy: Int?
    let satiety: Int?
    let clean: Int?
    let trust: Int?
}

// MARK: - 客户端

final class APIClient: @unchecked Sendable {

    /// 规整服务器地址：去空白、去结尾斜杠、缺 scheme 时补 https。
    static func normalize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = AppConfig.defaultServer }
        let lower = text.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            text = "https://" + text
        }
        // 去掉结尾斜杠，但别把 "https://" 剥成 "https:"（剥空 scheme 会变成非法 URL）
        while text.hasSuffix("/") && !text.hasSuffix("://") {
            text.removeLast()
        }
        return text
    }

    let base: String
    private let token: String?
    private let session: URLSession

    init(base: String, token: String? = nil) throws {
        let normalized = APIClient.normalize(base)
        guard let probe = URL(string: normalized + "/api/hello"), probe.host != nil else {
            throw APIError.badURL
        }
        self.base = normalized
        let trimmedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.token = trimmedToken.isEmpty ? nil : trimmedToken

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    // MARK: 接口

    func hello() async throws -> VBHello {
        try await call(path: "/api/hello", method: "GET", body: nil, auth: false)
    }

    func bind(code: String, device: String) async throws -> VBBind {
        let payload: [String: Any] = [
            "code": code,
            "device": device,
            "platform": AppConfig.platform,
            "app_version": AppConfig.appVersion
        ]
        return try await call(path: "/api/bind", method: "POST", body: payload, auth: false)
    }

    func state() async throws -> VBState {
        try await call(path: "/api/state", method: "GET", body: nil, auth: true)
    }

    /// 主动解绑：作废 token。失败不抛（本地照样清干净），只打日志。
    func unbind() async {
        do {
            let data = try await send(path: "/api/unbind", method: "POST", body: nil, auth: true)
            if let text = String(data: data, encoding: .utf8) {
                print("[VB api] unbind <- \(text.prefix(200))")
            }
        } catch {
            print("[VB api] unbind failed: \(error.vbUserMessage)")
        }
    }

    // MARK: 内部

    private struct Empty: Decodable {}

    private func call<T: Decodable>(path: String, method: String, body: [String: Any]?, auth: Bool) async throws -> T {
        let data = try await send(path: path, method: method, body: body, auth: auth)
        do {
            let envelope = try JSONDecoder().decode(VBEnvelope<T>.self, from: data)
            if envelope.ok, let payload = envelope.data {
                return payload
            }
            if envelope.ok {
                throw APIError.decode("envelope ok but data missing (\(path))")
            }
            throw APIError.server(code: envelope.error ?? "unknown", message: envelope.message)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.decode(String(describing: error))
        }
    }

    private func send(path: String, method: String, body: [String: Any]?, auth: Bool) async throws -> Data {
        guard let url = URL(string: base + path) else { throw APIError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("VirtualBody-iOS/\(AppConfig.appVersion)", forHTTPHeaderField: "User-Agent")
        if auth, let token = token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body = body {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
            } catch {
                throw APIError.decode("request body encode failed")
            }
        }

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 401 {
                    // 协议 §1：401 即 unbound
                    throw APIError.server(code: "unbound", message: nil)
                }
                if !(200...299).contains(http.statusCode) {
                    if let envelope = try? JSONDecoder().decode(VBEnvelope<Empty>.self, from: data),
                       let code = envelope.error {
                        throw APIError.server(code: code, message: envelope.message)
                    }
                    throw APIError.server(code: "http_\(http.statusCode)",
                                          message: "服务器返回 HTTP \(http.statusCode)")
                }
            }
            return data
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.transport(String(describing: error))
        }
    }
}
