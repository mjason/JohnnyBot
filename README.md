# JohnnyBot

JohnnyBot 是 macOS 和 iOS 上的 ACP 客户端。它通过 MQTT 5 和 TLS 1.3 连接 Johnny Bot Go 服务，按项目目录组织会话，并提供独立的远程终端。

- 会话支持流式 Markdown、工具调用折叠、模型与思考模式切换，以及截图和文件附件。可用能力由服务端声明。
- 远程终端支持多个标签、跨设备续接和控制权交接。macOS 上可用 `⌘T` 新建标签、`⌘W` 关闭当前标签。

## 构建和连接

1. 启动 Go 服务的 `johnnybot serve`，记下监听地址、`-host` 标识和 SHA-256 证书指纹。
2. 用包含 macOS 和 iOS 26.5 或更高版本 SDK 的 Xcode 打开 `JohnnyBot.xcodeproj`，运行 `JohnnyBot` scheme。iOS 真机安装需要配置签名团队。
3. 在客户端选择「复制设备公钥」，将公钥加入 Go 服务设备配置文件的 `authorized_keys` 数组。systemd 用户服务通过 `~/.config/johnnybot/service.env` 中的 `JOHNNYBOT_CONFIG` 指定该 JSON 文件的绝对路径。每台设备各自配对，私钥保存在设备钥匙串中。
4. 填入 `mqtts://主机:8883/服务标识`，点击「连接」。首次连接时，用可信渠道取得的指纹核对弹窗，确认后选择「信任并连接」。开发时可以用 `JOHNNY_MQTT_URL` 指定初始地址。
5. 在工作区的菜单中发现已有 Agent 会话，或创建新会话。打开过的会话同步到本机 SQLite。设备断线时可以继续阅读和排队发送，重连后按原命令 ID 同步。

远程终端支持实际 PTY 输入、调整大小、跨设备接管和重连续读。模型、模式和永久删除取决于服务端和当前 Agent 的能力。

## 发布 macOS 版

[Release macOS](https://github.com/mjason/JohnnyBot/actions/workflows/release-macos.yml) 构建同时支持 Apple 芯片和 Intel 的 macOS 26.5+ 版本。它使用 Developer ID 签名，提交 Apple 公证，再将带公证票据的 App 压缩包、SHA-256 校验文件和签名更新源上传到 [GitHub Releases](https://github.com/mjason/JohnnyBot/releases)。

从 1.0.1 起，macOS 发布版会自动检查 GitHub Releases 上的更新。也可以在 **JohnnyBot → 检查更新…** 手动检查，并在更新提示中选择是否自动安装后续版本。已安装 1.0.0 的用户需要先手动安装一次新版。

在仓库的 [Actions secrets](https://github.com/mjason/JohnnyBot/settings/secrets/actions) 中配置以下值。

| Secret | 内容 |
| --- | --- |
| `APPLE_DEVELOPER_ID_P12_BASE64` | [Developer ID Application 证书](https://developer.apple.com/help/account/certificates/create-developer-id-certificates)与私钥导出的 `.p12`，经 Base64 编码 |
| `APPLE_DEVELOPER_ID_P12_PASSWORD` | 导出 `.p12` 时设置的密码 |
| `APPLE_NOTARY_KEY_P8_BASE64` | [App Store Connect 团队 API 密钥](https://appstoreconnect.apple.com/access/integrations/api)的 `.p8` 文件，经 Base64 编码 |
| `APPLE_NOTARY_KEY_ID` | 团队 API 密钥的 Key ID |
| `APPLE_NOTARY_ISSUER_ID` | 团队 API 密钥的 Issuer ID |
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle `generate_keys -x` 导出的 EdDSA 私钥，对应 `ACPInfo.plist` 中的公钥 |

从 `main` 手动运行工作流并填写版本，例如 `v1.0.0`，或在 `main` 的提交上推送该格式的标签。勾选 `verify_only` 可以在配置凭据前验证构建，验证模式不会创建 Release。

## 许可证

项目代码采用 [MIT 许可证](LICENSE)。[SwiftStreamingMarkdown](ThirdParty/SwiftStreamingMarkdown/LICENSE) 和 [Nerd Fonts 符号字体](JohnnyBot/Fonts/NerdFontsSymbols-LICENSE.txt) 随附各自的许可证。
