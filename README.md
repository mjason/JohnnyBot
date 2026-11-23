# JohnnyBot

JohnnyBot 是 macOS 和 iOS 上的 ACP 客户端。它通过 WebSocket 连接远端 Agent，按项目目录组织会话，并提供独立的远程终端。

- 会话支持流式 Markdown、工具调用折叠、模型与思考模式切换，以及截图和文件附件。可用能力由服务端声明。
- 远程终端支持多个标签、跨设备续接和控制权交接。macOS 上可用 `⌘T` 新建标签、`⌘W` 关闭当前标签。

## 构建和连接

1. 按 [johnny-server 的说明](https://github.com/mjason/johnny-server#启动)启动服务端，并生成共享令牌。
2. 用包含 macOS 和 iOS 26.5 SDK 的 Xcode 打开 `JohnnyBot.xcodeproj`，运行 `JohnnyBot` scheme。iOS 真机安装需要在 Xcode 里配置自己的签名团队。
3. 在客户端填入服务端的 ACP WebSocket 地址和共享令牌。同一台电脑可以用 `ws://127.0.0.1:8765/acp`。从其他设备连接时，使用服务端在可信局域网中的地址，或使用配置了 TLS 的 `wss://` 入口。

本地开发时可以通过 `JOHNNY_ACP_URL` 设置初始连接地址。也可以在客户端导入只含 `TOKEN` 的 `.env` 文件。

## 发布 macOS 版

[Release macOS](https://github.com/mjason/JohnnyBot/actions/workflows/release-macos.yml) 构建同时支持 Apple 芯片和 Intel 的 macOS 26.5+ 版本。它使用 Developer ID 签名，提交 Apple 公证，再将带公证票据的 App 压缩包和 SHA-256 校验文件上传到 [GitHub Releases](https://github.com/mjason/JohnnyBot/releases)。

在仓库的 [Actions secrets](https://github.com/mjason/JohnnyBot/settings/secrets/actions) 中配置以下值。

| Secret | 内容 |
| --- | --- |
| `APPLE_DEVELOPER_ID_P12_BASE64` | [Developer ID Application 证书](https://developer.apple.com/help/account/certificates/create-developer-id-certificates)与私钥导出的 `.p12`，经 Base64 编码 |
| `APPLE_DEVELOPER_ID_P12_PASSWORD` | 导出 `.p12` 时设置的密码 |
| `APPLE_NOTARY_KEY_P8_BASE64` | [App Store Connect 团队 API 密钥](https://appstoreconnect.apple.com/access/integrations/api)的 `.p8` 文件，经 Base64 编码 |
| `APPLE_NOTARY_KEY_ID` | 团队 API 密钥的 Key ID |
| `APPLE_NOTARY_ISSUER_ID` | 团队 API 密钥的 Issuer ID |

从 `main` 手动运行工作流并填写版本，例如 `v1.0.0`，或在 `main` 的提交上推送该格式的标签。勾选 `verify_only` 可以在配置凭据前验证构建，验证模式不会创建 Release。

## 许可证

项目代码采用 [MIT 许可证](LICENSE)。[SwiftStreamingMarkdown](ThirdParty/SwiftStreamingMarkdown/LICENSE) 和 [Nerd Fonts 符号字体](JohnnyBot/Fonts/NerdFontsSymbols-LICENSE.txt) 随附各自的许可证。
