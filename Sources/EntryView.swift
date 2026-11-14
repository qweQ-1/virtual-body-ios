//
//  EntryView.swift
//  虚拟身体（VirtualBody）
//
//  职责：绑定门禁页。用户在这里填：服务器地址（默认生产基址）、6 位数字绑定码、设备名。
//  点「绑定」→ POST {base}/api/bind → 成功后 token 进 Keychain、QQ/昵称进 UserDefaults，
//  由 AppState 切到 MainView。失败按服务端 error 码显示中文提示。
//
//  无 iOS 17+ API；键盘收起用 .scrollDismissesKeyboard（iOS 16.0 起可用）。
//

import SwiftUI
import UIKit

struct EntryView: View {

    @EnvironmentObject private var app: AppState

    @State private var server: String = ""
    @State private var code: String = ""
    @State private var device: String = ""
    @State private var isBinding: Bool = false
    @State private var errorText: String?
    @State private var didLoadDraft: Bool = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case server
        case code
        case device
    }

    private let accent = Color(red: 0.42, green: 0.36, blue: 0.95)

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    hintCard
                    card { fields }
                    if let errorText = errorText {
                        messageRow(text: errorText, color: .red, icon: "exclamationmark.triangle.fill")
                    }
                    if let notice = app.notice {
                        messageRow(text: notice, color: .orange, icon: "info.circle.fill")
                    }
                    bindButton
                    footer
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 28)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear {
            guard !didLoadDraft else { return }
            didLoadDraft = true
            server = app.serverBase
            device = app.deviceName
        }
    }

    // MARK: - 子视图

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "heart.circle.fill")
                .font(.system(size: 40))
                .foregroundColor(accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("虚拟身体")
                    .font(.title2.weight(.bold))
                Text("把 QQ 里的角色接到这台手机上")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var hintCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "message.fill")
                .foregroundColor(accent)
            Text("在 QQ 里给机器人发送「虚现 绑定码」，把 6 位数字填到这里")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("服务器地址")
                TextField("https://samachat.de5.net/pet", text: $server)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
                    .focused($focusedField, equals: .server)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .code }
                    .padding(10)
                    .background(Color(uiColor: .secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("绑定码（6 位数字）")
                TextField("000000", text: codeBinding)
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .keyboardType(.numberPad)
                    .focused($focusedField, equals: .code)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(Color(uiColor: .secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text("绑定码 10 分钟内有效，一次一码。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("设备名（你在 QQ 里看到的名字）")
                TextField("iPhone", text: $device)
                    .font(.subheadline)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .focused($focusedField, equals: .device)
                    .submitLabel(.done)
                    .onSubmit { focusedField = nil }
                    .padding(10)
                    .background(Color(uiColor: .secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private var bindButton: some View {
        Button(action: { startBind() }) {
            HStack(spacing: 8) {
                if isBinding {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                }
                Text(isBinding ? "绑定中…" : "绑定")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundColor(.white)
            .background(isBinding ? accent.opacity(0.6) : accent,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isBinding)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text("版本 \(AppConfig.bundleVersion)（build \(AppConfig.bundleBuild)）")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("遇到问题：先在 QQ 里重新发送「虚现 绑定码」；局域网自建服务器请填 http://<IP>:8899")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundColor(.secondary)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .tertiarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }

    private func messageRow(text: String, color: Color, icon: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(text)
                .font(.footnote)
                .foregroundColor(color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 绑定码输入（只留数字、最多 6 位；用自定义 Binding，避免 onChange 版本差异）

    private var codeBinding: Binding<String> {
        Binding(
            get: { code },
            set: { newValue in
                let digits = newValue.filter { $0.isNumber }
                code = String(digits.prefix(6))
            }
        )
    }

    // MARK: - 绑定

    private func startBind() {
        focusedField = nil
        let base = APIClient.normalize(server)
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceName = device.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmedCode.count == 6, trimmedCode.allSatisfy({ $0.isNumber }) else {
            errorText = "请输入 6 位数字绑定码"
            Haptics.trigger(.warning)
            return
        }

        app.notice = nil
        errorText = nil
        isBinding = true

        Task {
            do {
                let client = try APIClient(base: base, token: nil)
                let result = try await client.bind(
                    code: trimmedCode,
                    device: deviceName.isEmpty ? AppConfig.defaultDeviceName : deviceName
                )
                await MainActor.run {
                    isBinding = false
                    Haptics.trigger(.success)
                    app.completeBind(
                        server: base,
                        token: result.token,
                        qq: result.qq,
                        nickname: result.nickname ?? "",
                        deviceName: deviceName.isEmpty ? AppConfig.defaultDeviceName : deviceName
                    )
                }
            } catch {
                print("[VB bind] failed: \(error.vbUserMessage)")
                await MainActor.run {
                    isBinding = false
                    errorText = error.vbUserMessage
                    Haptics.trigger(.error)
                }
            }
        }
    }
}
