# JohnnyBot local testing

Keep exactly one JohnnyBot test app running after launching a build. Check for existing JohnnyBot Debug instances in Xcode DerivedData and temporary build directories. Close older instances and verify that only the newest successful test build is running.

## SwiftUI 界面

- 导航、工具栏、菜单、表单、sheet 和 popover 优先使用系统组件。自定义浮动控件使用系统 Liquid Glass，所属操作共用一层材质。聊天正文、代码和表格保持清晰的内容背景。
- 保留 macOS 浮动圆角侧栏。按系统版本检查原生侧栏外观，避免叠加两层面板。保留键盘导航、焦点、折叠和多服务器切换。
- 修改界面后运行实际窗口，对照浅色、深色、窄窗口，以及受影响的辅助功能设置。对输入栏检查空白、输入、命令候选和禁用状态。记录实测平台以及仍待验证的场景。
- iPhone 上用紧凑宽度实测连接、项目列表、会话、键盘和返回手势。用本地测试服务检查多行草稿、发送、切换服务器和弹出页面，避免向真实会话写入测试消息。
- 本项目说的 threadlist 指会话内显示消息与工作过程的 `SessionTranscript`。性能验证优先测 Mac，再测 iPhone。用同一份含普通文本、列表、表格和代码的历史记录，边流式接收回复边连续滚动，分别记录设备刷新上限、帧间隔 P99 和错过的刷新周期。侧栏单独测量。
- 让系统滚动视图处理 ProMotion 自适应刷新。120 Hz 的单帧预算约为 8.33 ms，真机和模拟器的结果分别记录。
- Mac 上可在测试方案环境变量中设置 `JOHNNYBOT_SCROLL_PERF=1`，单独运行 `TranscriptScrollPerformanceTests.scrollHistoryWhileReceivingAReply`。它在刷新上限最高的已连接显示器上，用 3,500 轮合成对话测滚动，不依赖服务器。
- 参考 [Apple 的 Liquid Glass 采用指南](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) 和 [ECC 的 SwiftUI 示例](https://github.com/affaan-m/ECC/blob/main/docs/zh-CN/skills/liquid-glass-design/SKILL.md)。

## Go 协议联调

- Swift 客户端使用 MQTT 5、TLS 1.3 证书指纹和每设备 Ed25519 身份。Go 源码位于 `ssh mj@192.168.2.70` 的 `/home/mj/dev/go/johnny_bot`，接口字段以该仓库的 `INTEGRATION.md` 和实际服务为准。
- 当前内网端点为 `mqtts://192.168.2.70:8883/spark-e9e8`。工作区 ID 与工作区内的相对路径分别传输。列表、会话、权限和模型状态以已提交的同步事件为准。
- 使用独立的数据库、临时设备密钥和临时工作区测试断线重放、PTY 和永久删除。Mac 与 iPhone 测试可以注入临时身份，避免触发开发机钥匙串授权。
