import SwiftUI
import SwiftTerm

@MainActor @Observable
final class RemoteTerminalWindows {
    @MainActor @Observable
    final class Session: Identifiable {
        let id = UUID()
        let client: ACPClient
        let project: ACPProject
        let shell = RemoteShell()
        var request: URLRequest

        init(client: ACPClient, project: ACPProject, request: URLRequest) {
            self.client = client
            self.project = project
            self.request = request
        }
    }

    private var sessions: [Session] = []
    private(set) var current: Session?
    var isPresented = false

    func select(_ client: ACPClient, project: ACPProject) throws {
        let session = try session(for: client, project: project)
        if current !== session { current = session }
    }

    func session(for client: ACPClient, project: ACPProject) throws -> Session {
        let request = try client.shellRequest()
        if let session = sessions.first(where: { $0.client === client && $0.project == project && $0.request.url == request.url }) {
            session.request = request
            return session
        }
        let session = Session(client: client, project: project, request: request)
        sessions.append(session)
        return session
    }
}

struct RemoteTerminalWindow: View {
    private enum Confirmation: Identifiable {
        case end(RemoteShell.Tab)
        case takeControl(String)

        var id: String {
            switch self {
            case .end(let tab): "end-\(tab.id)"
            case .takeControl(let tab): "take-control-\(tab)"
            }
        }

        var title: String {
            switch self {
            case .end: "关闭终端标签？"
            case .takeControl: "接管当前终端？"
            }
        }

        var actionTitle: String {
            switch self {
            case .end: "结束标签"
            case .takeControl: "接管终端"
            }
        }

        var isDestructive: Bool {
            if case .end = self { return true }
            return false
        }
    }

    let session: RemoteTerminalWindows.Session
    @AppStorage("remoteTerminalTheme") private var theme = RemoteTerminalTheme.dark
    @AppStorage("remoteTerminalFontFamily") private var fontFamily = ""
    @AppStorage("remoteTerminalFontSize") private var fontSize = 13.0
    @AppStorage("remoteTerminalNerdSymbols") private var useNerdSymbols = true
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingSettings = false
    @State private var confirmation: Confirmation?
    @State private var hoveredTab: String?
#if !os(macOS)
    @Environment(\.dismiss) private var dismiss
#endif

    private var shell: RemoteShell { session.shell }
    private var activeDirectory: String { shell.activeTab?.cwd ?? session.project.path ?? "" }
    private var windowTitle: String {
        guard let tab = shell.activeTab else { return session.project.name }
        return tab.command ?? tabName(tab)
    }
    private var canChangeTabs: Bool { shell.state == .attached && !shell.isChangingTab }
    private var tabHeight: CGFloat {
#if os(macOS)
        28
#else
        44
#endif
    }

    private var appearance: RemoteTerminalAppearance {
        RemoteTerminalAppearance(theme: theme, colorScheme: colorScheme, fontFamily: fontFamily,
                                 fontSize: fontSize, useNerdSymbols: useNerdSymbols)
    }

    var body: some View {
        VStack(spacing: 0) {
#if !os(macOS)
            header
            Divider()
#endif
            tabBar
            Divider()
            ZStack {
                let showsTerminal = shell.state == .attached && shell.activeTab != nil
                TerminalSurface(shell: shell, appearance: appearance)
                    .padding(.top, 8)
                    .background(appearance.background)
                    .opacity(showsTerminal ? 1 : 0)
                    .allowsHitTesting(showsTerminal)
                    .accessibilityHidden(!showsTerminal)
                if !showsTerminal {
                    connectionState
                }
            }
            Divider()
            footer
        }
        .background(.background)
        .navigationTitle(windowTitle)
        .onAppear(perform: attach)
        .onDisappear { shell.detach() }
#if os(macOS)
        .sheet(item: $confirmation, content: confirmationSheet)
#else
        .alert(confirmation?.title ?? "", isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
        ), presenting: confirmation) { item in
            Button(item.actionTitle, role: item.isDestructive ? .destructive : nil) { confirm(item) }
            Button("取消", role: .cancel) {}
        } message: { item in
            Text(confirmationMessage(item))
        }
#endif
        .alert("终端操作失败", isPresented: Binding(get: { shell.commandError != nil }, set: { if !$0 { shell.commandError = nil } })) {
            Button("确定", role: .cancel) { shell.commandError = nil }
        } message: {
            Text(shell.commandError ?? "")
        }
#if os(macOS)
        .frame(minWidth: 420, minHeight: 280)
        .focusedSceneValue(\.remoteTerminalActions, menuActions)
#endif
    }

    private func confirmationMessage(_ item: Confirmation) -> String {
        switch item {
        case .end(let tab):
            "「\(tabName(tab))」中的终端进程将结束，其他设备也会移除此标签。"
        case .takeControl:
            "键盘输入会交给此设备，终端会按此设备的尺寸重绘。另一台设备会继续观看。"
        }
    }

    private func confirm(_ item: Confirmation) {
        confirmation = nil
        switch item {
        case .end(let tab): shell.closeTab(tab.id)
        case .takeControl(let tab):
            if shell.selectedTab == tab { shell.takeControl() }
        }
    }

#if os(macOS)
    private func confirmationSheet(_ item: Confirmation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.title).font(.headline).accessibilityAddTraits(.isHeader)
            Text(confirmationMessage(item))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(role: .cancel) { confirmation = nil } label: {
                    Text("取消")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button(role: item.isDestructive ? .destructive : nil) { confirm(item) } label: {
                    Text(item.actionTitle)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent)
                .tint(item.isDestructive ? .red : .accentColor)
                .keyboardShortcut(item.isDestructive ? nil : .defaultAction)
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 340)
    }
#endif

#if !os(macOS)
    private var header: some View {
        HStack(spacing: 10) {
            Label(windowTitle, systemImage: "terminal")
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Spacer()
            Button("关闭") { dismiss() }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.bar)
    }
#endif

    private var tabBar: some View {
        let tabs = shell.visibleTabs
        return HStack(spacing: 6) {
            GeometryReader { geometry in
                let count = max(1, tabs.count)
                let width = max(104 + 2 * tabHeight, (geometry.size.width - 4) / CGFloat(count))
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 0) {
                            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                                tabButton(tab, index: index, width: width)
                                    .overlay(alignment: .trailing) {
                                        if index + 1 < tabs.count,
                                           tab.id != shell.selectedTab,
                                           tabs[index + 1].id != shell.selectedTab {
                                            Rectangle()
                                                .fill(.primary.opacity(0.10))
                                                .frame(width: 1, height: 14)
                                                .allowsHitTesting(false)
                                        }
                                    }
                            }
                        }
                        .padding(2)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: shell.selectedTab, initial: true) { _, id in
                        if let id { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
            .frame(height: tabHeight + 4)
#if os(visionOS)
            .background(.regularMaterial, in: Capsule())
#else
            .glassEffect(.regular, in: .capsule)
#endif
            .clipShape(Capsule())
            .disabled(!canChangeTabs)
            Button(action: newTab) {
                toolbarIcon("新建终端标签", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.large)
#if !os(macOS)
            .keyboardShortcut("t", modifiers: .command)
#endif
            .help("新建终端标签（⌘T）")
            .disabled(!canChangeTabs && shell.state != .empty)

            Button { showingSettings.toggle() } label: {
                toolbarIcon("终端设置", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .help("终端设置")
            .popover(isPresented: $showingSettings, arrowEdge: .top) { settings }
        }
        .padding(.horizontal, 8)
#if os(macOS)
        .padding(.top, 7)
        .padding(.bottom, 3)
#else
        .padding(.vertical, 3)
        .background(.bar)
#endif
    }

    private func toolbarIcon(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .font(.system(size: 14, weight: .medium))
            .frame(width: 22, height: 22)
    }

    private func tabButton(_ tab: RemoteShell.Tab, index: Int, width: CGFloat) -> some View {
        let selected = tab.id == shell.selectedTab
        return Button { shell.selectTab(tab.id) } label: {
            HStack(spacing: 6) {
                Text(tabLabel(tab)).lineLimit(1).truncationMode(.head)
#if os(macOS)
                if index < 9 {
                    Text("⌘\(index + 1)").foregroundStyle(.secondary).accessibilityHidden(true)
                }
#endif
            }
            .font(.system(size: 12, weight: selected ? .medium : .regular))
            .padding(.horizontal, tabHeight + 4)
            .frame(width: width - 2, height: tabHeight)
            .workspaceTabHighlight(selected: selected, hovered: hoveredTab == tab.id)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(width: width)
        .keyboardShortcut(tabShortcut(index))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("remote-terminal-tab-\(index)")
        .help(tab.cwd)
        .overlay(alignment: .trailing) {
            if selected || hoveredTab == tab.id {
                Button { requestClose(tab) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: tabHeight, height: tabHeight)
                        .background(.primary.opacity(hoveredTab == tab.id ? 0.08 : 0), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭标签")
                .accessibilityIdentifier("remote-terminal-close-tab-\(index)")
                .help(closesRemotely(tab) ? "关闭标签" : "从此设备关闭标签")
                .padding(.trailing, 4)
            }
        }
        .onHover { hovering in
            if hovering { hoveredTab = tab.id }
            else if hoveredTab == tab.id { hoveredTab = nil }
        }
        .contextMenu {
            Button(closesRemotely(tab) ? "关闭标签…" : "从此设备关闭标签", systemImage: "xmark") { requestClose(tab) }
                .disabled(!canChangeTabs)
        }
        .id(tab.id)
    }

    private var settings: some View {
        Form {
            Picker("主题", selection: $theme) {
                ForEach(RemoteTerminalTheme.allCases) { theme in
                    Text(theme.label).tag(theme)
                }
            }
            Picker("字体", selection: $fontFamily) {
                Text("系统等宽").tag("")
                if !fontFamily.isEmpty, !RemoteTerminalAppearance.fontFamilies.contains(fontFamily) {
                    Text(fontFamily).tag(fontFamily)
                }
                ForEach(RemoteTerminalAppearance.fontFamilies, id: \.self) { family in
                    Text(family).tag(family)
                }
            }
            Picker("符号字体", selection: $useNerdSymbols) {
                Text("内置 Nerd Font Mono").tag(true)
                Text("跟随主字体").tag(false)
            }
            LabeledContent("字号") {
                Stepper(value: $fontSize, in: Double(RemoteTerminalAppearance.fontSizes.lowerBound)...Double(RemoteTerminalAppearance.fontSizes.upperBound)) {
                    Text("\(fontSize, format: .number.precision(.fractionLength(0))) pt")
                }
            }
        }
        .controlSize(.large)
        .padding(16)
        .frame(width: 330)
    }

    private func tabShortcut(_ index: Int) -> KeyboardShortcut? {
#if os(macOS)
        if index < 9 { return KeyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command) }
#endif
        return nil
    }

    private func tabName(_ tab: RemoteShell.Tab) -> String {
        guard tab.title == "Shell", tab.cwd != "/" else { return tab.title }
        return tab.cwd.split(separator: "/").last.map(String.init) ?? tab.title
    }

    private func tabLabel(_ tab: RemoteShell.Tab) -> String {
        let name = tabName(tab)
        guard let command = tab.command, command != name else { return name }
        return "\(name) (\(command))"
    }

    private func newTab() {
        if shell.state == .empty { attach() }
        else { shell.createTab(in: session.project.path) }
    }

    private func closesRemotely(_ tab: RemoteShell.Tab) -> Bool {
        shell.access == nil || (tab.id == shell.selectedTab && shell.canSendInput)
    }

    private func requestClose(_ tab: RemoteShell.Tab) {
        guard canChangeTabs else { return }
        if closesRemotely(tab) { confirmation = .end(tab) }
        else { shell.hideTab(tab.id) }
    }

#if os(macOS)
    private var menuActions: RemoteTerminalMenuActions {
        RemoteTerminalMenuActions(
            newTab: newTab,
            endTab: { if let tab = shell.activeTab { requestClose(tab) } },
            restoreTabs: shell.restoreHiddenTabs,
            showSettings: { showingSettings = true },
            selectAdjacentTab: { step in
                let tabs = shell.visibleTabs
                guard let index = tabs.firstIndex(where: { $0.id == shell.selectedTab }) else { return }
                shell.selectTab(tabs[(index + step + tabs.count) % tabs.count].id)
            },
            canNewTab: canChangeTabs || shell.state == .empty,
            canCloseTab: canChangeTabs && shell.activeTab != nil,
            canSwitchTabs: canChangeTabs && shell.visibleTabs.count > 1,
            hasHiddenTabs: !shell.hiddenTabs.isEmpty
        )
    }
#endif

    private var connectionState: some View {
        VStack(spacing: 9) {
            switch shell.state {
            case .connecting:
                ProgressView("正在接入远程终端…").controlSize(.small)
            case .attached:
                Text("请选择终端标签")
                if !shell.hiddenTabs.isEmpty {
                    Button("显示已关闭的标签", action: shell.restoreHiddenTabs).buttonStyle(.bordered)
                }
            case .empty:
                Text("没有打开的终端标签")
                Button("新建终端标签", action: newTab).buttonStyle(.borderedProminent)
            case .ended(let code):
                Text(code == 0 ? "已离开远程终端" : "终端退出（\(code)）")
                Button("重新接入", action: attach).buttonStyle(.borderedProminent)
            case .failed(let message):
                Text("终端连接中断")
                Text(message).font(.caption).foregroundStyle(.secondary)
                Button("重新接入", action: attach).buttonStyle(.borderedProminent)
            case .detached:
                Button("连接", action: attach).buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if !activeDirectory.isEmpty {
                Label(activeDirectory, systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .layoutPriority(-1)
            }
            Spacer()
            if shell.state == .attached, shell.activeTab != nil, let access = shell.access {
                Label(access.hasControl ? "控制中" : "观看中", systemImage: access.hasControl ? "keyboard" : "eye")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if access.hasControl {
                    Button("交出控制", action: shell.releaseControl)
                        .buttonStyle(.bordered)
                        .disabled(!canChangeTabs)
                } else if let tab = shell.selectedTab {
                    Menu {
                        ForEach(RemoteShell.ViewportDirection.allCases) { direction in
                            Button(direction.label, systemImage: direction.icon) { shell.moveViewport(direction) }
                        }
                    } label: {
                        toolbarIcon("移动画面", systemImage: "arrow.up.left.and.down.right")
                            .frame(minWidth: tabHeight, minHeight: max(32, tabHeight))
                            .background(.quaternary, in: Capsule())
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityIdentifier("remote-terminal-viewport")
                    .help("移动观看画面")
                    .disabled(!canChangeTabs)

                    Button(access.hasController ? "接管" : "开始控制") {
                        if access.hasController { confirmation = .takeControl(tab) }
                        else { shell.takeControl() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canChangeTabs)
                }
            } else if shell.state == .attached, let host = session.request.url?.host {
                Label {
                    Text(host)
                } icon: {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(.green)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("已连接")
            }
            if !shell.hiddenTabs.isEmpty {
                Button(action: shell.restoreHiddenTabs) {
                    toolbarIcon("显示已关闭的标签", systemImage: "rectangle.on.rectangle")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
            }
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 31)
    }

    private func attach() { shell.attach(request: session.request, directory: session.project.path) }
}

#if os(macOS)
struct RemoteTerminalMenuActions {
    let newTab: () -> Void
    let endTab: () -> Void
    let restoreTabs: () -> Void
    let showSettings: () -> Void
    let selectAdjacentTab: (Int) -> Void
    let canNewTab: Bool
    let canCloseTab: Bool
    let canSwitchTabs: Bool
    let hasHiddenTabs: Bool
}

extension FocusedValues {
    @Entry var remoteTerminalActions: RemoteTerminalMenuActions?
}

struct RemoteTerminalCommands: Commands {
    @FocusedValue(\.remoteTerminalActions) private var terminal

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            if let terminal {
                Button("关闭标签", action: terminal.endTab)
                    .keyboardShortcut("w", modifiers: .command)
                    .disabled(!terminal.canCloseTab)
            } else {
                Button("关闭窗口") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w", modifiers: .command)
            }
        }
        CommandMenu("Shell") {
            Button("新建终端标签") { terminal?.newTab() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(terminal?.canNewTab != true)
        }
        CommandMenu("会话") {
            Button("上一个标签") { terminal?.selectAdjacentTab(-1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(terminal?.canSwitchTabs != true)
            Button("下一个标签") { terminal?.selectAdjacentTab(1) }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(terminal?.canSwitchTabs != true)
            Button("显示已关闭的标签") { terminal?.restoreTabs() }
                .disabled(terminal?.hasHiddenTabs != true)
            Divider()
            Button("终端设置…") { terminal?.showSettings() }
                .disabled(terminal == nil)
        }
    }
}
#endif

private final class TerminalSurfaceCoordinator {
    var appearance: RemoteTerminalAppearance?
    var focusedTab: String?
}

#if os(macOS)
private struct TerminalSurface: NSViewRepresentable {
    let shell: RemoteShell
    let appearance: RemoteTerminalAppearance

    func makeNSView(context: Context) -> TerminalView { shell.view }
    func updateNSView(_ view: TerminalView, context: Context) {
        if context.coordinator.appearance != appearance {
            appearance.apply(to: view)
            context.coordinator.appearance = appearance
        }
        if shell.canSendInput, let tab = shell.selectedTab, context.coordinator.focusedTab != tab {
            context.coordinator.focusedTab = tab
            DispatchQueue.main.async { [weak view] in
                if let view, let window = view.window, window.isKeyWindow { window.makeFirstResponder(view) }
            }
        } else if !shell.canSendInput {
            context.coordinator.focusedTab = nil
        }
    }

    func makeCoordinator() -> TerminalSurfaceCoordinator { TerminalSurfaceCoordinator() }
}
#else
private struct TerminalSurface: UIViewRepresentable {
    let shell: RemoteShell
    let appearance: RemoteTerminalAppearance

    func makeUIView(context: Context) -> TerminalView { shell.view }
    func updateUIView(_ view: TerminalView, context: Context) {
        shell.updateInputFocus()
        if context.coordinator.appearance != appearance {
            appearance.apply(to: view)
            context.coordinator.appearance = appearance
        }
    }
    func makeCoordinator() -> TerminalSurfaceCoordinator { TerminalSurfaceCoordinator() }
}
#endif
