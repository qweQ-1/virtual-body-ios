//
//  VirtualBodyApp.swift
//  虚拟身体（VirtualBody）
//
//  职责：@main 入口 + 根路由。
//  - AppState 在这里创建并注入环境（门禁页/主界面/设置页都读它）；
//  - RootView 按 AppState.route 切换：loading（启动探活）→ entry（绑定门禁）→ main（WKWebView）；
//  - 启动探活只做一次（AppState.bootstrap 内部有幂等保护）。
//
//  纯 SwiftUI，无第三方依赖，最低 iOS 16.0。
//

import SwiftUI
import UIKit   // Color(uiColor:) 用到 UIColor，显式导入更保险

@main
struct VirtualBodyApp: App {

    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
        }
    }
}

struct RootView: View {

    @EnvironmentObject private var app: AppState

    var body: some View {
        Group {
            switch app.route {
            case .loading:
                SplashView()
            case .entry:
                EntryView()
            case .main:
                MainView()
            }
        }
        .task {
            await app.bootstrap()
        }
    }
}

/// 启动探活期间的一屏：避免出现“白屏一闪”
struct SplashView: View {

    @State private var pulse = false

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "heart.circle.fill")
                    .font(.system(size: 56))
                    .foregroundColor(Color(red: 0.42, green: 0.36, blue: 0.95))
                    .scaleEffect(pulse ? 1.06 : 0.94)
                Text("虚拟身体")
                    .font(.title3.weight(.semibold))
                ProgressView()
                Text("正在连接…")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
