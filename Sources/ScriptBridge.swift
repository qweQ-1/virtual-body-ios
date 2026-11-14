//
//  ScriptBridge.swift
//  虚拟身体（VirtualBody）
//
//  职责：Web 前端 ↔ 原生的消息桥。
//  前端调用：window.webkit.messageHandlers.vb.postMessage({cmd:"..."})
//  ※ 注册名必须是字符串 "vb"（ScriptBridge.handlerName），前端写死了这个名字。
//
//  支持的指令：
//    {"cmd":"haptic","style":"light|medium|heavy|soft|rigid|selection|success|warning|error"}
//    {"cmd":"speak","text":"...","lang":"zh-CN"}
//    {"cmd":"stop_speak"}
//    {"cmd":"unbind"}
//    {"cmd":"open_settings"}
//    {"cmd":"log","message":"..."}
//    {"cmd":"status","text":"...","level":"ok|warn|error"}
//  未知 cmd / 畸形 payload 一律忽略，绝不崩。
//

import Foundation
import WebKit

final class ScriptBridge: NSObject, WKScriptMessageHandler {

    /// 注册名：前端 window.webkit.messageHandlers.vb —— 不允许改
    static let handlerName = "vb"

    enum Event {
        case haptic(style: String)
        case speak(text: String, lang: String)
        case stopSpeak
        case unbind
        case openSettings
        case log(message: String)
        case status(text: String, level: String)
        case unknown(cmd: String)
    }

    /// 交给原生层处理（MainView）；保证在主线程回调。
    var onEvent: ((Event) -> Void)?

    /// 预留：需要时可由原生反调 JS（必须 weak，避免 webView → ucc → bridge → webView 环）
    weak var webView: WKWebView?

    // MARK: - 注入脚本

    /// 生成注入脚本：window.VB_CONFIG = {...};
    /// 用 JSONSerialization 生成，再做一次 < > 转义，避免任何字符串破坏脚本。
    static func configScript(server: String, token: String) -> String {
        let payload: [String: Any] = [
            "server": server,
            "token": token,
            "platform": AppConfig.platform,
            "app_version": AppConfig.appVersion,
            "native": true
        ]

        var json = "{\"server\":\"\",\"token\":\"\",\"platform\":\"ios\",\"app_version\":\"\(AppConfig.appVersion)\",\"native\":true}"
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8),
           !text.isEmpty {
            json = text
        }
        let safe = json
            .replacingOccurrences(of: "<", with: "\\u003C")
            .replacingOccurrences(of: ">", with: "\\u003E")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "window.VB_CONFIG = \(safe);"
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                              didReceive message: WKScriptMessage) {
        guard message.name == ScriptBridge.handlerName else { return }

        // 前端必须 postMessage 一个对象；字符串/数组/数字一律忽略
        guard let body = message.body as? [String: Any] else {
            print("[VB bridge] 忽略非字典消息")
            return
        }
        guard let rawCmd = body["cmd"] as? String else {
            print("[VB bridge] 忽略缺少 cmd 的消息")
            return
        }
        let cmd = rawCmd.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cmd.isEmpty else { return }

        switch cmd {
        case "haptic":
            let style = (body["style"] as? String) ?? "light"
            dispatch(.haptic(style: style))

        case "speak":
            let text = stringValue(body["text"])
            let lang = (body["lang"] as? String) ?? "zh-CN"
            if text.isEmpty {
                print("[VB bridge] speak 指令缺少 text，忽略")
            } else {
                dispatch(.speak(text: text, lang: lang))
            }

        case "stop_speak", "stopspeak", "stop":
            dispatch(.stopSpeak)

        case "unbind":
            dispatch(.unbind)

        case "open_settings", "opensettings", "settings":
            dispatch(.openSettings)

        case "log":
            dispatch(.log(message: stringValue(body["message"])))

        case "status":
            let text = stringValue(body["text"])
            let level = (body["level"] as? String) ?? "ok"
            if text.isEmpty {
                print("[VB bridge] status 指令缺少 text，忽略")
            } else {
                dispatch(.status(text: text, level: level))
            }

        default:
            // 未知指令：交给上层记录并忽略
            dispatch(.unknown(cmd: cmd))
        }
    }

    // MARK: - 内部

    private func dispatch(_ event: Event) {
        if Thread.isMainThread {
            onEvent?(event)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onEvent?(event)
            }
        }
    }

    /// 宽容取值：字符串 / 数字都能变成 String
    private func stringValue(_ any: Any?) -> String {
        if let text = any as? String { return text }
        if let number = any as? NSNumber { return number.stringValue }
        return ""
    }
}
