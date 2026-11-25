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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var servers: [Server]

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: "mqttServerAddresses") ?? [ACPClient.defaultAddress]
        let addresses = saved.isEmpty ? [""] : saved
        let restored = addresses.map { address in
            Server(client: ACPClient(address: address, fingerprint: UserDefaults.standard.string(forKey: "goPin." + address) ?? ""))

        }
        _servers = State(initialValue: restored)
        let selected = UserDefaults.standard.string(forKey: "mqttSelectedServerAddress")
        _selectedServer = State(initialValue: restored.first { $0.client.address == selected }?.id)
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
#if !os(iOS) && !os(macOS)
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
                    .frame(width: min(CGFloat(servers.count) * 180, max(132, windowWidth * 0.4)), height: 32)
#elseif os(iOS)
                serverMenu
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
        .onChange(of: current.client.address) { _, address in
            if !address.isEmpty { UserDefaults.standard.set(address, forKey: "mqttSelectedServerAddress") }
        }
        .onChange(of: servers.map { $0.client.address }) { _, addresses in
            let saved = addresses.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            UserDefaults.standard.set(saved, forKey: "mqttServerAddresses")
        }
        .confirmationDialog("移除服务器？", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("移除服务器", role: .destructive, action: removeTab)
        } message: {
            if let server = servers.first(where: { $0.id == pendingRemoval }) {
                Text("移除「\(server.label)」的连接配置和本地草稿。服务器上的会话记录会保留。")
            }
        }
    }

#if os(iOS)
    private var serverMenu: some View {
        Menu {
            Picker("当前服务器", selection: Binding(get: { current.id }, set: { selectedServer = $0 })) {
                ForEach(servers) { server in
                    let pending = server.client.permissions.count
                    Text(pending == 0 ? server.client.displayName : "\(server.client.displayName) · \(pending) 项待审批")
                        .tag(server.id)
                }
            }
            .pickerStyle(.inline)
            Button("添加服务器", systemImage: "plus", action: addServer)
            if current.client.available {
                Button("断开连接", systemImage: "power", role: .destructive) {
                    UserDefaults.standard.set(true, forKey: "acpManuallyDisconnected." + current.client.address)
                    current.client.disconnect()
                }
            }
            if servers.count > 1 || !current.client.address.isEmpty {
                Button("移除服务器", systemImage: "trash", role: .destructive) {
                    requestClose(current, confirmRemoval: true)
                }
            }
        } label: {
            Label("切换服务器", systemImage: "server.rack")
        }
        .accessibilityValue(current.client.displayName)
    }
#endif

    private var newTabButton: some View {
        Button(action: addServer) {
            Label("新建服务器标签页", systemImage: "plus")
                .labelStyle(.iconOnly)
        }
        .keyboardShortcut("t", modifiers: .command)
        .help("新建服务器标签页")
    }

    private func addServer() {
        let server = Server(client: ACPClient(address: ""))
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
            }
            .scrollIndicators(.hidden)
            .onChange(of: current.id, initial: true) { _, id in
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
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
        let title = server.client.offline ? server.client.status : server.client.displayName

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
        .workspaceTabHighlight(selected: selected && servers.count > 1, hovered: hoveredTab == server.id)
        .contentShape(Capsule())
        .onHover { hovering in
            if hovering {
                hoveredTab = server.id
            } else if hoveredTab == server.id {
                hoveredTab = nil
            }
        }
        .contextMenu {
            if server.client.available {
                Button("断开连接", systemImage: "power", role: .destructive) {
                    UserDefaults.standard.set(true, forKey: "acpManuallyDisconnected." + server.client.address)
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
        let address = server.client.address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.isEmpty && !servers.contains(where: { $0.id != server.id && $0.client.address.trimmingCharacters(in: .whitespacesAndNewlines) == address }) {
            UserDefaults.standard.removeObject(forKey: "goPin." + address)
        }
        if !servers.contains(where: { $0.id != server.id && $0.client.address == address }) {
            UserDefaults.standard.removeObject(forKey: "acpManuallyDisconnected." + address)
            UserDefaults.standard.removeObject(forKey: "acpLastSession." + address)
        }
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

enum SidebarExpansion {
    static func restore(server: String, projects: [ACPProject], defaultProject: ACPProject,
                        defaults: UserDefaults = .standard) -> Set<ACPProject> {
        guard let ids = defaults.stringArray(forKey: "acpExpandedProjects." + server) else {
            return [defaultProject]
        }
        let expanded = Set(ids)
        return Set(projects.filter { expanded.contains($0.id) })
    }

    static func save(_ projects: Set<ACPProject>, server: String, defaults: UserDefaults = .standard) {
        defaults.set(projects.map(\.id).sorted(), forKey: "acpExpandedProjects." + server)
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
    var projectSectionExpanded = true
    var drafts: [String: String] = [:]
    var draftAttachments: [String: [ACPAttachment]] = [:]
    var restoredCredential = false
    var pairedAddress = false
    var resumeConnection = false
    var managing = false
    var reconnectWhenIdle = false
    var failure: String?
#if os(iOS)
    var preferredColumn: NavigationSplitViewColumn = .sidebar
#else
    var preferredColumn: NavigationSplitViewColumn = .detail
#endif
}

private struct ServerWorkspace<Header: View, TrailingAction: View>: View {
    let client: ACPClient
    @Bindable var workspace: ServerWorkspaceState
    @Binding var columns: NavigationSplitViewVisibility
    let removeServer: () -> Void
    @ViewBuilder let header: () -> Header
    @ViewBuilder let trailingAction: () -> TrailingAction
    @State private var publicKey = ""
    @State private var choosingProject = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        return ([initial] + workspace.addedProjects).filter { !$0.isDefaultWorkspaceRoot }
    }
    @State private var sessionToDelete: ACPSession?

#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private enum ConnectionField { case address, fingerprint }
    @FocusState private var connectionFocus: ConnectionField?
#endif

    @ViewBuilder private var workspaceContent: some View {
#if os(iOS)
        if client.available {
            if horizontalSizeClass == .compact {
                NavigationStack(path: phonePath) {
                    projectSidebar(selection: nil)
                        .navigationDestination(for: String.self) { id in
                            if let session = client.directory.session(id: id) {
                                conversation(session)
                            }
                        }
                }
            } else {
                workspaceLayout
            }
        } else {
            NavigationStack {
                connection
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { header() } }
            }
        }
#else
        workspaceLayout
#endif
    }

#if os(iOS)
    private var phonePath: Binding<[String]> {
        Binding {
            workspace.selection.map { [$0] } ?? []
        } set: { path in
            guard client.available, scenePhase == .active, workspace.selection != path.last else { return }
            if let id = path.last {
                workspace.selection = id
            } else {
                forgetSelection()
            }
        }
    }
#endif

    var body: some View {
        workspaceContent
        .confirmationDialog(
            "永久删除会话？",
            isPresented: Binding(get: { sessionToDelete != nil }, set: { if !$0 { sessionToDelete = nil } }),
            titleVisibility: .visible,
            presenting: sessionToDelete
        ) { session in
            Button("永久删除会话", role: .destructive) {
                manage {
                    try await client.deleteSession(session.id)
                    workspace.drafts.removeValue(forKey: session.id)
                    workspace.draftAttachments.removeValue(forKey: session.id)
                    if workspace.selection == session.id {
                        forgetSelection()
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: { session in
            Text("「\(session.title)」的 Agent 会话和服务端历史会被永久删除，其他设备同步后也会移除。此操作无法撤销。")
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
        .onAppear {
            if !workspace.restoredCredential {
                workspace.restoredCredential = true
                let address = client.address.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !address.isEmpty else { return }
                workspace.pairedAddress = UserDefaults.standard.string(forKey: "goPin." + address) == client.fingerprint && !client.fingerprint.isEmpty
                workspace.resumeConnection = workspace.pairedAddress
                if workspace.pairedAddress && !UserDefaults.standard.bool(forKey: "acpManuallyDisconnected." + address) {
                    do {
                        try client.restoreCache()
                        restoreProjects()
                        if let project = workspace.activeProject {
                            Task { try? await client.listSessions(in: project); openSelectedSession() }
                        }
                    } catch { workspace.failure = error.localizedDescription }
                }
            }
            reconnectIfNeeded()
        }
        .onChange(of: client.offline) { _, offline in
            if offline && !workspace.managing && scenePhase == .active { reconnectIfNeeded() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { client.catchUp(); reconnectIfNeeded() }
        }
        .task(id: client.offline && scenePhase == .active) {
            while client.offline && scenePhase == .active {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                if !workspace.managing { reconnectIfNeeded() }
            }
        }
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
            if let id, let project = projects.first(where: { client.directory.contains(id, in: $0) }) {
                workspace.activeProject = project
                if let session = client.directory.session(id: id) {
                    let location = ["id": id, "project": project.id, "title": session.title, "cwd": session.cwd]
                    UserDefaults.standard.set(location, forKey: "acpLastSession." + client.address)
                }
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
            guard !managing else { return }
            if workspace.reconnectWhenIdle {
                workspace.reconnectWhenIdle = false
                if scenePhase == .active { reconnectIfNeeded() }
            }
            openSelectedSession()
        }
        .alert("操作失败", isPresented: Binding(get: { workspace.failure != nil }, set: { if !$0 { workspace.failure = nil } })) {
            Button("确定") { workspace.failure = nil }
        } message: {
            Text(workspace.failure ?? "")
        }
        .onChange(of: client.available) { _, available in
            if !available {
#if os(iOS)
                workspace.preferredColumn = .sidebar
                terminalSession = nil
#endif
                choosingProject = false
                sessionToRename = nil
                workspace.selection = nil
                workspace.sessionLoadFailure = nil
                workspace.defaultProject = nil
                workspace.activeProject = nil
                workspace.addedProjects.removeAll()
                workspace.expandedProjects.removeAll()
                if scenePhase == .active { reconnectIfNeeded() }
            }
        }
    }

    private func projectSidebar(selection: Binding<String?>?) -> some View {
        sidebarContent(selection: selection)
#if os(macOS)
        .toolbar(removing: .sidebarToggle)
#endif
        .listStyle(.sidebar)
#if os(iOS)
        .navigationTitle("会话")
        .navigationSubtitle(client.displayName)
        .refreshable { await refreshActiveProject() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { header() }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if client.supportsDirectoryListing || client.supportsRemoteShell || client.supportsSessionList {
                    Menu {
                        if client.supportsDirectoryListing {
                            Button("添加项目", systemImage: "folder.badge.plus") { choosingProject = true }
                        }
                        if let project = workspace.activeProject {
                            if client.supportsSessionList {
                                Button("刷新会话", systemImage: "arrow.clockwise") { refresh(project) }
                            }
                            if client.supportsRemoteShell {
                                Button("远程终端", systemImage: "terminal") { openTerminal(project) }
                            }
                        }
                    } label: { Label("项目操作", systemImage: "ellipsis") }
                    .disabled(workspace.managing)
                }
                if projects.count > 1 {
                    Menu {
                        Section("选择项目") {
                            ForEach(projects) { project in
                                Button(project.name) { createSession(in: project) }
                            }
                        }
                    } label: { Label("新建会话", systemImage: "square.and.pencil") }
                    .disabled(workspace.managing)
                } else {
                    Button {
                        if let project = projects.first { createSession(in: project) }
                    } label: { Label("新建会话", systemImage: "square.and.pencil") }
                    .disabled(!client.connected || projects.isEmpty || workspace.managing)
                }
            }
        }
#else
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
#if os(macOS)
                .padding(.leading, 16)
                .padding(.trailing, 8.5)
#else
                .padding(.horizontal, 16)
#endif
                .padding(.vertical, 10)
            }
        }
#if !os(macOS)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if client.available {
                serverBar
            }
            if !client.available {
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
        .modifier(FloatingSidebar())
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
                .sharedBackgroundVisibility(.hidden)
            }
#endif
        }
#endif
    }

    private func setSectionExpanded(_ expanded: Bool) {
        workspace.projectSectionExpanded = expanded
        if client.connected {
            UserDefaults.standard.set(expanded, forKey: "acpProjectSectionExpanded." + client.address)
        }
    }

    private var sidebarGroups: [SidebarProjectGroup] {
        projects.map { project in
            let expanded = workspace.expandedProjects.contains(project)
            return SidebarProjectGroup(project: project, expanded: expanded,
                                       revision: expanded ? client.directory.revision(in: project) : 0,
                                       rows: expanded ? client.directory.rows(in: project) : [])
        }
    }

    private func discloseProject(_ project: ACPProject, expanded: Bool) {
        setProject(project, expanded: expanded)
        if expanded { workspace.activeProject = project }
    }

    private func selectSession(_ session: ACPSession, in project: ACPProject) {
        guard client.directory.contains(session.id, in: project) else { return }
        workspace.activeProject = project
        workspace.selection = session.id
    }

    @ViewBuilder private func sidebarContent(selection: Binding<String?>?) -> some View {
#if os(macOS)
        MacSessionList(
            groups: sidebarGroups, sectionExpanded: workspace.projectSectionExpanded,
            connected: client.available, selection: workspace.selection, client: client,
            activeProject: { workspace.activeProject }, toggleSection: setSectionExpanded,
            toggleProject: discloseProject, activateProject: { project in
                workspace.activeProject = project
                if let id = workspace.selection, !client.directory.contains(id, in: project) { forgetSelection() }
            },
            select: selectSession, loadProject: loadProjectIfNeeded,
            menuForProject: projectMenuItems, menuForSession: sessionMenuItems
        )
#elseif os(iOS)
        if horizontalSizeClass == .compact {
            PhoneSessionList(
                groups: sidebarGroups, sectionExpanded: workspace.projectSectionExpanded, client: client,
                activeProject: { workspace.activeProject },
                toggleSection: { setSectionExpanded(!workspace.projectSectionExpanded) },
                toggleProject: discloseProject, loadProject: loadProjectIfNeeded, select: selectSession,
                menuForProject: projectMenuItems, menuForSession: sessionMenuItems,
                refresh: refreshActiveProject
            )
        } else {
            sidebarList(selection: selection)
        }
#else
        sidebarList(selection: selection)
#endif
    }

#if !os(macOS)
    private func sidebarList(selection: Binding<String?>?) -> some View {
        List(selection: selection) {
            Section("项目", isExpanded: Binding(
                get: { workspace.projectSectionExpanded },
                set: { expanded in
                    setSectionExpanded(expanded)
                }
            )) {
                if projects.isEmpty {
                    Text(client.connected ? "添加项目后在此显示" : "连接服务器后显示项目")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(projects) { project in
                    projectRow(project)
                }
            }
        }
    }

#endif

#if os(iOS)
    private func refreshActiveProject() async {
        guard client.supportsSessionList, !workspace.managing, let project = workspace.activeProject else { return }
        do { try await client.refreshSessions(in: project) }
        catch { if client.connected && !Task.isCancelled { workspace.failure = error.localizedDescription } }
    }
#endif

    private func loadProjectIfNeeded(_ project: ACPProject) async {
        guard client.supportsSessionList, !client.directory.hasListed(project) else { return }
        do { try await client.listSessions(in: project) }
        catch { if client.connected && !Task.isCancelled { workspace.failure = error.localizedDescription } }
    }

    private var workspaceLayout: some View {
        NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $workspace.preferredColumn) {
            projectSidebar(selection: $workspace.selection)
        } detail: {
            Group {
                if let id = workspace.selection, let session = client.directory.session(id: id) {
                    conversation(session)
                } else {
                    if client.available {
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
#if !os(iOS)
            .overlay(alignment: .bottomTrailing) {
                if client.supportsRemoteShell, let project = workspace.activeProject {
                    terminalButton(project)
                        .padding(.trailing, 14)
                        .padding(.bottom, 16)
                }
            }
#endif
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
        .overlayPreferenceValue(SessionPreviewAnchor.self) { preview in
            if let preview, sessionToDelete == nil {
                let session = preview.session
                GeometryReader { geometry in
                    let sidebar = geometry[preview.anchor]
                    let row = preview.row.offsetBy(dx: sidebar.minX, dy: sidebar.minY)
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
    private struct FloatingSidebar: ViewModifier {
        @ViewBuilder
        func body(content: Content) -> some View {
            if #available(macOS 27.0, *) {
                // Tahoe draws its own floating sidebar. On newer systems the default is edge-to-edge.
                let panel = RoundedRectangle(cornerRadius: 16, style: .continuous)
                let inset: CGFloat = 8
                content
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, inset)
                    .padding(.bottom, inset)
                    .background {
                        Color.clear
                            .glassEffect(.regular, in: panel)
                            .padding(inset)
                            .overlay {
                                GeometryReader { geometry in
                                    let bounds = CGRect(origin: .zero, size: geometry.size)
                                    Path { path in
                                        path.addRect(bounds)
                                        path.addPath(panel.path(in: bounds.insetBy(dx: inset, dy: inset)))
                                    }
                                    .fill(.background, style: FillStyle(eoFill: true))
                                }
                            }
                            .ignoresSafeArea(.container, edges: [.top, .bottom])
                            .allowsHitTesting(false)
                    }
            } else {
                content
            }
        }
    }

    private var sidebarActions: some View {
        // Each 28 pt target adds 4.5 pt on either side of its 19 pt symbol.
        HStack(alignment: .center, spacing: 11) {
            Button(action: removeServer) {
                sidebarActionIcon("minus.rectangle")
            }
            .accessibilityLabel("移除当前服务器")
            .disabled(client.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("移除当前服务器")

            sidebarToggle(showing: true)
        }
        .buttonStyle(SidebarHoverStyle())
        .padding(.leading, 3)
        .padding(.trailing, 6)
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
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
    }

    private func sidebarToggle(showing: Bool) -> some View {
        let title = showing ? "隐藏边栏" : "显示边栏"
        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
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

#if !os(macOS)
    private func projectRow(_ project: ACPProject) -> some View {
        let isExpanded = Binding(
            get: { workspace.expandedProjects.contains(project) },
            set: { expanded in
                setProject(project, expanded: expanded)
                if expanded {
                    workspace.activeProject = project
                }
            }
        )
        return DisclosureGroup(isExpanded: isExpanded) {
            let sessions = client.directory.rows(in: project)
            if sessions.isEmpty {
                Text("暂无会话").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(sessions) { session in
                NavigationLink(value: session.id) {
                    SessionListRow(session: session, client: client, workspace: workspace)
                }
                .contextMenu { menuButtons(sessionMenuItems(session)) }
            }
        } label: {
            Label(project.name, systemImage: workspace.activeProject == project ? "folder.fill" : "folder")
                .lineLimit(1)
                .task(id: isExpanded.wrappedValue) {
                    if isExpanded.wrappedValue { await loadProjectIfNeeded(project) }
                }
                .help(project.path ?? "服务器默认项目")
                .contextMenu { menuButtons(projectMenuItems(project)) }
        }
    }

#endif

    private func projectMenuItems(_ project: ACPProject) -> [SidebarMenuItem] {
        var items = client.agents.map { agent in
            SidebarMenuItem("新建 " + agent + " 会话", "square.and.pencil", disabled: workspace.managing || !client.connected) {
                createSession(in: project, agent: agent)
            }
        }
        for agent in client.agents where client.connected {
            items.append(SidebarMenuItem("发现 " + agent + " 会话", "arrow.clockwise", disabled: workspace.managing) {
                manage { try await client.refreshSessions(in: project, agent: agent) }
            })
        }
        items.append(SidebarMenuItem(client.showingArchives ? "隐藏已归档会话" : "显示已归档会话", "archivebox", disabled: false) {
            client.toggleArchives()
        })
        if project != workspace.defaultProject {
            items.append(SidebarMenuItem("从侧边栏移除项目", "minus.circle", disabled: workspace.managing) { removeProject(project) })
        }
        return items
    }

    private func sessionMenuItems(_ session: ACPSession) -> [SidebarMenuItem] {
        var items: [SidebarMenuItem] = []
        if client.supportsSessionRename {
            items.append(SidebarMenuItem("重命名会话…", "pencil", disabled: workspace.managing) {
                sessionName = session.title
                sessionToRename = session
            })
        }
        let archived = client.isArchived(session.id)
        items.append(SidebarMenuItem(archived ? "取消归档" : "归档会话", "archivebox", disabled: !client.connected || workspace.managing || client.prompting.contains(session.id)) {
            manage {
                try await client.setArchived(!archived, in: session.id)
                if !archived && !client.showingArchives && workspace.selection == session.id { forgetSelection() }
            }
        })
        items.append(SidebarMenuItem("删除会话", "trash", destructive: true,
                                     disabled: !client.canDelete(session.id) || workspace.managing || client.prompting.contains(session.id)) {
            sessionToDelete = session
        })
        return items
    }

    private func menuButtons(_ items: [SidebarMenuItem]) -> some View {
        ForEach(items, id: \.title) { item in
            Button(item.title, systemImage: item.symbol, role: item.destructive ? .destructive : nil, action: item.perform)
                .disabled(item.disabled)
        }
    }

    private var serverBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(client.connected ? Color.green : Color.secondary)
                .accessibilityHidden(true)
            Text(client.status)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .accessibilityLabel(client.status)
            Spacer()
            Menu {
                if client.offline { Button("重新连接", systemImage: "arrow.clockwise") { connect(automatic: false) } }
                Button("断开连接", systemImage: "power", role: .destructive) {
                    UserDefaults.standard.set(true, forKey: "acpManuallyDisconnected." + client.address)
                    client.disconnect()
                }
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

    private var serverAddress: Binding<String> {
        Binding(get: { client.address }, set: { address in
            guard client.address != address else { return }
            if workspace.pairedAddress {
                client.fingerprint = ""
                workspace.pairedAddress = false
            }
            workspace.resumeConnection = false
            client.address = address
        })
    }

    private var connection: some View {
        @Bindable var client = client
#if os(iOS)
        let canConnect = !workspace.managing &&
            !client.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !client.fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Form {
            Section {
                TextField("mqtts://主机:8883/服务标识", text: serverAddress)
                    .accessibilityLabel("服务器地址")
                    .keyboardType(.URL)
                    .focused($connectionFocus, equals: .address)
                    .submitLabel(.next)
                    .onSubmit { connectionFocus = .fingerprint }
            } header: { Text("服务器地址") } footer: {
                Text("末尾的服务标识取自 Go 服务的 -host 参数。")
            }
            Section("证书指纹") {
                TextField("SHA-256 指纹", text: $client.fingerprint)
                    .focused($connectionFocus, equals: .fingerprint)
                    .submitLabel(.go)
                    .onSubmit {
                        if canConnect { connectionFocus = nil; connect(automatic: false) }
                    }
                pairButton
                Text("将公钥添加到服务器的 authorized_keys 后即可连接。").font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button {
                    connectionFocus = nil
                    connect(automatic: false)
                } label: {
                    HStack {
                        Spacer()
                        if workspace.managing { ProgressView() }
                        Text(workspace.managing ? "正在连接…" : "连接服务器").fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(!canConnect)
            }
        }
        .disabled(workspace.managing)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("连接服务器")
        .gesture(DismissKeyboardOnOutsideTap())
#else
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
                    Text("填写 Go 服务地址和 TLS 证书指纹，并将本设备公钥添加到服务器的 authorized_keys。")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: 12) {
                    connectionField("服务器地址", icon: "server.rack") {
                        TextField("mqtts://主机:8883/服务标识", text: serverAddress)
                            .accessibilityLabel("服务器地址")
                    }
                    connectionField("证书指纹", icon: "key") {
                        TextField("SHA-256 指纹", text: $client.fingerprint)
                            .accessibilityLabel("证书指纹")
                    }
                }
                .textFieldStyle(.roundedBorder)
                .disabled(workspace.managing)
                .autocorrectionDisabled()
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
#endif
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
    }

    private var pairButton: some View {
        Button(publicKey.isEmpty ? "复制设备公钥" : "已复制设备公钥", systemImage: "key") {
            do {
                let line = try client.devicePublicKey()
#if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(line, forType: .string)
#else
                UIPasteboard.general.string = line
#endif
                publicKey = line
            } catch { workspace.failure = error.localizedDescription }
        }
        .accessibilityValue(publicKey.isEmpty ? "" : "已复制")
        .help("复制 OpenSSH 公钥")
    }

    @ViewBuilder private var connectionButtons: some View {
        pairButton
        Button {
            connect(automatic: false)
        } label: {
            Label("连接", systemImage: "arrow.right")
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .disabled(client.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                  client.fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func reconnectIfNeeded() {
        guard !client.connected, !client.fingerprint.isEmpty, workspace.resumeConnection, workspace.pairedAddress,
              !UserDefaults.standard.bool(forKey: "acpManuallyDisconnected." + client.address) else { return }
        if workspace.managing {
            workspace.reconnectWhenIdle = true
            return
        }
        connect(automatic: true)
    }

    private func connect(automatic: Bool) {
        manage {
            client.address = client.address.trimmingCharacters(in: .whitespacesAndNewlines)
            do { try await client.connect() }
            catch { if automatic && client.offline { return }; throw error }
            UserDefaults.standard.removeObject(forKey: "acpManuallyDisconnected." + client.address)
            workspace.pairedAddress = true
            workspace.resumeConnection = true
            UserDefaults.standard.set(client.fingerprint, forKey: "goPin." + client.address)
            workspace.sessionLoadFailure = nil
            restoreProjects()
            let key = "acpLastSession." + client.address
            let last = UserDefaults.standard.dictionary(forKey: key) as? [String: String]
            guard let last, let id = last["id"], let lastProject = restoredProject(for: last) else { return }
            let initial = workspace.selection
            try await client.listSessions(in: lastProject)
            guard client.connected, workspace.selection == initial else { return }
            if !client.directory.contains(id, in: lastProject) {
#if os(iOS)
                guard client.supportsSessionLoad else { return }
                let saved = ACPSession(id: id, title: last["title"] ?? "上次会话", cwd: last["cwd"] ?? lastProject.path ?? "")
                try await client.restoreUnlistedSession(saved, in: lastProject)
                guard client.connected, workspace.selection == initial else { return }
#else
                if client.supportsSessionList { UserDefaults.standard.removeObject(forKey: key) }
                return
#endif
            }
            workspace.activeProject = lastProject
            workspace.selection = id
            workspace.preferredColumn = .detail
        }
    }

    private func restoreProjects() {
        guard let first = client.workspaceIDs.first else { return }
        let project = ACPProject(path: first)
        let saved = UserDefaults.standard.dictionary(forKey: "acpProjectPaths") ?? [:]
        let paths = saved[client.address] as? [String] ?? []
        var seen: Set<ACPProject> = [project]
        workspace.addedProjects = (Array(client.workspaceIDs.dropFirst()) + paths).map { ACPProject(path: $0) }.filter {
            !$0.isDefaultWorkspaceRoot && client.workspaceIDs.contains($0.workspaceID) && seen.insert($0).inserted
        }
        workspace.defaultProject = project
        workspace.activeProject = projects.first
        workspace.projectSectionExpanded = UserDefaults.standard.object(forKey: "acpProjectSectionExpanded." + client.address) as? Bool ?? true
        workspace.expandedProjects = projects.first.map { SidebarExpansion.restore(server: client.address, projects: projects, defaultProject: $0) } ?? []
        if let last = UserDefaults.standard.dictionary(forKey: "acpLastSession." + client.address) as? [String: String],
           let saved = restoredProject(for: last) {
            workspace.activeProject = saved
            if last["project"] == "default" { workspace.expandedProjects.insert(saved) }
            workspace.selection = last["id"]
        }
    }

    private func restoredProject(for location: [String: String]) -> ACPProject? {
        if location["project"] == "default", let cwd = location["cwd"] {
            return projects.first { $0.workspaceID == "default" && $0.relativePath == cwd }
        }
        return projects.first { $0.id == location["project"] }
    }

    private func forgetSelection() {
#if os(iOS)
        workspace.preferredColumn = .sidebar
#endif
        UserDefaults.standard.removeObject(forKey: "acpLastSession." + client.address)
        workspace.selection = nil
    }

    private func refresh(_ project: ACPProject) {
        manage { try await client.refreshSessions(in: project) }
    }

    private func addProject(_ path: String) {
        let project = ACPProject(path: path)
        guard !project.isDefaultWorkspaceRoot else { return }
        manage {
            try await client.listSessions(in: project)
            if !projects.contains(project) {
                workspace.addedProjects.append(project)
                saveProjects()
            }
            workspace.activeProject = project
            setProject(project, expanded: true)
        }
    }

    private func removeProject(_ project: ACPProject) {
        workspace.addedProjects.removeAll { $0 == project }
        setProject(project, expanded: false)
        if workspace.activeProject == project { workspace.activeProject = projects.first }
        if let selection = workspace.selection, client.directory.contains(selection, in: project) {
            forgetSelection()
        }
        saveProjects()
    }

    private func setProject(_ project: ACPProject, expanded: Bool) {
        if expanded { workspace.expandedProjects.insert(project) }
        else { workspace.expandedProjects.remove(project) }
        SidebarExpansion.save(workspace.expandedProjects, server: client.address)
    }

    private func saveProjects() {
        var saved = UserDefaults.standard.dictionary(forKey: "acpProjectPaths") ?? [:]
        saved[client.address] = workspace.addedProjects.compactMap(\.path)
        UserDefaults.standard.set(saved, forKey: "acpProjectPaths")
    }

    private func createSession(in project: ACPProject, agent: String = "codex") {
        manage {
            let id = try await client.createSession(in: project, agent: agent)
            workspace.activeProject = project
            setProject(project, expanded: true)
            workspace.selection = id
            workspace.preferredColumn = .detail
        }
    }

    private func openSelectedSession() {
        guard client.available, client.supportsSessionLoad, let id = workspace.selection,
              !client.loaded.contains(id), workspace.sessionLoadFailure?.id != id,
              let session = client.directory.session(id: id) else { return }
        manage {
            guard client.available, workspace.selection == id else { return }
            do {
                try await client.load(session)
            } catch {
                if client.available, workspace.selection == id {
                    workspace.sessionLoadFailure = (id, error)
                }
            }
        }
    }

    private func conversation(_ session: ACPSession) -> some View {
        let id = session.id
        let isLoaded = client.loaded.contains(id)
        let isPrompting = client.prompting.contains(id)
        let permissions = client.permissions.filter { $0.sessionID == id }
        let options = client.sessionOptions[id]
        let showsSettings = (client.supportsConfig && options?.config?.isEmpty == false) || (client.supportsMode && options?.modes?.availableModes.isEmpty == false)
#if os(iOS)
        let horizontalMargin: CGFloat = 16
#else
        let settingsMargin = showsSettings ? ConversationLayout.settingsGutter : 0
        let terminalMargin: CGFloat = client.supportsRemoteShell ? 46 : 0
        let horizontalMargin = ConversationLayout.horizontalMargin + settingsMargin + terminalMargin
#endif
        return VStack(spacing: 0) {
            if isLoaded, let timeline = client.timelines[id] {
                SessionTranscript(
                    timeline: timeline, isResponding: isPrompting, permissions: permissions,
                    horizontalMargin: horizontalMargin, composerSpacing: ConversationLayout.composerSpacing
                ) { permission, option in
                    run { try await client.respond(to: permission, option: option) }
                }
#if os(iOS)
                .contentShape(Rectangle())
                .gesture(DismissKeyboardOnOutsideTap())
#endif
                .modifier(ProjectLinkPreview(client: client, session: id))
                .id(id)

                if let queue = client.queuedPrompts[id], !queue.isEmpty {
                    ForEach(queue) { message in
                        Label("待发送 · " + message.text, systemImage: "clock").font(.caption).lineLimit(2)
                    }
                }
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
                        isManaging: workspace.managing || client.isArchived(id),
                        horizontalMargin: horizontalMargin,
                        send: { sendDraft(in: id) },
                        stop: { run { try await client.cancelPrompt(in: id) } },
                        addAttachments: { addAttachments($0, in: id) },
                        removeAttachment: { attachment in workspace.draftAttachments[id]?.removeAll { $0.id == attachment } },
                        attachmentFailed: { workspace.failure = $0.localizedDescription }
                    )
                    .id(id)
                    .frame(maxWidth: .infinity)
#if !os(iOS)
                    if showsSettings, let options {
                        sessionSettings(options, in: id)
                            .padding(.trailing, 20 + terminalMargin)
                            .padding(.bottom, 16)
                    }
#endif
                }
            } else {
                sessionOpeningStatus(for: id)
            }
        }
        .navigationTitle(session.title)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
#if os(iOS)
            if isLoaded || client.supportsRemoteShell {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if isLoaded, showsSettings, let options { sessionSettings(options, in: id) }
                        if client.supportsRemoteShell, let project = workspace.activeProject {
                            Button("远程终端", systemImage: "terminal") { openTerminal(project) }
                        }
                        if isLoaded { releaseButton(id) }
                    } label: { Label("会话操作", systemImage: "ellipsis") }
                }
            }
#else
            if isLoaded { ToolbarItem { releaseButton(id) } }
#endif
        }
    }

    private func releaseButton(_ id: String) -> some View {
        Button("关闭会话", systemImage: "rectangle.portrait.and.arrow.right") {
            manage {
                try await client.close(id)
                if workspace.selection == id { forgetSelection() }
            }
        }
        .disabled(workspace.managing || client.prompting.contains(id))
    }

    private func openTerminal(_ project: ACPProject) {
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
    }

    private func terminalButton(_ project: ACPProject) -> some View {
        Button { openTerminal(project) } label: {
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
            ContentUnavailableView {
                Label("无法打开会话", systemImage: "exclamationmark.circle")
            } description: {
                Text(failure.error.localizedDescription)
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
            if client.supportsConfig, let config = options.config {
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
            }
            if client.supportsMode, let modes = options.modes {
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
#if os(iOS)
            Label("会话设置", systemImage: "slider.horizontal.3")
#else
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
#endif
        }
#if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
#endif
        .frame(width: 32, height: 32)

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

struct SidebarProjectGroup {
    let project: ACPProject
    let expanded: Bool
    let revision: UInt64
    let rows: [ACPSession]
    var visibleRowCount: Int { expanded ? 1 + max(1, rows.count) : 1 }
}

struct SidebarMenuItem {
    let title: String
    let symbol: String
    let destructive: Bool
    let disabled: Bool
    let perform: () -> Void

    init(_ title: String, _ symbol: String, destructive: Bool = false, disabled: Bool, perform: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.destructive = destructive
        self.disabled = disabled
        self.perform = perform
    }
}

#if !os(macOS)
private struct SessionListRow: View {
    let session: ACPSession
    let client: ACPClient
    let workspace: ServerWorkspaceState

    var body: some View {
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
        }
        .frame(minHeight: 26)
        .contentShape(Rectangle())
    }
}

#endif

#Preview {
    ContentView()
        .environment(RemoteTerminalWindows())
}

#if os(macOS)
struct SessionPreviewAnchor: PreferenceKey {
    struct Preview {
        let session: ACPSession
        let anchor: Anchor<CGRect>
        let row: CGRect
    }

    static var defaultValue: Preview? { nil }

    static func reduce(value: inout Preview?, nextValue: () -> Preview?) {
        if let next = nextValue() { value = next }
    }
}
#endif
