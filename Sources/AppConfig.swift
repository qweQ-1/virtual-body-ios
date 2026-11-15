//
//  AppConfig.swift
//  虚拟身体（VirtualBody）
//
//  职责：
//  1) 全局常量：服务器基址、App 版本、平台标识、UserDefaults / Keychain 键名；
//  2) UserDefaults 持久化：服务器地址、设备名、Q 号、昵称、语音开关、触觉开关；
//  3) AppState：全局状态机 —— 启动探活（hello → state）、绑定成功、解绑清理、路由切换。
//
//  约定：所有对 @Published 的写入都在主线程完成（视图动作、Task { @MainActor in }、
//  或本文件内显式的 MainActor.run）。AppState 声明为 @unchecked Sendable 是自觉承诺：
//  跨线程使用时由调用方把写入切回主线程。
//

import Foundation
import Combine
import UIKit

// MARK: - 常量

enum AppConfig {

    /// 生产基址（见 docs/PROTOCOL.md §0），不带结尾斜杠
    static let defaultServer = "https://samachat.de5.net/pet"

    /// 必须与 project.yml 的 MARKETING_VERSION 保持一致
    static let appVersion: String = "2.0.0"

    /// 平台标识（/api/bind 请求体的 platform 字段）
    static let platform = "ios"

    enum Key {
        static let server     = "vb.server"
        static let deviceName = "vb.deviceName"
        static let qq         = "vb.qq"
        static let nickname   = "vb.nickname"
        static let speech     = "vb.speechEnabled"
        static let haptics    = "vb.hapticsEnabled"
    }

    /// 默认设备名：本机名称（如 “iPhone 15”），取不到就退回 "iPhone"
    static var defaultDeviceName: String {
        let name = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "iPhone" : String(name.prefix(40))
    }

    /// 展示用版本号：优先取 bundle 里的 CFBundleShortVersionString
    static var bundleVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? appVersion
    }

    static var bundleBuild: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
    }

    /// 语音朗读开关（未设置过默认开）
    static var speechEnabled: Bool {
        UserDefaults.standard.object(forKey: Key.speech) as? Bool ?? true
    }

    /// 触觉开关（未设置过默认开）；Haptics 每次触发时读取它
    static var hapticsEnabled: Bool {
        UserDefaults.standard.object(forKey: Key.haptics) as? Bool ?? true
    }
}

// MARK: - 全局状态

final class AppState: ObservableObject, @unchecked Sendable {

    enum Route {
        case loading    // 启动探活中
        case entry      // 绑定门禁页
        case main       // 主界面（WKWebView）
    }

    // 路由与身份
    @Published private(set) var route: Route = .loading
    @Published private(set) var token: String?
    @Published private(set) var qq: String = ""
    @Published private(set) var nickname: String = ""

    // 可编辑配置（写入即落 UserDefaults）
    @Published var serverBase: String {
        didSet { UserDefaults.standard.set(serverBase, forKey: AppConfig.Key.server) }
    }
    @Published var deviceName: String {
        didSet { UserDefaults.standard.set(deviceName, forKey: AppConfig.Key.deviceName) }
    }
    @Published var speechEnabled: Bool {
        didSet { UserDefaults.standard.set(speechEnabled, forKey: AppConfig.Key.speech) }
    }
    @Published var hapticsEnabled: Bool {
        didSet { UserDefaults.standard.set(hapticsEnabled, forKey: AppConfig.Key.haptics) }
    }

    /// 连接状态浮层内容（设置页也读它）
    @Published private(set) var statusText: String = "未连接"
    @Published private(set) var statusLevel: String = "warn"   // ok | warn | error
    /// 前端是否主动上报过状态；上报过就不再被原生的“页面已加载”覆盖
    @Published private(set) var statusFromWeb: Bool = false

    /// 门禁页顶部一次性提示（解绑、改地址、token 失效等）
    @Published var notice: String?

    private var didBootstrap = false

    // MARK: 初始化

    init() {
        let defaults = UserDefaults.standard

        let savedServer = (defaults.string(forKey: AppConfig.Key.server) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.serverBase = APIClient.normalize(savedServer.isEmpty ? AppConfig.defaultServer : savedServer)

        let savedDevice = (defaults.string(forKey: AppConfig.Key.deviceName) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.deviceName = savedDevice.isEmpty ? AppConfig.defaultDeviceName : savedDevice

        self.qq = defaults.string(forKey: AppConfig.Key.qq) ?? ""
        self.nickname = defaults.string(forKey: AppConfig.Key.nickname) ?? ""
        self.speechEnabled = defaults.object(forKey: AppConfig.Key.speech) as? Bool ?? true
        self.hapticsEnabled = defaults.object(forKey: AppConfig.Key.haptics) as? Bool ?? true

        let storedToken = Keychain.load() ?? ""
        self.token = storedToken.isEmpty ? nil : storedToken
    }

    var isBound: Bool {
        !((token ?? "").isEmpty)
    }

    // MARK: 启动流程

    /// 启动：有 token 就先 hello 探活，再 state 校验；unbound 清 token 回门禁页。
    /// 网络不通时仍然进入主界面（交给 WebView 的原生错误页 + 重试 + 设置里改地址）。
    func bootstrap() async {
        if didBootstrap { return }
        didBootstrap = true

        guard let token = token, !token.isEmpty else {
            await MainActor.run { self.route = .entry }
            return
        }
        guard let client = try? APIClient(base: serverBase, token: token) else {
            await MainActor.run { self.route = .entry }
            return
        }

        do {
            _ = try await client.hello()
        } catch {
            await MainActor.run {
                self.setStatus(text: "连不上服务器，请检查地址", level: "error", fromWeb: false)
                self.route = .main
            }
            return
        }

        do {
            let snapshot = try await client.state()
            if snapshot.bound == false {
                await MainActor.run {
                    self.clearBinding(notice: "服务端说这台设备已经解绑了，请重新绑定。", clearProfile: false)
                }
            } else {
                await MainActor.run {
                    if let character = snapshot.character {
                        if let name = character.name, !name.isEmpty { self.nickname = name }
                        if let owner = character.ownerQQ, !owner.isEmpty { self.qq = owner }
                    }
                    self.route = .main
                }
            }
        } catch let error as APIError where error.isUnauthorized {
            await MainActor.run {
                self.clearBinding(notice: "登录已失效，请在 QQ 里发送「虚现 绑定码」重新绑定。", clearProfile: false)
            }
        } catch {
            await MainActor.run { self.route = .main }
        }
    }

    // MARK: 绑定结果

    /// 绑定成功：token 进 Keychain，身份信息进 UserDefaults，进主界面。
    func completeBind(server: String, token: String, qq: String, nickname: String, deviceName: String) {
        let normalized = APIClient.normalize(server)
        self.serverBase = normalized
        self.deviceName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AppConfig.defaultDeviceName
            : deviceName
        self.token = token
        self.qq = qq
        self.nickname = nickname

        _ = Keychain.save(token)
        UserDefaults.standard.set(qq, forKey: AppConfig.Key.qq)
        UserDefaults.standard.set(nickname, forKey: AppConfig.Key.nickname)

        self.notice = nil
        self.statusFromWeb = false
        self.setStatus(text: "已绑定，正在连接…", level: "warn", fromWeb: false)
        self.route = .main
    }

    /// 清掉登录态回门禁页（unbound / 解绑 / 换服务器 / token 失效都走这里）。
    /// clearProfile=false 时保留 QQ 号与昵称，方便门禁页/设置页展示“上次绑定的是谁”。
    func clearBinding(notice: String?, clearProfile: Bool = false) {
        _ = Keychain.delete()
        self.token = nil
        if clearProfile {
            self.qq = ""
            self.nickname = ""
            UserDefaults.standard.removeObject(forKey: AppConfig.Key.qq)
            UserDefaults.standard.removeObject(forKey: AppConfig.Key.nickname)
        }
        self.notice = notice
        self.statusFromWeb = false
        self.setStatus(text: "未连接", level: "warn", fromWeb: false)
        self.route = .entry
    }

    /// 改服务器地址：真的变了就保存 + 清 token + 回门禁页，返回是否发生了变化。
    @discardableResult
    func changeServer(_ raw: String) -> Bool {
        let normalized = APIClient.normalize(raw)
        guard normalized != APIClient.normalize(serverBase) else { return false }
        self.serverBase = normalized
        self.clearBinding(notice: "服务器地址已修改，请重新绑定。", clearProfile: false)
        return true
    }

    // MARK: 连接状态

    func setStatus(text: String, level: String, fromWeb: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalized = ["ok", "warn", "error"].contains(level.lowercased()) ? level.lowercased() : "warn"
        if fromWeb { self.statusFromWeb = true }
        self.statusText = trimmed
        self.statusLevel = normalized
    }
}
