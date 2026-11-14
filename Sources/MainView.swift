//
//  MainView.swift
//  虚拟身体（VirtualBody）
//
//  职责：主界面 —— 全屏 WKWebView 加载 bundle 内的 WebApp/index.html + 原生能力桥。
//  1) 加载前用 WKUserScript(.atDocumentStart, forMainFrameOnly) 注入 window.VB_CONFIG；
//  2) 注册 WKScriptMessageHandler("vb")：haptic / speak / stop_speak / unbind /
//     open_settings / log / status，未知 cmd 忽略；
//  3) didFail / didFailProvisionalNavigation → 原生错误页 + 「重试」；
//  4) 顶部连接状态浮层（点按进设置），设置入口；
//  5) 渲染进程被系统回收时自动重载。
//
//  无 iOS 17+ API（isInspectable 是 iOS 16.4，已用 #available 包裹）。
//

import SwiftUI
import UIKit
import WebKit

// MARK: - WebView 状态

final class WebBridgeModel: ObservableObject, @unchecked Sendable {

    @Published var isLoading: Bool = true
    @Published var loadError: String?

    var fileURL: URL?
    weak var webView: WKWebView?

    /// 页面首次（或重新）加载完成时回调，由 MainView 在 onAppear 里赋值。
    var onPageLoaded: (() -> Void)?

    /// 加载（首次进入 / 重试都走它）
    func loadIfNeeded() {
        guard let webView = webView else { return }
        guard let fileURL = fileURL else {
            isLoading = false
            loadError = "找不到内置的 WebApp/index.html（bundle 内资源缺失，请检查 WebApp 是否以 folder reference 进了 bundle）"
            return
        }
        loadError = nil
        isLoading = true
        webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
    }

    func retry() {
        if let webView = webView, webView.url != nil, loadError == nil {
            webView.reload()
        } else {
            loadIfNeeded()
        }
    }
}

// MARK: - UIViewRepresentable 包装

struct WebViewContainer: UIViewRepresentable {

    let server: String
    let token: String
    let model: WebBridgeModel
    let onEvent: (ScriptBridge.Event) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        // 注入 VB_CONFIG（.atDocumentStart，只注主框架）
        let userScript = WKUserScript(
            source: ScriptBridge.configScript(server: server, token: token),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(userScript)

        // 原生消息桥（名字固定 "vb"）
        let coordinator = context.coordinator
        let bridge = ScriptBridge()
        bridge.onEvent = { event in
            coordinator.forward(event, onEvent: onEvent)
        }
        configuration.userContentController.add(bridge, name: ScriptBridge.handlerName)
        coordinator.bridge = bridge

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.keyboardDismissMode = .interactive
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        if #available(iOS 16.4, *) {
            // 方便用 Safari Web Inspector 调前端；老系统没有这个属性
            webView.isInspectable = true
        }

        coordinator.webView = webView
        coordinator.server = server
        bridge.webView = webView
        model.webView = webView
        model.fileURL = WebViewContainer.webAppIndexURL()

        // 推迟到下一个 runloop，避免在 SwiftUI 更新期间改 @Published
        DispatchQueue.main.async {
            model.loadIfNeeded()
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 服务器地址/token 变化会重建整个 MainView（路由切换），这里不需要动 WebView
    }

    /// bundle 内 WebApp/index.html 的位置：
    /// folder reference 进包后路径是 <bundle>/WebApp/index.html
    static func webAppIndexURL() -> URL? {
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "WebApp") {
            return url
        }
        let fallback = Bundle.main.bundleURL.appendingPathComponent("WebApp/index.html")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate {

        let model: WebBridgeModel
        weak var webView: WKWebView?
        var bridge: ScriptBridge?
        /// 本页所属服务器，用于判断「用户点的链接」是否要外抛给 Safari
        var server: String = ""

        init(model: WebBridgeModel) {
            self.model = model
            super.init()
        }

        /// 把桥消息转到 SwiftUI 层（保证主线程）
        func forward(_ event: ScriptBridge.Event, onEvent: @escaping (ScriptBridge.Event) -> Void) {
            if Thread.isMainThread {
                onEvent(event)
            } else {
                DispatchQueue.main.async {
                    onEvent(event)
                }
            }
        }

        private func onMain(_ work: @escaping () -> Void) {
            if Thread.isMainThread {
                work()
            } else {
                DispatchQueue.main.async(execute: work)
            }
        }

        // MARK: 加载状态

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            onMain {
                self.model.isLoading = true
                self.model.loadError = nil
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onMain {
                self.model.isLoading = false
                self.model.loadError = nil
                self.model.onPageLoaded?()
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onMain {
                self.model.isLoading = false
                self.model.loadError = WebViewContainer.friendlyMessage(for: error)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onMain {
                self.model.isLoading = false
                self.model.loadError = WebViewContainer.friendlyMessage(for: error)
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            onMain {
                self.model.isLoading = true
                self.model.loadError = nil
                self.model.onPageLoaded?()
                self.model.retry()
            }
        }

        // MARK: 外链

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            let scheme = (url.scheme ?? "").lowercased()
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            let ownHost = URL(string: server)?.host

            // 只有“用户点了链接”才可能外跳；且只跳走「不属于本服务器」的 http(s)
            if navigationAction.navigationType == .linkActivated,
               isMainFrame,
               scheme == "http" || scheme == "https",
               let host = url.host,
               let own = ownHost,
               host != own {
                decisionHandler(.cancel)
                DispatchQueue.main.async {
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                }
                return
            }
            decisionHandler(.allow)
        }
    }

    static func friendlyMessage(for error: Error) -> String {
        let nsError = error as NSError
        switch nsError.code {
        case NSURLErrorFileDoesNotExist:
            return "内置前端文件不存在（WebApp/index.html 没有打进 App）"
        case NSURLErrorCannotConnectToHost, NSURLErrorTimedOut, NSURLErrorNotConnectedToInternet,
             NSURLErrorNetworkConnectionLost, NSURLErrorCannotFindHost:
            return "连不上服务器，请检查地址与网络"
        default:
            return "界面加载失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 主界面

struct MainView: View {

    @EnvironmentObject private var app: AppState
    @StateObject private var model = WebBridgeModel()
    @StateObject private var speech = SpeechEngine()

    @State private var showSettings = false
    @State private var isUnbinding = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            WebViewContainer(server: app.serverBase,
                             token: app.token ?? "",
                             model: model,
                             onEvent: { event in handle(event) })
                .ignoresSafeArea()

            statusOverlay
                .padding(.top, 6)

            if model.isLoading && model.loadError == nil {
                fullScreenCenter { loadingOverlay }
            }

            if let message = model.loadError {
                fullScreenCenter { errorOverlay(message: message) }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(app)
        }
        .onAppear {
            Haptics.prepare()
            model.onPageLoaded = {
                if !app.statusFromWeb {
                    app.setStatus(text: "界面已加载", level: "ok", fromWeb: false)
                }
            }
            if !app.statusFromWeb {
                app.setStatus(text: "正在加载界面…", level: "warn", fromWeb: false)
            }
        }
    }

    // MARK: 浮层

    private var statusOverlay: some View {
        Button {
            showSettings = true
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(color(for: app.statusLevel))
                    .frame(width: 9, height: 9)
                Text(app.statusText)
                    .font(.footnote)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Image(systemName: "gearshape.fill")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private var loadingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
            Text("正在加载界面…")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func errorOverlay(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundColor(.orange)
            Text("界面加载失败")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("重试") {
                    Haptics.trigger(.medium)
                    model.retry()
                }
                .buttonStyle(.borderedProminent)
                Button("打开设置") {
                    showSettings = true
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 2)
        }
        .padding(24)
        .frame(maxWidth: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 24)
    }

    // MARK: 桥消息处理

    private func handle(_ event: ScriptBridge.Event) {
        switch event {
        case .haptic(let style):
            Haptics.trigger(named: style)

        case .speak(let text, let lang):
            guard app.speechEnabled else { return }
            speech.speak(text, lang: lang)

        case .stopSpeak:
            speech.stop()

        case .unbind:
            unbindFromWeb()

        case .openSettings:
            showSettings = true

        case .log(let message):
            print("[VB web] \(message)")

        case .status(let text, let level):
            app.setStatus(text: text, level: level, fromWeb: true)

        case .unknown(let cmd):
            // 未知指令：只记日志，绝不崩
            print("[VB web] 未知指令，已忽略：\(cmd)")
        }
    }

    /// 前端点了「解绑」：先调 /api/unbind，再清本地登录态回门禁页
    private func unbindFromWeb() {
        guard !isUnbinding else { return }
        isUnbinding = true
        speech.stop()

        let base = app.serverBase
        let token = app.token

        Task {
            if let client = try? APIClient(base: base, token: token) {
                await client.unbind()
            }
            await MainActor.run {
                isUnbinding = false
                Haptics.trigger(.warning)
                app.clearBinding(notice: "已解绑，请在 QQ 里发送「虚现 绑定码」重新绑定。", clearProfile: true)
            }
        }
    }

    // MARK: 工具

    /// 让浮层在整屏垂直居中（外层 ZStack 是 .top 对齐，状态浮层用顶部）
    private func fullScreenCenter<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            content()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func color(for level: String) -> Color {
        switch level.lowercased() {
        case "ok":    return .green
        case "error": return .red
        default:      return .orange
        }
    }
}
