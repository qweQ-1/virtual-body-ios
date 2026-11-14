# 虚拟身体 · iOS App（VirtualBody）

把 AstrBot 机器人变成一个**住在手机里的虚拟生命**：可以用手指真的摸到它（摸头、抱抱、挠痒、投喂、抛起来），
而且**虚 ↔ 现 双向互通** —— 你在 App 里摸它，QQ 会收到它的反应；你在 QQ 里说的话，它会在这个 App 里开口说出来。

> 服务端是另一个仓库的 AstrBot 插件：**[qweQ-1/astrbot_plugin_virtual_body](https://github.com/qweQ-1/astrbot_plugin_virtual_body)**（本仓库的界面就是它托管的同一份前端）。

---

## 一、两种用法，按你的设备条件选

| 方式 | 需要什么 | 优点 |
|---|---|---|
| **① PWA（推荐先试）** | 只要 iPhone + Safari | 30 秒就能玩。打开服务端地址 → 填绑定码 → 「添加到主屏幕」，图标和全屏体验跟原生一样 |
| — | — | 服务端地址由插件提供，形如 `https://你的域名/pet/` |
| **② 原生 ipa** | 有 Mac，或只用 GitHub Actions | 有原生触觉反馈（CoreHaptics）、原生 TTS 朗读、Keychain 保存 token |

### ① PWA：立刻可用

1. 在 QQ 里给机器人发送 `虚现 绑定码`，拿到 6 位数字。
2. iPhone Safari 打开你的服务端地址（形如 `https://your-domain/pet/`）。
3. 填服务器地址、绑定码、设备名 → 「绑定并进入」。
4. 分享菜单 → **添加到主屏幕**。之后从桌面图标进去就是全屏 App。
5. 想先不绑定试试手感：地址后面加 `?demo=1`（例如 `https://your-domain/pet/?demo=1`），进离线试用模式。

### ② 原生 ipa：没有 Mac 也能装

本仓库自带 GitHub Actions 工作流，在 **macOS runner** 上编译出**未签名 ipa**：

1. 把本仓库推到 GitHub（或用你自己的 fork）。
2. 打开仓库 **Actions → Build Unsigned IPA → Run workflow**。
3. 跑完后在该次运行页面底部下载 artifact **`VirtualBody-unsigned-ipa`**，里面是 `VirtualBody-unsigned.ipa`。
4. 用 **AltStore / Sideloadly / ESign** 之类工具自签安装（未签名 ipa 必须重签；免费 Apple ID 签名的 App 7 天过期，需重新签）。

有 Mac 的话本地一行命令：

```bash
brew install xcodegen
sh scripts/build-ipa.sh              # 出未签名 ipa → build/VirtualBody-unsigned.ipa
TEAM_ID=你的TeamID sh scripts/build-ipa.sh signed   # 用你的开发者证书签好，可直接装
```

然后 `open VirtualBody.xcodeproj` 也可以正常在 Xcode 里跑（工程由 `xcodegen generate` 生成，不要提交 `.xcodeproj`）。

---

## 二、进去第一件事：绑定 QQ

角色**只属于一个 QQ 号**。流程是：

```
QQ 里发送「虚现 绑定码」 → 机器人回 6 位数字 → App 里填数字 → 绑定成功
```

- 绑定码 10 分钟有效、一次一码。
- 绑定成功后 App 拿到一个长期 token（原生版存在 Keychain，PWA 版存在 localStorage）。
- 房主在 QQ 里发送 `虚现 解绑` 可以让所有设备失效。

---

## 三、摸它会发生什么（这就是"虚现互通"）

```
手指摸头 ──▶ 服务端生成反应（情绪 + 动作 + 台词，可选走大模型）──▶ App：角色说话/动作/特效
                                                              └─▶ QQ：一条触觉播报
你在 QQ 说话 ──▶ 角色在 App 里"听见" ──▶ LLM 回复 ──▶ App：角色把这句话说出口 + QQ 回复
在 App 里打字 ──▶ 角色在 App 里回应 ──▶ 同时镜像到 QQ
```

手势 → 触摸事件 的映射：

| 手势 | 事件 | 说明 |
|---|---|---|
| 轻点 | `tap` / `poke` | 点身体是戳，点头/脸是戳脸 |
| 横向抚摸 | `pet` | 连续触发（320ms 节流），摸不同部位反应不同 |
| 长按不动 | `rub` | 揉搓，持续触发 |
| 快速向上甩 | `toss` | 抛起来 |
| 上下拖动 | `drag` | 拎起来（视觉跟随，松手回位） |
| 底部按钮 | `hug` `tickle` `feed` `kiss` `dance` `sleep` … | 见 App 底部快捷条 |
| 聊天框 | `chat` | 对它说话 |

---

## 四、目录结构

```
project.yml                 # XcodeGen 工程定义（xcodegen generate 生成 .xcodeproj）
ExportOptions.plist         # 签名/导出模板（填 TEAM_ID 后可用于 exportArchive）
Sources/
  VirtualBodyApp.swift      # @main + 路由（启动 → 门禁 → 主界面）
  AppConfig.swift           # AppState：服务器地址/token/开关/设备名
  Keychain.swift            # token 存 Keychain
  APIClient.swift           # hello / bind / state / unbind
  EntryView.swift           # 绑定门禁页
  MainView.swift            # WKWebView 容器 + 原生错误页 + 注入 VB_CONFIG
  ScriptBridge.swift        # 网页 ↔ 原生 桥（handler 名固定 "vb"）
  Haptics.swift             # CoreHaptics / UIImpactFeedbackGenerator
  Speech.swift              # AVSpeechSynthesizer（zh-CN）
  SettingsView.swift        # 设置面板
Resources/
  Info.plist                # 手写（ATS 放开、局域网/麦克风用途描述）
  WebApp/                   # 界面主体：canvas 画出来的角色（无图片资源、可离线）
scripts/build-ipa.sh        # 一键出 ipa
.github/workflows/ios-build.yml
docs/PROTOCOL.md            # 与插件之间的完整接口契约
```

**原生壳只做 4 件事**：绑定门禁、触觉、朗读、设置。其余全部由 `Resources/WebApp/` 里的前端渲染，
所以改界面不用重新出 ipa —— 直接换服务端托管的 `webapp/`（插件仓库里那份）就能热更新。

前端与原生之间只有一条约定：网页发 `window.webkit.messageHandlers.vb.postMessage({cmd: ...})`，
支持 `haptic` / `speak` / `stop_speak` / `unbind` / `open_settings` / `log` / `status`；
原生在页面加载前注入 `window.VB_CONFIG = {server, token, platform, app_version, native}`。

---

## 五、把地址换成你自己的服务器

- 默认基址写在 `Sources/AppConfig.swift`（默认值）和门禁页输入框里，**首次绑定前都能改**。
- 换服务器后 token 会失效：在设置里「解绑本机」再重新绑一次即可。
- 服务端要支持 **HTTPS**（App Transport Security 已放开任意加载，但生产别用 http）和 **WebSocket**
  （`/ws`），反向代理记得加 `Upgrade` / `Connection` 头，见插件仓库的部署说明。

---

## 六、已知注意事项

- **没有任何 Mac 编译验证过**这份源码（生成环境的限制）。首次 `xcodebuild` 如报错，把错误贴回仓库 issue 即可，通常是小改。
- 首次运行会弹「本地网络」权限：用于访问你自建的服务器（局域网调试时必需）。
- 免费 Apple ID 签名的 ipa 7 天过期；想长期使用建议用付费开发者账号签名，或用 PWA。
- 没有 `Assets.xcassets` / AppIcon：本地安装无影响，**上架 App Store 前需要补**。
- 网页层的语音朗读用 `speechSynthesis`；原生壳里走 `Speech.swift`（更好听）。两者开关在设置页。

## 许可证

MIT
