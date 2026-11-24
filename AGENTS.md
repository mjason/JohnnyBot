# JohnnyBot local testing

Keep exactly one JohnnyBot test app running after launching a build. Check for existing JohnnyBot Debug instances in Xcode DerivedData and temporary build directories. Close older instances and verify that only the newest successful test build is running.

## SwiftUI 界面

- 导航、工具栏、菜单、表单、sheet 和 popover 优先使用系统组件。自定义浮动控件使用系统 Liquid Glass，所属操作共用一层材质。聊天正文、代码和表格保持清晰的内容背景。
- 保留 macOS 浮动圆角侧栏。按系统版本检查原生侧栏外观，避免叠加两层面板。保留键盘导航、焦点、折叠和多服务器切换。
- 修改界面后运行实际窗口，对照浅色、深色、窄窗口，以及受影响的辅助功能设置。对输入栏检查空白、输入、命令候选和禁用状态。记录实测平台以及仍待验证的场景。
- iPhone 上用紧凑宽度实测连接、项目列表、会话、键盘和返回手势。用本地测试服务检查多行草稿、发送、切换服务器和弹出页面，避免向真实会话写入测试消息。
- 参考 [Apple 的 Liquid Glass 采用指南](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) 和 [ECC 的 SwiftUI 示例](https://github.com/affaan-m/ECC/blob/main/docs/zh-CN/skills/liquid-glass-design/SKILL.md)。
