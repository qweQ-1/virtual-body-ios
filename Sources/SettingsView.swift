//
//  SettingsView.swift
//  虚拟身体（VirtualBody）
//
//  职责：设置面板（从主界面浮层的齿轮进入）。
//  - 服务器地址：可改，改了就清 token 回门禁页并提示重新绑定；
//  - 连接状态：实时显示原生/前端上报的状态；
//  - 语音朗读 / 触觉反馈 开关；
//  - 解绑（Alert 二次确认 → /api/unbind → 清 token → 回门禁页）；
//  - App 版本、已绑定 QQ 号、设备名。
//
//  iOS 16.0 起可用（NavigationStack / Form / Toggle 均为 iOS 16 及更早 API）。
//

import SwiftUI

struct SettingsView: View {

    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var serverDraft: String = ""
    @State private var didLoadDraft: Bool = false
    @State private var showUnbindAlert: Bool = false
    @State private var isUnbinding: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                statusSection
                switchSection
                if app.isBound {
                    dangerSection
                }
                aboutSection
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .onAppear {
            guard !didLoadDraft else { return }
            didLoadDraft = true
            serverDraft = app.serverBase
        }
        .alert("确认解绑这台设备？", isPresented: $showUnbindAlert) {
            Button("取消", role: .cancel) { }
            Button("解绑", role: .destructive) { unbind() }
        } message: {
            Text("解绑后需要重新在 QQ 里发送「虚现 绑定码」才能进入。角色数据不会丢失。")
        }
    }

    // MARK: - Sections

    private var serverSection: some View {
        Section {
            TextField("https://samachat.de5.net/pet", text: $serverDraft)
                .font(.system(.footnote, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .keyboardType(.URL)

            Button {
                saveServer()
            } label: {
                Label("保存并重新绑定", systemImage: "arrow.clockwise")
            }
            .disabled(APIClient.normalize(serverDraft) == APIClient.normalize(app.serverBase))
        } header: {
            Text("服务器地址")
        } footer: {
            Text("改地址会清除本机登录状态，需要重新绑定。局域网自建服务器填 http://<IP>:8899")
        }
    }

    private var statusSection: some View {
        Section {
            HStack(spacing: 8) {
                Circle()
                    .fill(color(for: app.statusLevel))
                    .frame(width: 9, height: 9)
                Text(app.statusText)
                Spacer()
            }
            HStack {
                Text("已绑定 QQ")
                Spacer()
                Text(app.qq.isEmpty ? "—" : app.qq)
                    .foregroundColor(.secondary)
            }
            if !app.nickname.isEmpty {
                HStack {
                    Text("昵称")
                    Spacer()
                    Text(app.nickname).foregroundColor(.secondary)
                }
            }
            HStack {
                Text("设备名")
                Spacer()
                Text(app.deviceName.isEmpty ? "—" : app.deviceName)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        } header: {
            Text("连接")
        }
    }

    private var switchSection: some View {
        Section {
            Toggle(isOn: $app.speechEnabled) {
                Label("语音朗读（TTS）", systemImage: "speaker.wave.2.fill")
            }
            Toggle(isOn: $app.hapticsEnabled) {
                Label("触觉反馈", systemImage: "hand.tap.fill")
            }
        } header: {
            Text("原生能力")
        } footer: {
            Text("关掉后前端传来的 speak / haptic 指令会被忽略，界面照常。")
        }
    }

    private var dangerSection: some View {
        Section {
            Button(role: .destructive) {
                showUnbindAlert = true
            } label: {
                HStack {
                    Label("解绑这台设备", systemImage: "xmark.circle")
                    if isUnbinding {
                        Spacer()
                        ProgressView()
                            .progressViewStyle(.circular)
                    }
                }
            }
            .disabled(isUnbinding)
        } footer: {
            Text("解绑会作废服务器上的 token，下次要重新用绑定码进门。")
        }
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Text("App 版本")
                Spacer()
                Text("\(AppConfig.bundleVersion)（\(AppConfig.bundleBuild)）")
                    .foregroundColor(.secondary)
            }
            HStack {
                Text("平台")
                Spacer()
                Text(AppConfig.platform).foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("当前服务器").font(.subheadline)
                Text(app.serverBase)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("关于")
        }
    }

    // MARK: - Actions

    private func saveServer() {
        let changed = app.changeServer(serverDraft)
        if changed {
            // 地址变了 → AppState 已清 token 并切回门禁页
            serverDraft = app.serverBase
            dismiss()
        }
    }

    private func unbind() {
        guard !isUnbinding else { return }
        isUnbinding = true

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
                dismiss()
            }
        }
    }

    private func color(for level: String) -> Color {
        switch level.lowercased() {
        case "ok":    return .green
        case "error": return .red
        default:      return .orange
        }
    }
}
