# JohnnyBot

JohnnyBot 是 macOS 和 iOS 上的 ACP 客户端。它通过 WebSocket 连接远端 Agent，按项目目录组织会话，并提供独立的远程终端。

- 会话支持流式 Markdown、工具调用折叠、模型与思考模式切换，以及截图和文件附件。可用能力由服务端声明。
- 远程终端支持多个标签、跨设备续接和控制权交接。macOS 上可用 `⌘T` 新建标签、`⌘W` 关闭当前标签。

## 构建和连接

1. 按 [johnny-server 的说明](https://github.com/mjason/johnny-server#启动)启动服务端，并生成共享令牌。
2. 用包含 macOS 和 iOS 26.5 SDK 的 Xcode 打开 `JohnnyBot.xcodeproj`，运行 `JohnnyBot` scheme。iOS 真机安装需要在 Xcode 里配置自己的签名团队。
3. 在客户端填入服务端的 ACP WebSocket 地址和共享令牌。同一台电脑可以用 `ws://127.0.0.1:8765/acp`。从其他设备连接时，使用服务端在可信局域网中的地址，或使用配置了 TLS 的 `wss://` 入口。

本地开发时可以通过 `JOHNNY_ACP_URL` 设置初始连接地址。也可以在客户端导入只含 `TOKEN` 的 `.env` 文件。

## 许可证

项目代码采用 [MIT 许可证](LICENSE)。[SwiftStreamingMarkdown](ThirdParty/SwiftStreamingMarkdown/LICENSE) 和 [Nerd Fonts 符号字体](JohnnyBot/Fonts/NerdFontsSymbols-LICENSE.txt) 随附各自的许可证。
