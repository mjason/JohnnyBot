import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    private struct Server: Identifiable {
        let id = UUID()
        let client: ACPClient
        let workspace = ServerWorkspaceState()

        var label: String {
            client.address.isEmpty ? "新服务器" : client.address
        }
    }

    @State private var servers: [Server]

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: "acpServerAddresses") ?? [ACPClient.defaultAddress]
        let addresses = saved.isEmpty ? [""] : saved
        _servers = State(initialValue: addresses.map { address in
            let token = address == ACPClient.defaultAddress ? ProcessInfo.processInfo.environment["TOKEN"] ?? "" : ""
            return Server(client: ACPClient(address: address, token: token))
        })
    }
    @State private var selectedServer: UUID?
    @State private var confirmingRemoval = false
    @State private var pendingRemoval: UUID?
    @State private var hoveredTab: UUID?
#if os(macOS)
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var windowWidth: CGFloat = 1020
#else
    @State private var columns: NavigationSplitViewVisibility = .automatic
#endif

    private var current: Server {
        servers.first { $0.id == selectedServer } ?? servers[0]
    }

    var body: some View {
        VStack(spacing: 0) {
#if !os(macOS)
            HStack(spacing: 8) {
                serverTabs
                newTabButton
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            Divider()
#endif
            ServerWorkspace(
                client: current.client,
                workspace: current.workspace,
                columns: $columns,
                removeServer: { requestClose(current, confirmRemoval: true) }
            ) {
#if os(macOS)
                serverTabs
                    .frame(width: min(920, max(132, windowWidth - 355)), height: 32)
#endif
            } trailingAction: {
                newTabButton
            }
            .id(current.id)
        }
#if os(macOS)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
            windowWidth = width
        }
#endif
        .onDisappear {
            for server in servers { server.client.disconnect() }
        }
        .onChange(of: servers.map { $0.client.address }) { _, addresses in
            let saved = addresses.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            UserDefaults.standard.set(saved, forKey: "acpServerAddresses")
        }
        .confirmationDialog("移除服务器？", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("移除服务器", role: .destructive, action: removeTab)
        } message: {
            if let server = servers.first(where: { $0.id == pendingRemoval }) {
                Text("移除「\(server.label)」的连接配置和本地草稿。服务器上的会话记录会保留。")
            }
        }
    }

    private var newTabButton: some View {
        Button(action: addServer) {
            Label("新建服务器标签页", systemImage: "plus")
                .labelStyle(.iconOnly)
        }
        .keyboardShortcut("t", modifiers: .command)
        .help("新建服务器标签页")
    }

    private func addServer() {
        let server = Server(client: ACPClient(address: "", token: ""))
        servers.append(server)
        selectedServer = server.id
    }

    private var serverTabs: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(servers) { server in
                        serverTab(server)
                            .id(server.id)
                    }
                }
                .padding(2)
                .containerRelativeFrame(.horizontal) { width, _ in
                    max(width, CGFloat(servers.count) * 132)
                }
                .background(.quaternary, in: Capsule())
            }
            .scrollIndicators(.hidden)
            .onChange(of: current.id, initial: true) { _, id in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("服务器标签页")
    }

    private func serverTab(_ server: Server) -> some View {
        let selected = server.id == current.id
#if os(macOS)
        let showsClose = hoveredTab == server.id
#else
        let showsClose = selected
#endif
        let pending = server.client.permissions.count
        let address = URLComponents(string: server.client.address)
        let host = address?.host.map { host in
            address?.port.map { "\(host):\($0)" } ?? host
        }
        let title = host ?? server.label

        return HStack(spacing: 0) {
            if servers.count > 1 {
                Button {
                    requestClose(server)
                } label: {
                    Label("关闭标签页", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(showsClose ? 1 : 0)
                .allowsHitTesting(showsClose)
                .accessibilityHidden(!showsClose)
                .help("关闭 \(server.label)")
            }

            Button {
                selectedServer = server.id
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: server.client.connected ? "circle.fill" : "server.rack")
                        .font(.system(size: server.client.connected ? 7 : 11))
                        .foregroundStyle(server.client.connected ? Color.green : Color.secondary)
                        .accessibilityHidden(true)
                    Text(title)
                        .truncationMode(.middle)
                        .lineLimit(1)
                    if pending > 0 {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(.orange)
                            .accessibilityLabel("\(pending) 项待审批")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 28)
                .padding(.trailing, servers.count > 1 ? 28 : 0)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityValue(server.client.connected ? "已连接" : "未连接")
            .help(server.label)
        }
        .font(.callout.weight(selected ? .semibold : .regular))
        .foregroundStyle(selected ? .primary : .secondary)
        .background {
            if selected {
                Capsule()
                    .fill(.background)
                    .shadow(color: .black.opacity(0.10), radius: 1.5, y: 1)
            } else if hoveredTab == server.id {
                Capsule().fill(.primary.opacity(0.055))
            }
        }
        .contentShape(Capsule())
        .onHover { hovering in
            if hovering {
                hoveredTab = server.id
            } else if hoveredTab == server.id {
                hoveredTab = nil
            }
        }
        .contextMenu {
            if server.client.connected {
                Button("断开连接", systemImage: "power", role: .destructive) {
                    server.client.disconnect()
                }
            }
            if servers.count > 1 {
                Button("关闭标签页", systemImage: "xmark") {
                    requestClose(server)
                }
            }
        }
    }

    private func requestClose(_ server: Server, confirmRemoval: Bool = false) {
        pendingRemoval = server.id
        if confirmRemoval || server.client.connected || server.workspace.managing {
            confirmingRemoval = true
        } else {
            removeTab()
        }
    }

    private func removeTab() {
        guard let index = servers.firstIndex(where: { $0.id == pendingRemoval }) else { return }
        let server = servers[index]
        let wasSelected = server.id == current.id
        server.client.disconnect()
        servers.remove(at: index)
        if servers.isEmpty {
            addServer()
        } else if wasSelected {
            selectedServer = servers[min(index, servers.count - 1)].id
        }
        pendingRemoval = nil
    }

}

@Observable @MainActor
private final class ServerWorkspaceState {
    var selection: String?
    var drafts: [String: String] = [:]
    var managing = false
    var failure: String?
    var preferredColumn: NavigationSplitViewColumn = .detail
}

private struct ServerWorkspace<Header: View, TrailingAction: View>: View {
    @FocusState private var composerFocused: Bool
    let client: ACPClient
    @Bindable var workspace: ServerWorkspaceState
    @Binding var columns: NavigationSplitViewVisibility
    let removeServer: () -> Void
    @ViewBuilder let header: () -> Header
    @ViewBuilder let trailingAction: () -> TrailingAction
    @State private var importing = false
    @State private var hoveredSession: String?
    @State private var sessionToDelete: ACPSession?

    var body: some View {
        NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $workspace.preferredColumn) {
            List(selection: $workspace.selection) {
#if os(macOS)
                if client.sessions.isEmpty {
                    Section("会话") {
                        Text(client.connected ? "暂无会话" : "连接服务器后显示会话")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
#endif
                if !client.sessions.isEmpty {
                    Section("会话") {
                        ForEach(client.sessions) { session in
                            Group {
#if os(macOS)
                                sessionRow(session).tag(session.id)
#else
                                NavigationLink(value: session.id) { sessionRow(session) }
#endif
                            }
                            .contextMenu {
                                Button("删除会话", systemImage: "trash", role: .destructive) {
                                    sessionToDelete = session
                                }
                                .disabled(!client.supportsSessionDelete || workspace.managing || client.prompting.contains(session.id))
                            }
                        }
                    }
                }
            }
#if os(macOS)
            .toolbar(removing: .sidebarToggle)
#endif
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if client.connected {
                    HStack {
                        Button(action: createSession) {
                            Label("新建会话", systemImage: "square.and.pencil")
                        }
                        Spacer()
                        Button { manage { try await client.listSessions() } } label: {
                            Label("刷新会话", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                        }
                        .help("刷新会话")
                    }
                    .buttonStyle(.borderless)
                    .disabled(workspace.managing)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
#if !os(macOS)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if client.connected {
                    serverBar
                }
                if !client.connected {
                    Button {
                        workspace.preferredColumn = .detail
                    } label: {
                        Label("连接 Agent", systemImage: "network")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .padding()
                }
            }
            .overlay {
                if client.sessions.isEmpty {
                    Text(client.connected ? "暂无会话" : "连接后显示会话")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
#endif
#if os(macOS)
            .navigationSplitViewColumnWidth(min: 220, ideal: 268, max: 340)
#endif
            .navigationTitle("JohnnyBot")
            .toolbar {
#if os(macOS)
                if columns != .detailOnly {
                    ToolbarSpacer(.flexible, placement: .primaryAction)
                    ToolbarItem(placement: .primaryAction) {
                        sidebarActions
                    }
                }
#endif
            }
        } detail: {
            Group {
                if let id = workspace.selection, let session = client.sessions.first(where: { $0.id == id }) {
                    conversation(session)
                } else {
                    if client.connected {
                        ContentUnavailableView {
                            Label("选择会话", systemImage: "bubble.left.and.bubble.right")
                        } description: {
                            Text("从边栏选择会话，或新建一段对话。")

                        }
                    } else {
                        connection
                    }
                }
            }
#if os(macOS)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    header()
                }
                ToolbarItem(placement: .primaryAction) {
                    trailingAction()
                }
            }
#endif
        }
#if os(macOS)
        .toolbar {
            if columns == .detailOnly {
                ToolbarItem(placement: .navigation) {
                    sidebarToggle(showing: false)
                }
            }
        }
#endif
#if os(macOS)
        .overlayPreferenceValue(SessionPreviewAnchor.self) { anchor in
            if let anchor, let session = client.sessions.first(where: { $0.id == hoveredSession }), sessionToDelete == nil {
                GeometryReader { geometry in
                    let row = geometry[anchor]
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.title).font(.headline)
                        if !session.cwd.isEmpty {
                            Text(session.cwd).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .frame(width: 280, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.16), radius: 7, y: 3)
                    .position(x: min(row.maxX + 162, geometry.size.width - 144),
                              y: max(45, min(row.midY, geometry.size.height - 45)))
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
#endif
        .confirmationDialog(
            "删除会话？",
            isPresented: Binding(get: { sessionToDelete != nil }, set: { if !$0 { sessionToDelete = nil } }),
            titleVisibility: .visible,
            presenting: sessionToDelete
        ) { session in
            Button("删除会话", role: .destructive) {
                manage {
                    try await client.deleteSession(session.id)
                    workspace.drafts.removeValue(forKey: session.id)
                    if workspace.selection == session.id {
                        workspace.selection = nil
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: { session in
            Text("从服务器的会话列表中删除「\(session.title)」？")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            do {
                try client.importToken(from: result.get())
            } catch {
                workspace.failure = error.localizedDescription
            }
        }
        .alert("操作失败", isPresented: Binding(get: { workspace.failure != nil }, set: { if !$0 { workspace.failure = nil } })) {
            Button("确定") { workspace.failure = nil }
        } message: {
            Text(workspace.failure ?? "")
        }
        .onChange(of: client.connected) { _, connected in
            if !connected {
                workspace.selection = nil
                workspace.drafts.removeAll()
            }
        }
    }

#if os(macOS)
    private var sidebarActions: some View {
        HStack(spacing: 1) {
            Button(action: removeServer) {
                sidebarActionIcon("minus.rectangle")
            }
            .accessibilityLabel("移除当前服务器")
            .disabled(client.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("移除当前服务器")

            sidebarToggle(showing: true)
        }
        .buttonStyle(SidebarHoverStyle())
        .padding(.horizontal, 3)
    }

    private struct SidebarHoverStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            HoverLabel(configuration: configuration)
        }

        private struct HoverLabel: View {
            let configuration: ButtonStyle.Configuration
            @State private var hovered = false
            @Environment(\.isEnabled) private var enabled

            var body: some View {
                configuration.label
                    .background {
                        Capsule().fill(.primary.opacity(enabled && configuration.isPressed ? 0.14 : enabled && hovered ? 0.07 : 0))
                    }
                    .onHover { hovered = $0 }
            }
        }
    }

    private func sidebarActionIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .resizable()
            .scaledToFit()
            .frame(width: 19, height: 15)
            .frame(width: 32, height: 24)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
    }

    private func sidebarToggle(showing: Bool) -> some View {
        let title = showing ? "隐藏边栏" : "显示边栏"
        return Button {
            withAnimation(.easeInOut(duration: 0.22)) {
                columns = showing ? .detailOnly : .all
            }
        } label: {
            if showing {
                sidebarActionIcon("sidebar.left")
            } else {
                Label(title, systemImage: "sidebar.left")
                    .labelStyle(.iconOnly)
            }
        }
        .accessibilityLabel(title)
        .help(title)
        .keyboardShortcut("s", modifiers: [.command, .control])
    }
#endif

    private func sessionRow(_ session: ACPSession) -> some View {
        let active = client.loaded.contains(session.id)
        let approvalPending = client.permissions.contains { $0.sessionID == session.id }
        return HStack(spacing: 10) {
            Image(systemName: active ? "bubble.left.fill" : "bubble.left")
                .foregroundStyle(workspace.selection == session.id ? Color.primary : Color.accentColor)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(session.title).font(.body.weight(.medium)).lineLimit(1)
            Spacer(minLength: 0)
            if approvalPending {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("等待审批")
            } else if client.prompting.contains(session.id) {
                ProgressView().controlSize(.small).accessibilityLabel("正在回复")
            }
#if os(macOS)
            if workspace.selection == session.id {
                Button {
                    hoveredSession = nil
                    sessionToDelete = session
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("删除会话")
                .help("删除会话")
                .disabled(!client.supportsSessionDelete || workspace.managing || client.prompting.contains(session.id))
            }
#endif
        }
        .frame(minHeight: 26)
        .contentShape(Rectangle())
#if os(macOS)
        .onHover { inside in
            if inside { hoveredSession = session.id }
            else if hoveredSession == session.id { hoveredSession = nil }
        }
        .anchorPreference(key: SessionPreviewAnchor.self, value: .bounds) {
            hoveredSession == session.id ? $0 : nil
        }
#endif
    }

    private var serverBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(client.status)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .accessibilityLabel("已连接到 \(client.status)")
            Spacer()
            Menu {
                Button("断开连接", systemImage: "power", role: .destructive) { client.disconnect() }
            } label: {
                Label("连接选项", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.bar)
    }

    private var connection: some View {
        @Bindable var client = client
        return ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 11) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 32, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 76, height: 76)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 24))
                        .accessibilityHidden(true)
                    Text("连接 Agent").font(.largeTitle.bold())
                    Text("输入 ACP 服务器地址和共享令牌。")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: 0) {
                    connectionField("服务器地址", icon: "server.rack") {
                        TextField("ws:// 或 wss://", text: $client.address)
                            .accessibilityLabel("服务器地址")
                    }
                    Divider().padding(.leading, 42)
                    connectionField("共享令牌", icon: "key") {
                        SecureField("输入或导入令牌", text: $client.token)
                            .accessibilityLabel("共享令牌")
                    }
                }
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.quaternary) }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { connectionButtons }
                    VStack(spacing: 12) { connectionButtons }
                }
                .controlSize(.large)
                .disabled(workspace.managing)
                if workspace.managing {
                    ProgressView(client.status).controlSize(.small)
                }
            }
            .frame(maxWidth: 390)
            .padding(24)
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical) { height, _ in max(390, height) }
        }
        .navigationTitle("JohnnyBot")
    }

    private func connectionField<Field: View>(_ title: String, icon: String, @ViewBuilder field: () -> Field) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                field()
            }
        }
        .padding(14)
    }

    @ViewBuilder private var connectionButtons: some View {
        Button { importing = true } label: {
            Label("导入 .env", systemImage: "arrow.down.doc")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        Button {
            manage {
                try await client.connect()
                try await client.listSessions()
            }
        } label: {
            Label("连接", systemImage: "arrow.right")
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .disabled(client.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                  client.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func createSession() {
        manage {
            workspace.selection = try await client.createSession()
            workspace.preferredColumn = .detail
        }
    }

    private func conversation(_ session: ACPSession) -> some View {
        let id = session.id
        let entries = client.entries[id] ?? []
        let isLoaded = client.loaded.contains(id)
        let isPrompting = client.prompting.contains(id)
        let permissions = client.permissions.filter { $0.sessionID == id }
        return VStack(spacing: 0) {
            if !isLoaded && entries.isEmpty {
                ContentUnavailableView {
                    Label(session.title, systemImage: "bubble.left")
                } actions: {
                    Button("加载会话") { manage { try await client.load(id) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(workspace.managing)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(entries) { entry in
                            messageRow(entry)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: 680)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 22)
                    .frame(maxWidth: .infinity)
                }
#if os(macOS)
                .scrollEdgeEffectHidden(true, for: .top)
#endif
                .defaultScrollAnchor(.bottom)
                .overlay {
                    if entries.isEmpty {
                        ContentUnavailableView("开始对话", systemImage: "text.bubble",
                                               description: Text("向 Agent 发送一条消息。"))
                        .allowsHitTesting(false)
                    }
                }

                ForEach(permissions) { permission in
                    VStack(alignment: .leading, spacing: 8) {
                        Label("审批请求", systemImage: "lock.shield")
                            .font(.headline)
                        Text(permission.title).textSelection(.enabled)
                        if let details = permission.details {
                            DisclosureGroup("工具参数") {
                                ScrollView {
                                    Text(details).font(.caption.monospaced()).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 120)
                            }
                        }
                        Menu("选择审批结果") {
                            ForEach(permission.options) { option in
                                Button(option.name) {
                                    run { try await client.respond(to: permission, option: option.id) }
                                }
                            }
                            Button("取消请求") { run { try await client.respond(to: permission, option: nil) } }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 5)
                }

                if isLoaded {
                    HStack(spacing: 5) {
                        TextField("向 Agent 发送消息", text: Binding(
                            get: { workspace.drafts[id, default: ""] },
                            set: { workspace.drafts[id] = $0 }
                        ), prompt: Text("向 Agent 发送消息").foregroundStyle(.primary.opacity(0.28)), axis: .vertical)
                        .focused($composerFocused)
                        .lineLimit(1...6)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .medium))
                        .tint(.primary)
                        .padding(.vertical, 6)
                        if isPrompting {
                            Button { run { try await client.cancelPrompt(in: id) } } label: {
                                Label("停止", systemImage: "stop.fill").labelStyle(.iconOnly)
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.circle)
                            .help("停止回复")
                        } else if !workspace.drafts[id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button {
                                let text = workspace.drafts[id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !text.isEmpty else { return }
                                workspace.drafts[id] = ""
                                run { try await client.prompt(text, in: id) }
                            } label: {
                                Image(systemName: "arrow.up.circle")
                                    .font(.system(size: 21, weight: .medium))
                                    .foregroundStyle(LinearGradient(
                                        colors: [
                                            Color(red: 0.27, green: 0.60, blue: 0.66),
                                            Color(red: 0.74, green: 0.53, blue: 0.34),
                                            Color(red: 0.80, green: 0.47, blue: 0.56)
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing))
                                    .frame(width: 25, height: 28)
                            }
                            .buttonStyle(ComposerSendStyle())
                            .accessibilityLabel("发送")
                            .keyboardShortcut(.return, modifiers: .command)
                            .help("发送消息（⌘↩）")
                            .disabled(workspace.drafts[id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workspace.managing)
                        }
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 5)
                    .frame(minHeight: 32)
                    .background { ComposerSurface(focused: composerFocused) }
                    .frame(maxWidth: 390)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                } else {
                    Button("加载会话") { manage { try await client.load(id) } }
                        .disabled(workspace.managing)
                        .padding()
                }
            }
        }
        .navigationTitle(session.title)
        .toolbar {
            if isLoaded {
                Button {
                    manage { try await client.close(id) }
                } label: {
                    Label("释放会话", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .disabled(workspace.managing || isPrompting)
            }
        }
    }

    private func messageRow(_ entry: ACPEntry) -> some View {
        let isUser = entry.role == "你"
        let isAgent = entry.role == "Agent"
        return VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
            if !isUser {
                Label(entry.role, systemImage: isAgent ? "sparkles" : entry.role == "工具" ? "wrench" : "text.alignleft")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(entry.text)
                .font(isUser || isAgent ? .body : .callout)
                .textSelection(.enabled)
                .padding(.horizontal, isUser ? 14 : 0)
                .padding(.vertical, isUser ? 10 : 0)
                .background(isUser ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 17))
                .accessibilityLabel(isUser ? "你：\(entry.text)" : entry.text)
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private func manage(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !workspace.managing else { return }
        workspace.managing = true
        run {
            defer { workspace.managing = false }
            try await operation()
        }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await operation() }
            catch { workspace.failure = error.localizedDescription }
        }
    }
}

#Preview {
    ContentView()
}

private struct ComposerSendStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.9 : 1)
    }
}

private struct ComposerSurface: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var scheme

    let focused: Bool

    var body: some View {
        let outline = RoundedRectangle(cornerRadius: 24, style: .continuous)
        let base = scheme == .dark ? Color(white: 0.14) : .white
        Group {
            if focused && scenePhase == .active {
                TimelineView(.animation(minimumInterval: 1 / 24, paused: reduceMotion)) { frame in
                    let drift = reduceMotion ? 0 : sin(frame.date.timeIntervalSinceReferenceDate * .pi / 22)
                    let wash = LinearGradient(stops: [
                        .init(color: Color(red: 0.53, green: 0.88, blue: 0.94), location: 0),
                        .init(color: Color(red: 1, green: 0.86, blue: 0.64), location: 0.46 + 0.12 * drift),
                        .init(color: Color(red: 0.99, green: 0.66, blue: 0.77), location: 1)
                    ], startPoint: .leading, endPoint: .trailing)
                    ZStack {
                        outline.stroke(wash, lineWidth: 6 + drift).blur(radius: 7)
                        outline.fill(base)
                        outline.fill(wash.opacity(scheme == .dark ? 0.15 : 0.25))
                        outline.fill(LinearGradient(colors: [.clear, .purple.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                        outline.strokeBorder(.white.opacity(scheme == .dark ? 0.55 : 0.96), lineWidth: 1.5)
                    }
                }
            } else {
                outline.fill(base)
                    .overlay { outline.strokeBorder(.secondary.opacity(0.25), lineWidth: 1) }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#if os(macOS)
private struct SessionPreviewAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        if let next = nextValue() { value = next }
    }
}
#endif
