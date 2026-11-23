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
    var sessionLoadFailure: (id: String, error: Error)?
    var defaultProject: ACPProject?
    var activeProject: ACPProject?
    var addedProjects: [ACPProject] = []
    var expandedProjects: Set<ACPProject> = []
    var drafts: [String: String] = [:]
    var draftAttachments: [String: [ACPAttachment]] = [:]
    var managing = false
    var failure: String?
    var preferredColumn: NavigationSplitViewColumn = .detail
}

private struct ServerWorkspace<Header: View, TrailingAction: View>: View {
    let client: ACPClient
    @Bindable var workspace: ServerWorkspaceState
    @Binding var columns: NavigationSplitViewVisibility
    let removeServer: () -> Void
    @ViewBuilder let header: () -> Header
    @ViewBuilder let trailingAction: () -> TrailingAction
    @State private var importing = false
    @State private var choosingProject = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(RemoteTerminalWindows.self) private var terminalWindows
#if os(macOS)
    @Environment(\.openWindow) private var openWindow
#else
    @State private var terminalSession: RemoteTerminalWindows.Session?
#endif
    @State private var sessionToRename: ACPSession?
    @State private var sessionName = ""

    private var projects: [ACPProject] {
        guard let initial = workspace.defaultProject else { return [] }
        return [initial] + workspace.addedProjects.filter { $0 != initial }
    }
    @State private var hoveredSession: String?
    @State private var sessionToDelete: ACPSession?

    var body: some View {
        workspaceLayout
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
                    workspace.draftAttachments.removeValue(forKey: session.id)
                    if workspace.selection == session.id {
                        workspace.selection = nil
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: { session in
            Text("从服务器的会话列表中删除「\(session.title)」？")
        }
        .alert("重命名会话", isPresented: Binding(
            get: { sessionToRename != nil },
            set: { if !$0 { sessionToRename = nil } }
        ), presenting: sessionToRename) { session in
            TextField("会话名称", text: $sessionName)
            Button("保存") {
                let title = sessionName
                manage { try await client.renameSession(session, to: title) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("取消", role: .cancel) {}
        }
        .task(id: projectsToSync) { await syncProjectTitles() }
        .sheet(isPresented: $choosingProject) {
            RemoteDirectoryPicker(client: client, projects: projects, defaultPath: workspace.defaultProject?.path,
                                  select: addProject)
        }
#if !os(macOS)
        .sheet(item: $terminalSession) { session in
            RemoteTerminalWindow(session: session)
        }
#endif
        .onChange(of: workspace.selection, initial: true) { _, id in
            workspace.sessionLoadFailure = nil
            if let id, let project = projects.first(where: { client.projectSessionIDs[$0]?.contains(id) == true }) {
                workspace.activeProject = project
            }
            openSelectedSession()
        }
#if os(macOS)
        .onChange(of: workspace.activeProject, initial: true) { _, project in
            guard terminalWindows.isPresented, client.supportsRemoteShell, let project else { return }
            do { try terminalWindows.select(client, project: project) }
            catch { workspace.failure = error.localizedDescription }
        }
#endif
        .onChange(of: workspace.managing) { _, managing in
            if !managing { openSelectedSession() }
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
                choosingProject = false
                sessionToRename = nil
                workspace.selection = nil
                workspace.sessionLoadFailure = nil
                workspace.defaultProject = nil
                workspace.activeProject = nil
                workspace.addedProjects.removeAll()
                workspace.expandedProjects.removeAll()
            }
        }
    }

    private var workspaceLayout: some View {
        NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $workspace.preferredColumn) {
            List(selection: $workspace.selection) {
                Section("项目") {
                    if projects.isEmpty {
                        Text(client.connected ? "正在加载项目…" : "连接服务器后显示项目")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(projects) { project in
                        projectRow(project)
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
                        Button {
                            if let project = workspace.activeProject { createSession(in: project) }
                        } label: {
                            Label("新建会话", systemImage: "square.and.pencil")
                        }
                        .help(workspace.activeProject.map { "在「\($0.name)」中创建会话" } ?? "新建会话")
                        .disabled(workspace.activeProject == nil)
                        Spacer()
                        if client.supportsDirectoryListing {
                            Button { choosingProject = true } label: {
                                Label("添加项目", systemImage: "folder.badge.plus").labelStyle(.iconOnly)
                            }
                            .help("添加远程项目")
                        }
                        if client.supportsSessionList {
                            Button {
                                if let project = workspace.activeProject { refresh(project) }
                            } label: {
                                Label("刷新会话", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                            }
                            .help("刷新当前项目的会话")
                            .disabled(workspace.activeProject == nil)
                        }
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
                            Text("从边栏展开项目并选择会话，或在项目中创建会话。")
                        }
                    } else {
                        connection
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) {
                if client.supportsRemoteShell, let project = workspace.activeProject {
                    terminalButton(project)
                        .padding(.trailing, 14)
                        .padding(.bottom, 16)
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

    private var projectsToSync: Set<ACPProject> {
        guard client.connected, client.supportsSessionList, scenePhase == .active else { return [] }
        return Set(projects).intersection(workspace.expandedProjects)
    }

    private func syncProjectTitles() async {
        let visibleProjects = projectsToSync
        guard !visibleProjects.isEmpty else { return }
        // An Agent may send title updates only to the connection that owns the loaded session.
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(15)) }
            catch { return }
            for project in visibleProjects {
                guard !Task.isCancelled, client.connected else { return }
                if !workspace.managing { try? await client.listSessions(in: project, titlesOnly: true) }
            }
        }
    }

    private func projectRow(_ project: ACPProject) -> some View {
        let isExpanded = Binding(
            get: { workspace.expandedProjects.contains(project) },
            set: { expanded in
                if expanded {
                    workspace.expandedProjects.insert(project)
                    workspace.activeProject = project
                    if client.projectSessionIDs[project] == nil { refresh(project) }
                } else {
                    workspace.expandedProjects.remove(project)
                }
            }
        )
        return DisclosureGroup(isExpanded: isExpanded) {
            let sessions = client.sessions(in: project)
            if sessions.isEmpty {
                Text("暂无会话").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(sessions) { session in
                Group {
#if os(macOS)
                    sessionRow(session).tag(session.id)
#else
                    NavigationLink(value: session.id) { sessionRow(session) }
#endif
                }
                .contextMenu {
                    if client.supportsSessionRename {
                        Button("重命名会话…", systemImage: "pencil") {
                            sessionName = session.title
                            sessionToRename = session
                        }
                        .disabled(workspace.managing)
                    }
                    Button("删除会话", systemImage: "trash", role: .destructive) {
                        sessionToDelete = session
                    }
                    .disabled(!client.supportsSessionDelete || workspace.managing || client.prompting.contains(session.id))
                }
            }
        } label: {
            Label(project.name, systemImage: workspace.activeProject == project ? "folder.fill" : "folder")
                .lineLimit(1)
#if os(macOS)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(TapGesture(count: 2).exclusively(before: TapGesture()).onEnded { tap in
                    workspace.activeProject = project
                    if let currentSession = workspace.selection,
                       client.projectSessionIDs[project]?.contains(currentSession) != true {
                        workspace.selection = nil
                    }
                    if case .first = tap { isExpanded.wrappedValue.toggle() }
                })
#endif
                .help(project.path ?? "服务器默认项目")
                .contextMenu {
                    Button("新建会话", systemImage: "square.and.pencil") { createSession(in: project) }
                        .disabled(workspace.managing)
                    if client.supportsSessionList {
                        Button("刷新会话", systemImage: "arrow.clockwise") { refresh(project) }
                            .disabled(workspace.managing)
                    }
                    if project != workspace.defaultProject {
                        Button("从侧边栏移除项目", systemImage: "minus.circle") { removeProject(project) }
                            .disabled(workspace.managing)
                    }
                }
        }
    }

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
                let defaultPath = client.supportsDirectoryListing ? try? await client.listDirectories().path : nil
                guard client.connected else { return }
                let project = ACPProject(path: defaultPath)
                let saved = UserDefaults.standard.dictionary(forKey: "acpProjectPaths") ?? [:]
                let paths = saved[client.address] as? [String] ?? []
                workspace.addedProjects = paths.map { ACPProject(path: $0) }
                workspace.defaultProject = project
                workspace.activeProject = project
                workspace.expandedProjects = [project]
                try await client.listSessions(in: project)
            }
        } label: {
            Label("连接", systemImage: "arrow.right")
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .disabled(client.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                  client.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func refresh(_ project: ACPProject) {
        manage { try await client.listSessions(in: project) }
    }

    private func addProject(_ path: String) {
        let project = ACPProject(path: path)
        manage {
            try await client.listSessions(in: project)
            if !projects.contains(project) {
                workspace.addedProjects.append(project)
                saveProjects()
            }
            workspace.activeProject = project
            workspace.expandedProjects.insert(project)
        }
    }

    private func removeProject(_ project: ACPProject) {
        workspace.addedProjects.removeAll { $0 == project }
        workspace.expandedProjects.remove(project)
        if workspace.activeProject == project { workspace.activeProject = workspace.defaultProject }
        if let selection = workspace.selection, client.projectSessionIDs[project]?.contains(selection) == true {
            workspace.selection = nil
        }
        saveProjects()
    }

    private func saveProjects() {
        var saved = UserDefaults.standard.dictionary(forKey: "acpProjectPaths") ?? [:]
        saved[client.address] = workspace.addedProjects.compactMap(\.path)
        UserDefaults.standard.set(saved, forKey: "acpProjectPaths")
    }

    private func createSession(in project: ACPProject) {
        manage {
            let id = try await client.createSession(in: project)
            workspace.activeProject = project
            workspace.expandedProjects.insert(project)
            workspace.selection = id
            workspace.preferredColumn = .detail
        }
    }

    private func openSelectedSession() {
        guard client.connected, client.supportsSessionLoad, let id = workspace.selection,
              !client.loaded.contains(id), workspace.sessionLoadFailure?.id != id,
              let session = client.sessions.first(where: { $0.id == id }) else { return }
        manage {
            guard client.connected, workspace.selection == id else { return }
            do {
                try await client.load(session)
            } catch {
                if client.connected, workspace.selection == id {
                    workspace.sessionLoadFailure = (id, error)
                }
            }
        }
    }

    private func conversation(_ session: ACPSession) -> some View {
        let id = session.id
        let entries = client.entries[id] ?? []
        let isLoaded = client.loaded.contains(id)
        let isPrompting = client.prompting.contains(id)
        let permissions = client.permissions.filter { $0.sessionID == id }
        let options = client.sessionOptions[id]
        let showsSettings = options?.config.map { !$0.isEmpty } ?? (options?.modes?.availableModes.isEmpty == false)
        let settingsMargin = showsSettings ? ConversationLayout.settingsGutter : 0
        let terminalMargin: CGFloat = client.supportsRemoteShell ? 46 : 0
        let horizontalMargin = ConversationLayout.horizontalMargin + settingsMargin + terminalMargin
        return VStack(spacing: 0) {
            if isLoaded {
                SessionTranscript(
                    entries: entries, isResponding: isPrompting, permissions: permissions,
                    horizontalMargin: horizontalMargin, composerSpacing: ConversationLayout.composerSpacing
                ) { permission, option in
                    run { try await client.respond(to: permission, option: option) }
                }
                .id(id)

                ZStack(alignment: .bottomTrailing) {
                    SessionComposer(
                        draft: Binding(
                            get: { workspace.drafts[id, default: ""] },
                            set: { workspace.drafts[id] = $0 }
                        ),
                        attachments: workspace.draftAttachments[id, default: []],
                        supportsImages: client.supportsPromptImages,
                        supportsFiles: client.supportsPromptFiles,
                        commands: options?.commands ?? [],
                        isPrompting: isPrompting,
                        isManaging: workspace.managing,
                        horizontalMargin: horizontalMargin,
                        send: { sendDraft(in: id) },
                        stop: { run { try await client.cancelPrompt(in: id) } },
                        addAttachments: { addAttachments($0, in: id) },
                        removeAttachment: { attachment in workspace.draftAttachments[id]?.removeAll { $0.id == attachment } },
                        attachmentFailed: { workspace.failure = $0.localizedDescription }
                    )
                    .id(id)
                    .frame(maxWidth: .infinity)
                    if showsSettings, let options {
                        sessionSettings(options, in: id)
                            .padding(.trailing, 20 + terminalMargin)
                            .padding(.bottom, 16)
                    }
                }
            } else {
                sessionOpeningStatus(for: id)
            }
        }
        .navigationTitle(session.title)
        .toolbar {
            if isLoaded {
                ToolbarItem {
                    Button {
                        manage {
                            try await client.close(id)
                            if workspace.selection == id { workspace.selection = nil }
                        }
                    } label: {
                        Label("释放会话", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .disabled(workspace.managing || isPrompting)
                }
            }
        }
    }

    private func terminalButton(_ project: ACPProject) -> some View {
        Button {
            do {
#if os(macOS)
                try terminalWindows.select(client, project: project)
                openWindow(id: "remote-terminal")
#else
                terminalSession = try terminalWindows.session(for: client, project: project)
#endif
            } catch {
                workspace.failure = error.localizedDescription
            }
        } label: {
            Label("远程终端", systemImage: "terminal")
                .labelStyle(.iconOnly)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .help("打开远程终端")
    }

    @ViewBuilder
    private func sessionOpeningStatus(for id: String) -> some View {
        if !client.supportsSessionLoad {
            ContentUnavailableView("服务器不支持打开历史会话", systemImage: "bubble.left")
        } else if let failure = workspace.sessionLoadFailure, failure.id == id {
            let acpError = failure.error as? ACPFailure
            let occupied = acpError?.isSessionOccupied == true
            ContentUnavailableView {
                if acpError?.isCodexSessionInUse == true {
                    Label("会话正在 Codex 中使用", systemImage: "person.2")
                } else {
                    Label(occupied ? "会话正在其他客户端使用" : "无法打开会话",
                          systemImage: occupied ? "person.2" : "exclamationmark.circle")
                }
            } description: {
                if acpError?.isCodexSessionInUse == true {
                    Text("请先在远程 Codex 中关闭这条会话，再回到这里重试。")
                } else {
                    Text(occupied ? "请在另一客户端释放会话后重试。" : failure.error.localizedDescription)
                }
            } actions: {
                Button("重试") {
                    workspace.sessionLoadFailure = nil
                    openSelectedSession()
                }
                .buttonStyle(.bordered)
                .disabled(workspace.managing)
            }
        } else {
            ProgressView("正在打开会话…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func sendDraft(in id: String) {
        let draft = workspace.drafts[id, default: ""]
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = workspace.draftAttachments[id, default: []]
        let command = ACPCommand.commandText(in: text)
        guard !text.isEmpty || !attachments.isEmpty, command != "/", client.loaded.contains(id),
              !client.prompting.contains(id), !workspace.managing else { return }
        let invocation = command?.prefix { !$0.isWhitespace } ?? ""
        let isKnownCommand = client.sessionOptions[id]?.commands.contains { $0.invocation == invocation } == true
        let prompt = isKnownCommand ? command ?? text : text
        workspace.drafts[id] = ""
        workspace.draftAttachments[id] = []
        run {
            do {
                try await client.prompt(prompt, attachments: attachments, in: id)
            } catch {
                let nextDraft = workspace.drafts[id, default: ""]
                workspace.drafts[id] = [draft, nextDraft].filter { !$0.isEmpty }.joined(separator: "\n\n")
                workspace.draftAttachments[id, default: []].insert(contentsOf: attachments, at: 0)
                throw error
            }
        }
    }

    private func addAttachments(_ attachments: [ACPAttachment], in id: String) {
        guard client.loaded.contains(id), !attachments.isEmpty else { return }
        var pending = workspace.draftAttachments[id, default: []]
        var byteCount = pending.reduce(0) { $0 + $1.byteCount }
        for attachment in attachments {
            let isImage = attachment.preview.isImage
            guard isImage ? client.supportsPromptImages : client.supportsPromptFiles else {
                workspace.failure = (isImage ? AttachmentError.unsupportedImage : AttachmentError.unsupportedFile).localizedDescription
                continue
            }
            guard byteCount + attachment.byteCount <= ACPAttachment.maxTotalBytes else {
                workspace.failure = AttachmentError.messageTooLarge.localizedDescription
                continue
            }
            pending.append(attachment)
            byteCount += attachment.byteCount
        }
        workspace.draftAttachments[id] = pending
    }

    private func sessionSettings(_ options: ACPSessionOptions, in id: String) -> some View {
        Menu {
            if let config = options.config {
                ForEach(config) { option in
                    switch option.control {
                    case let .select(current, groups):
                        Menu {
                            ForEach(groups) { group in
                                Section {
                                    ForEach(group.choices) { choice in
                                        Button {
                                            manage { try await client.setConfigOption(option, value: choice.id, in: id) }
                                        } label: {
                                            if choice.id == current { Label(choice.name, systemImage: "checkmark") }
                                            else { Text(choice.name) }
                                        }
                                        .help(choice.description ?? choice.name)
                                    }
                                } header: {
                                    if let name = group.name { Text(name) }
                                }
                            }
                        } label: {
                            Text("\(option.name) · \(option.currentLabel)")
                        }
                        .help(option.description ?? option.name)
                    case let .boolean(enabled):
                        Toggle(option.name, isOn: Binding(
                            get: { enabled },
                            set: { value in manage { try await client.setConfigOption(option, enabled: value, in: id) } }
                        ))
                        .help(option.description ?? option.name)
                    }
                }
            } else if let modes = options.modes {
                ForEach(modes.availableModes) { mode in
                    Button {
                        manage { try await client.setMode(mode.id, in: id) }
                    } label: {
                        if mode.id == options.currentModeID { Label(mode.name, systemImage: "checkmark") }
                        else { Text(mode.name) }
                    }
                    .help(mode.description ?? mode.name)
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        }
#if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
#endif
        .frame(width: 32, height: 32)
        .background(.quaternary.opacity(0.5), in: Circle())
        .accessibilityLabel("会话设置")
        .help("切换模型、推理强度和会话模式")
        .disabled(workspace.managing)
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
        .environment(RemoteTerminalWindows())
}

#if os(macOS)
private struct SessionPreviewAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        if let next = nextValue() { value = next }
    }
}
#endif
