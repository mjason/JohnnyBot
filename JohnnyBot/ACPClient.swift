import Foundation
import Observation

struct ACPFailure: LocalizedError {
    let message: String
    let code: Int?
    private let reason: String?

    init(message: String, code: Int? = nil, reason: String? = nil) {
        self.message = message
        self.code = code
        self.reason = reason
    }

    var errorDescription: String? { message }

    var isCodexSessionInUse: Bool { reason == "thread_active_writer" }

    var isSessionOccupied: Bool {
        isCodexSessionInUse
            || (code == -32010 && message.caseInsensitiveCompare("Session is attached to another client") == .orderedSame)
    }
}

struct ACPProject: Hashable, Identifiable {
    let path: String?
    var id: String { path ?? "" }

    var name: String {
        guard let path else { return "默认项目" }
        return path.split(separator: "/").last.map(String.init) ?? "/"
    }
}

struct ACPDirectoryListing: Decodable {
    struct Directory: Decodable, Identifiable {
        let name: String
        let path: String
        var id: String { path }
    }

    let path: String
    let parent: String?
    let directories: [Directory]
}

struct ACPEntry: Identifiable {
    enum Kind: Hashable {
        case user, agent, thought, tool, plan, status
    }

    enum MessagePhase: String {
        case commentary
        case finalAnswer = "final_answer"
    }

    enum ToolContent {
        case text(String)
        case diff(path: String, oldText: String?, newText: String?)
        case terminal(String)
    }

    struct ToolLocation: Decodable, Hashable {
        let path: String
        let line: Int?
    }

    struct PlanStep: Decodable {
        let content: String
        let status: String
    }

    let id = UUID()
    let kind: Kind
    var text: String
    var messageID: String?
    var phase: MessagePhase?
    var replyTiming: ACPReplyTiming?
    var toolID: String?
    var toolKind: String?
    var toolStatus: String?
    var toolContent: [ToolContent] = []
    var toolLocations: [ToolLocation] = []
    var planSteps: [PlanStep] = []
    var attachments: [ACPAttachment.Preview] = []

    var replyTimingID: String? {
        switch kind {
        case .agent, .thought:
            guard let messageID, !messageID.isEmpty else { return nil }
            return kind == .agent ? "agent:\(messageID)" : "thought:\(messageID)"
        case .tool:
            guard let toolID, !toolID.isEmpty else { return nil }
            return "tool:\(toolID)"
        case .user, .plan, .status:
            return nil
        }
    }
}

struct ACPPermission: Identifiable {
    struct Option: Identifiable {
        let id: String
        let name: String
    }

    let id = UUID()
    let requestID: Any
    let sessionID: String
    let title: String
    let details: String?
    let options: [Option]
}

@MainActor @Observable
final class ACPClient {
    @ObservationIgnored private var streamUpdates: [(String, [String: Any])] = []
    @ObservationIgnored private var batchOffsets: [String: Set<Int>]?
    @ObservationIgnored private var streamFlush: Task<Void, Never>?
    @ObservationIgnored private var peerTurns = Set<String>()

    private func flushStream() {
        streamFlush?.cancel()
        streamFlush = nil
        guard !streamUpdates.isEmpty else { return }
        batchOffsets = [:]
        for (session, update) in streamUpdates { apply(update, to: session) }
        streamUpdates.removeAll(keepingCapacity: true)
        let changes = batchOffsets ?? [:]
        batchOffsets = nil
        for (id, offsets) in changes {
            if let timeline = timelines[id], let history = entries[id] {
                timeline.update(history, changedOffsets: offsets)
            } else if let offset = offsets.first {
                publishEntry(in: id, at: offset)
            }
        }
    }

    private func enqueueStream(_ update: [String: Any], session: String) {
        streamUpdates.append((session, update))
        guard streamFlush == nil else { return }
        streamFlush = Task {
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            flushStream()
        }
    }

    private struct TranscriptIndex {
        struct Message: Hashable {
            let kind: ACPEntry.Kind
            let id: String
        }

        var messages: [Message: Int] = [:]
        var tools: [String: Int] = [:]
    }

#if os(iOS)
    static let defaultAddress = ProcessInfo.processInfo.environment["JOHNNY_ACP_URL"] ?? ""
#else
    static let defaultAddress = ProcessInfo.processInfo.environment["JOHNNY_ACP_URL"] ?? "ws://127.0.0.1:8765/acp"
#endif

    var address: String
    var token: String

    var displayName: String {
        let components = URLComponents(string: address)
        guard let host = components?.host else { return address.isEmpty ? "新服务器" : address }
        return components?.port.map { "\(host):\($0)" } ?? host
    }

    init(address: String, token: String) {
        self.address = address
        self.token = token
    }
    private(set) var status = "未连接"
    private(set) var connected = false
    private(set) var supportsSessionLoad = false
    private(set) var supportsSessionList = false
    private var supportsProjectFilePreview = false
    private(set) var supportsDirectoryListing = false
    private var serverHomeDirectory: String?
    private(set) var supportsRemoteShell = false
    private(set) var supportsSessionRename = false
    private(set) var supportsSessionDelete = false
    private(set) var supportsPromptImages = false
    private(set) var supportsPromptFiles = false
    private var supportsSessionClose = false
    let directory = SessionDirectory()
    private(set) var sessionOptions: [String: ACPSessionOptions] = [:]
    private(set) var loaded: Set<String> = []
    private(set) var prompting: Set<String> = []
    @ObservationIgnored private var entries: [String: [ACPEntry]] = [:]
    private(set) var timelines: [String: TranscriptTimeline] = [:]

    private func publishEntry(in id: String, at offset: Int) {
        if batchOffsets != nil {
            batchOffsets?[id, default: []].insert(offset)
            return
        }
        guard let history = entries[id] else { return }
        if let timeline = timelines[id] {
            timeline.update(history, at: offset)
        } else {
            let timeline = TranscriptTimeline()
            timeline.replace(history)
            timelines[id] = timeline
        }
    }
    private(set) var permissions: [ACPPermission] = []

    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var listingProjects: [ACPProject: (titlesOnly: Bool, task: Task<Void, Error>)] = [:]
    @ObservationIgnored private var directoryRevision = 0
    // A page that was already in flight must not bring back a deleted session.
    @ObservationIgnored private var deletedDuringListing: [String: Int] = [:]
    @ObservationIgnored private var titleUpdates: [String: (title: String, revision: Int)] = [:]
    @ObservationIgnored private var replayHistory: [String: [ACPEntry]] = [:]
    @ObservationIgnored private var transcriptIndexes: [String: TranscriptIndex] = [:]
    private let replyTimingStore = ACPReplyTimingStore()

    func importToken(from url: URL) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let contents = try String(contentsOf: url, encoding: .utf8)
        for line in contents.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "TOKEN" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty {
                if let quote = value.first, (quote == "\"" || quote == "'"), value.last == quote, value.count > 1 {
                    token = String(value.dropFirst().dropLast())
                } else {
                    token = value
                }
                return
            }
        }
        throw ACPFailure(message: "配置文件缺少 TOKEN")
    }

    func connect() async throws {
        guard socket == nil else { return }
        guard let url = URL(string: address), let scheme = url.scheme, ["ws", "wss"].contains(scheme), url.host != nil else {
            throw ACPFailure(message: "请输入有效的 WebSocket 地址")
        }
        let request = try authorizedRequest(to: url)
        let task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1024 * 1024
        socket = task
        status = "正在连接…"
        task.resume()
        Task { await receive(from: task) }
        do {
            let info = try await call("initialize", [
                "protocolVersion": 1,
                "clientCapabilities": ["session": ["configOptions": ["boolean": [:]]]]
            ])
            guard info["protocolVersion"] as? Int == 1 else {
                throw ACPFailure(message: "服务器未协商 ACP v1")
            }
            let capabilities = info["agentCapabilities"] as? [String: Any]
            let sessionCapabilities = capabilities?["sessionCapabilities"] as? [String: Any]
            let promptCapabilities = capabilities?["promptCapabilities"] as? [String: Any]
            let metadata = capabilities?["_meta"] as? [String: Any]
            supportsRemoteShell = metadata?["johnny/shell"] as? Bool == true
            supportsPromptImages = promptCapabilities?["image"] as? Bool == true
            supportsPromptFiles = promptCapabilities?["embeddedContext"] as? Bool == true
            supportsSessionLoad = capabilities?["loadSession"] as? Bool == true
            supportsProjectFilePreview = metadata?["johnny/read_project_file"] as? Bool == true
            supportsDirectoryListing = (metadata?["johnny/list_directories"] as? Bool) == true
            if let home = metadata?["johnny/home_directory"] as? String, home.hasPrefix("/") {
                serverHomeDirectory = home
            }
            supportsSessionList = sessionCapabilities?["list"] is [String: Any]
            supportsSessionRename = sessionCapabilities?["title"] is [String: Any]
                || sessionCapabilities?["setTitle"] is [String: Any]
            supportsSessionDelete = sessionCapabilities?["delete"] is [String: Any]
            supportsSessionClose = sessionCapabilities?["close"] is [String: Any]
            connected = true
            let agentInfo = info["agentInfo"] as? [String: Any]
            status = agentInfo?["title"] as? String ?? "已连接"
        } catch {
            if socket === task { disconnect(reason: error) }
            throw error
        }
    }

    func shellRequest() throws -> URLRequest {
        guard connected, supportsRemoteShell, let endpoint = socket?.originalRequest?.url,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw ACPFailure(message: "当前服务器没有提供远程终端")
        }
        components.path = endpoint.deletingLastPathComponent().appending(path: "shell").path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw ACPFailure(message: "无法解析终端地址") }
        return try authorizedRequest(to: url)
    }

    private func authorizedRequest(to url: URL) throws -> URLRequest {
        let credential = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty, !credential.contains(where: \.isNewline) else {
            throw ACPFailure(message: "请输入有效的令牌")
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        return request
    }

    func disconnect(reason: Error? = nil) {
        streamFlush?.cancel()
        streamFlush = nil
        streamUpdates.removeAll()
        peerTurns.removeAll()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        connected = false
        supportsSessionLoad = false
        supportsSessionList = false
        supportsProjectFilePreview = false
        supportsDirectoryListing = false
        serverHomeDirectory = nil
        supportsRemoteShell = false
        supportsSessionRename = false
        supportsSessionDelete = false
        supportsPromptImages = false
        supportsPromptFiles = false
        supportsSessionClose = false
        status = reason.map { "连接中断 · \($0.localizedDescription)" } ?? "未连接"
        let requests = pending
        pending.removeAll()
        for continuation in requests.values {
            continuation.resume(throwing: reason ?? ACPFailure(message: "连接已断开"))
        }
        sessionOptions.removeAll()
        loaded.removeAll()
        prompting.removeAll()
        permissions.removeAll()
        directory.removeAll()
        listingProjects.removeAll()
        deletedDuringListing.removeAll()
        titleUpdates.removeAll()
        entries.removeAll()
        timelines.removeAll()
        replayHistory.removeAll()
        transcriptIndexes.removeAll()
    }

    func projectHomeDirectory(defaultPath: String?) -> String? {
        if let serverHomeDirectory { return serverHomeDirectory }
        guard let defaultPath, defaultPath.hasPrefix("/") else { return nil }
        // Older servers only report the configured project. Recognize standard account directories.
        let components = defaultPath.split(separator: "/", maxSplits: 2)
        switch components.first {
        case "home", "Users":
            guard components.count >= 2 else { return nil }
            return "/\(components[0])/\(components[1])"
        case "root":
            return "/root"
        default:
            return nil
        }
    }

    func readProjectFile(_ path: String, session: String) async throws -> String {
        guard supportsProjectFilePreview else { throw ACPFailure(message: "请更新服务器以启用项目文件预览") }
        let result = try await call("_johnny/read_project_file", ["sessionId": session, "path": path])
        guard let content = result["content"] as? String else { throw ACPFailure(message: "服务器返回的文件内容无效") }
        return content
    }

    func listDirectories(path: String? = nil) async throws -> ACPDirectoryListing {
        guard supportsDirectoryListing else {
            throw ACPFailure(message: "服务器未提供远程目录浏览")
        }
        let result = try await call("_johnny/list_directories", path.map { ["path": $0] } ?? [:])
        guard let listing = decodeACP(ACPDirectoryListing.self, from: result),
              listing.path.hasPrefix("/"),
              listing.parent?.hasPrefix("/") != false,
              listing.directories.allSatisfy({ $0.path.hasPrefix("/") }) else {
            throw ACPFailure(message: "服务器返回的目录列表格式无效")
        }
        return listing
    }

    func listSessions(in project: ACPProject, titlesOnly: Bool = false) async throws {
        guard supportsSessionList else { return }
        guard let connection = socket else { throw ACPFailure(message: "请先连接服务器") }
        while let listing = listingProjects[project] {
            try await listing.task.value
            guard socket === connection else { throw ACPFailure(message: "连接已断开") }
            if titlesOnly || !listing.titlesOnly { return }
        }
        let task = Task {
            defer {
                if socket === connection {
                    listingProjects.removeValue(forKey: project)
                    if listingProjects.isEmpty { deletedDuringListing.removeAll() }
                }
            }
            try await fetchSessions(in: project, titlesOnly: titlesOnly, connection: connection)
        }
        listingProjects[project] = (titlesOnly, task)
        try await task.value
    }

    private func fetchSessions(in project: ACPProject, titlesOnly: Bool, connection: URLSessionWebSocketTask) async throws {
        guard socket === connection else { throw ACPFailure(message: "连接已断开") }
        let startingRevision = directoryRevision
        var listed: [ListedSession] = []
        var listedIDs: Set<String> = []
        var cursor: String?
        var seenCursors: Set<String> = []
        repeat {
            var params: [String: Any] = [:]
            params["cwd"] = project.path
            params["cursor"] = cursor
            let result = try await call("session/list", params)
            guard socket === connection else { throw ACPFailure(message: "连接已断开") }
            for item in result["sessions"] as? [[String: Any]] ?? [] {
                let cwd = item["cwd"] as? String ?? project.path ?? ""
                guard project.path == nil || project.path == cwd,
                      let id = item["sessionId"] as? String,
                      deletedDuringListing[id, default: 0] <= startingRevision,
                      listedIDs.insert(id).inserted else { continue }
                let listedTitle: String
                if let update = titleUpdates[id], update.revision > startingRevision {
                    listedTitle = update.title
                } else {
                    listedTitle = item["title"] as? String ?? titleUpdates[id]?.title ?? "未命名会话"
                }
                listed.append(ListedSession(id: id, title: listedTitle, cwd: cwd))
            }
            let firstPage = cursor == nil
            cursor = result["nextCursor"] as? String
            if firstPage, !titlesOnly, cursor?.isEmpty == false, !directory.hasListed(project) {
                directory.replace(listed, ids: listedIDs, in: project, retaining: loaded, complete: false)
            }
            if let cursor, !cursor.isEmpty, !seenCursors.insert(cursor).inserted {
                throw ACPFailure(message: "服务器返回重复的分页游标")
            }
        } while cursor?.isEmpty == false

        if !deletedDuringListing.isEmpty {
            listed.removeAll { deletedDuringListing[$0.id, default: 0] > startingRevision }
            listedIDs = Set(listed.map(\.id))
        }
        for index in listed.indices {
            if let update = titleUpdates[listed[index].id], update.revision > startingRevision {
                listed[index].title = update.title
            }
        }
        if titlesOnly {
            for item in listed { directory.updateTitle(item.title, for: item.id) }
        } else {
            directory.replace(listed, ids: listedIDs, in: project, retaining: loaded, complete: true)
        }
    }

    func createSession(in project: ACPProject) async throws -> String {
        guard let socket else { throw ACPFailure(message: "请先连接服务器") }
        var params: [String: Any] = ["mcpServers": []]
        params["cwd"] = project.path
        let result = try await call("session/new", params)
        guard self.socket === socket else { throw ACPFailure(message: "连接已断开") }
        guard let id = result["sessionId"] as? String else {
            throw ACPFailure(message: "服务器未返回会话 ID")
        }
        let cwd = result["cwd"] as? String ?? project.path ?? ""
        let title = titleUpdates[id]?.title ?? result["title"] as? String ?? "新会话"
        directory.insert(ACPSession(id: id, title: title, cwd: cwd), in: project, atFront: true)
        applySessionSetup(result, to: id)
        if timelines[id] == nil { timelines[id] = TranscriptTimeline() }
        loaded.insert(id)
        return id
    }

    func load(_ session: ACPSession) async throws {
        let id = session.id
        guard !loaded.contains(id), replayHistory[id] == nil else { return }
        guard let socket else { throw ACPFailure(message: "请先连接服务器") }
        replayHistory[id] = []
        transcriptIndexes.removeValue(forKey: id)
        do {
            var params: [String: Any] = ["sessionId": id, "mcpServers": []]
            if !session.cwd.isEmpty { params["cwd"] = session.cwd }
            let result = try await call("session/load", params)
            guard self.socket === socket else { throw ACPFailure(message: "连接已断开") }
            var history = replayHistory.removeValue(forKey: id) ?? []
            if let endpoint = socket.originalRequest?.url {
                let timings = replyTimingStore.timings(endpoint: endpoint, sessionID: id)
                for index in history.indices {
                    if let key = history[index].replyTimingID, let timing = timings[key] {
                        history[index].replyTiming = timing
                    }
                }
            }
            let timeline = TranscriptTimeline()
            timeline.replace(history)
            timelines[id] = timeline
            entries[id] = history
            applySessionSetup(result, to: id)
            loaded.insert(id)
        } catch {
            if self.socket === socket {
                replayHistory.removeValue(forKey: id)
                transcriptIndexes.removeValue(forKey: id)
                entries.removeValue(forKey: id)
                timelines.removeValue(forKey: id)
                sessionOptions.removeValue(forKey: id)
            }
            throw error
        }
    }

#if os(iOS)
    // A session can be loadable before the server includes it in session/list.
    func restoreUnlistedSession(_ session: ACPSession, in project: ACPProject) async throws {
        guard let connection = socket else { throw ACPFailure(message: "请先连接服务器") }
        try await load(session)
        guard socket === connection, loaded.contains(session.id) else { throw ACPFailure(message: "未能恢复会话") }
        directory.insert(session, in: project, atFront: false)
    }
#endif

    func close(_ id: String) async throws {
        _ = try await call("session/close", ["sessionId": id])
        loaded.remove(id)
        sessionOptions.removeValue(forKey: id)
        permissions.removeAll { $0.sessionID == id }
    }

    func deleteSession(_ id: String) async throws {
        guard supportsSessionDelete else {
            throw ACPFailure(message: "服务器不支持删除会话")
        }
        guard !prompting.contains(id) else {
            throw ACPFailure(message: "请先停止当前回复")
        }
        guard let socket else { throw ACPFailure(message: "请先连接服务器") }

        if loaded.contains(id), supportsSessionClose {
            do {
                try await close(id)
            } catch let error as ACPFailure where error.code == -32002 {
                guard self.socket === socket else { throw ACPFailure(message: "连接已断开") }
                loaded.remove(id)
                permissions.removeAll { $0.sessionID == id }
            }
        }
        guard self.socket === socket else { throw ACPFailure(message: "连接已断开") }
        do {
            _ = try await call("session/delete", ["sessionId": id])
        } catch let error as ACPFailure where error.code == -32002 {
            // The server has already removed this session.
        }
        if let endpoint = socket.originalRequest?.url {
            replyTimingStore.remove(endpoint: endpoint, sessionID: id)
        }
        guard self.socket === socket else { return }
        loaded.remove(id)
        sessionOptions.removeValue(forKey: id)
        entries.removeValue(forKey: id)
        timelines.removeValue(forKey: id)
        transcriptIndexes.removeValue(forKey: id)
        permissions.removeAll { $0.sessionID == id }
        directory.remove(id)
        if !listingProjects.isEmpty {
            directoryRevision += 1
            deletedDuringListing[id] = directoryRevision
        }
        titleUpdates.removeValue(forKey: id)
    }

    func renameSession(_ session: ACPSession, to draft: String) async throws {
        guard supportsSessionRename else { throw ACPFailure(message: "服务器不支持重命名会话") }
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ACPFailure(message: "会话名称不能为空") }

        do {
            try await setSessionTitle(title, in: session.id)
        } catch let error as ACPFailure where error.code == -32010 && !loaded.contains(session.id) {
            try await load(session)
            do {
                try await setSessionTitle(title, in: session.id)
            } catch {
                if supportsSessionClose { try? await close(session.id) }
                throw error
            }
            if supportsSessionClose {
                do { try await close(session.id) }
                catch { throw ACPFailure(message: "已重命名会话，但无法释放：\(error.localizedDescription)") }
            }
        }
    }

    private func setSessionTitle(_ title: String, in id: String) async throws {
        guard let socket else { throw ACPFailure(message: "请先连接服务器") }
        let startingRevision = directoryRevision
        let result = try await call("session/set_title", ["sessionId": id, "title": title])
        guard self.socket === socket else { throw ACPFailure(message: "连接已断开") }
        if let update = titleUpdates[id], update.revision > startingRevision { return }
        updateSessionTitle(result["title"] as? String ?? title, in: id)
    }

    private func updateSessionTitle(_ title: String, in id: String) {
        directoryRevision += 1
        titleUpdates[id] = (title, directoryRevision)
        directory.updateTitle(title, for: id)
    }

    func setConfigOption(_ option: ACPConfigOption, value: String, in id: String) async throws {
        try await setConfigOption(["sessionId": id, "configId": option.id, "value": value], in: id)
    }

    func setConfigOption(_ option: ACPConfigOption, enabled: Bool, in id: String) async throws {
        try await setConfigOption([
            "sessionId": id, "configId": option.id, "type": "boolean", "value": enabled
        ], in: id)
    }

    private func setConfigOption(_ params: [String: Any], in id: String) async throws {
        guard loaded.contains(id) else { return }
        let result = try await call("session/set_config_option", params)
        guard let config = result["configOptions"] as? [[String: Any]] else {
            throw ACPFailure(message: "Agent 未返回完整的会话设置")
        }
        if loaded.contains(id) {
            sessionOptions[id, default: ACPSessionOptions()].config = ACPConfigOption.decode(config)
        }
    }

    func setMode(_ modeID: String, in id: String) async throws {
        guard loaded.contains(id) else { return }
        let previousMode = sessionOptions[id]?.currentModeID
        _ = try await call("session/set_mode", ["sessionId": id, "modeId": modeID])
        if loaded.contains(id), sessionOptions[id]?.currentModeID == previousMode {
            sessionOptions[id]?.currentModeID = modeID
        }
    }

    private func applySessionSetup(_ result: [String: Any], to id: String) {
        var options = sessionOptions[id, default: ACPSessionOptions()]
        if options.config == nil, let config = result["configOptions"] as? [[String: Any]] {
            options.config = ACPConfigOption.decode(config)
        }
        if let rawModes = result["modes"], let modes = decodeACP(ACPSessionModes.self, from: rawModes) {
            options.modes = modes
            if options.currentModeID == nil { options.currentModeID = modes.currentModeId }
        }
        sessionOptions[id] = options
    }

    func prompt(_ text: String, attachments: [ACPAttachment] = [], in id: String) async throws {
        guard let socket, loaded.contains(id) else { throw ACPFailure(message: "请先打开会话") }
        guard !prompting.contains(id) else { throw ACPFailure(message: "请等待当前回复完成") }
        guard supportsPromptImages || !attachments.contains(where: { $0.preview.isImage }) else {
            throw AttachmentError.unsupportedImage
        }
        guard supportsPromptFiles || attachments.allSatisfy({ $0.preview.isImage }) else {
            throw AttachmentError.unsupportedFile
        }
        guard attachments.reduce(0, { $0 + $1.byteCount }) <= ACPAttachment.maxTotalBytes else {
            throw AttachmentError.messageTooLarge
        }
        var blocks: [[String: Any]] = text.isEmpty ? [] : [["type": "text", "text": text]]
        blocks += attachments.map(\.promptBlock)
        guard !blocks.isEmpty else { return }
        if !attachments.isEmpty, try JSONSerialization.data(withJSONObject: blocks).count > ACPAttachment.maxWireBytes {
            throw AttachmentError.messageTooLarge
        }
        prompting.insert(id)
        let startedAt = ContinuousClock.now
        let userEntry = ACPEntry(kind: .user, text: text, attachments: attachments.map(\.preview))
        updateTranscript(id) { history, _ in
            history.append(userEntry)
            return history.count - 1
        }
        defer { if self.socket === socket && !peerTurns.contains(id) { prompting.remove(id) } }
        let result: [String: Any]
        do {
            result = try await call("session/prompt", ["sessionId": id, "prompt": blocks])
        } catch {
            if self.socket === socket,
               entries[id]?.last?.id == userEntry.id || (error as? ACPFailure)?.code == -32010,
               let offset = entries[id]?.firstIndex(where: { $0.id == userEntry.id }) {
                entries[id]?.remove(at: offset)
                timelines[id]?.replace(entries[id] ?? [])
                // Removing an optimistic entry shifts indexes for later messages.
                transcriptIndexes[id] = TranscriptIndex()
                for (index, entry) in (entries[id] ?? []).enumerated() {
                    if let key = entry.messageID { transcriptIndexes[id]?.messages[.init(kind: entry.kind, id: key)] = index }
                    if let key = entry.toolID { transcriptIndexes[id]?.tools[key] = index }
                }
            }
            throw error
        }
        guard self.socket === socket else { return }
        let stopReason = result["stopReason"] as? String
        if let stopReason, stopReason != "end_turn" {
            updateTranscript(id) { history, _ in
                history.append(ACPEntry(kind: .status, text: stopReason))
                return history.count - 1
            }
        }
        guard let history = entries[id], let promptIndex = history.lastIndex(where: { $0.id == userEntry.id }) else { return }
        let timing = ACPReplyTiming(elapsed: startedAt.duration(to: .now),
                                    wasStopped: stopReason == "cancelled" || stopReason == "canceled")
        let response = history[(promptIndex + 1)...]
        let anchor = response.lastIndex { $0.kind == .agent && $0.replyTimingID != nil }
            ?? response.lastIndex { $0.replyTimingID != nil }
        entries[id]?[anchor ?? promptIndex].replyTiming = timing
        publishEntry(in: id, at: anchor ?? promptIndex)
        if let anchor, let key = history[anchor].replyTimingID, let endpoint = socket.originalRequest?.url {
            replyTimingStore.record(timing, for: key, endpoint: endpoint, sessionID: id)
        }
    }

    func cancelPrompt(in id: String) async throws {
        guard let socket, prompting.contains(id) else { return }
        try await send(["jsonrpc": "2.0", "method": "session/cancel", "params": ["sessionId": id]], to: socket)
        for permission in permissions.filter({ $0.sessionID == id }) {
            try await respond(to: permission, option: nil)
        }
    }

    func respond(to permission: ACPPermission, option: String?) async throws {
        guard let socket, let index = permissions.firstIndex(where: { $0.id == permission.id }) else { return }
        permissions.remove(at: index)
        let outcome = option.map { ["outcome": "selected", "optionId": $0] } ?? ["outcome": "cancelled"]
        do {
            try await send(["jsonrpc": "2.0", "id": permission.requestID, "result": ["outcome": outcome]], to: socket)
        } catch {
            if self.socket === socket { disconnect(reason: error) }
            throw error
        }
    }

    private func call(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        guard let socket else { throw ACPFailure(message: "请先连接服务器") }
        nextID += 1
        let id = nextID
        let message = try encode(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let timeout = Task {
            guard method != "session/prompt" else { return }
            do {
                try await Task.sleep(for: .seconds(30))
                if self.socket === socket, pending[id] != nil {
                    disconnect(reason: ACPFailure(message: "\(method) 请求超时"))
                }
            } catch {}
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do {
                    try await socket.send(.string(message))
                } catch {
                    if self.socket === socket { disconnect(reason: error) }
                }
            }
        }
    }

    private func encode(_ message: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
    }

    private func send(_ message: [String: Any], to socket: URLSessionWebSocketTask) async throws {
        try await socket.send(.string(encode(message)))
    }

    nonisolated private static func decodeFrame(_ text: String) throws -> sending [String: Any]? {
        try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }

    @concurrent private static func decodeLargeFrame(_ text: String) async throws -> sending [String: Any]? {
        try decodeFrame(text)
    }

    private func receive(from socket: URLSessionWebSocketTask) async {
        var nextYield = ContinuousClock.now + .milliseconds(8)
        do {
            while self.socket === socket {
                let frame = try await socket.receive()
                guard self.socket === socket else { return }
                guard case .string(let text) = frame else { continue }
                let decoded: [String: Any]?
                if text.utf8.count >= 32 * 1024 {
                    decoded = try await Self.decodeLargeFrame(text)
                    guard self.socket === socket else { return }
                } else {
                    decoded = try Self.decodeFrame(text)
                }
                guard let message = decoded, message["jsonrpc"] as? String == "2.0" else { continue }
                if let method = message["method"] as? String {
                    try await handle(method, message: message, socket: socket)
                } else if let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
                    flushStream()
                    if let error = message["error"] as? [String: Any] {
                        let data = error["data"] as? [String: Any]
                        continuation.resume(throwing: ACPFailure(
                            message: error["message"] as? String ?? "服务器请求失败",
                            code: error["code"] as? Int,
                            reason: data?["reason"] as? String
                        ))
                    } else if let result = message["result"] {
                        let payload = result as? [String: Any] ?? [:]
                        if let meta = payload["_meta"] as? [String: Any],
                           let session = meta["johnny/session_id"] as? String,
                           meta["johnny/prompt_running"] as? Bool == true, replayHistory[session] != nil {
                            prompting.insert(session)
                        }
                        continuation.resume(returning: payload)
                    } else {
                        continuation.resume(throwing: ACPFailure(message: "服务器响应缺少 result"))
                    }
                }
                if ContinuousClock.now >= nextYield {
                    await Task.yield()
                    nextYield = ContinuousClock.now + .milliseconds(8)
                }
            }
        } catch {
            if self.socket === socket { disconnect(reason: error) }
        }
    }

    private func handle(_ method: String, message: [String: Any], socket: URLSessionWebSocketTask) async throws {
        let params = message["params"] as? [String: Any] ?? [:]
        let sessionID = params["sessionId"] as? String
        if method == "session/update", let sessionID, replayHistory[sessionID] == nil,
           let update = params["update"] as? [String: Any],
           let kind = update["sessionUpdate"] as? String,
           kind == "agent_message_chunk" || kind == "agent_thought_chunk" {
            enqueueStream(update, session: sessionID)
            return
        }
        flushStream()
        if let id = message["id"] {
            if method == "session/request_permission", let sessionID,
               let tool = params["toolCall"] as? [String: Any],
               let options = params["options"] as? [[String: Any]] {
                permissions.append(ACPPermission(
                    requestID: id, sessionID: sessionID,
                    title: tool["title"] as? String ?? "工具调用",
                    details: tool["rawInput"].flatMap { input in
                        guard let data = try? JSONSerialization.data(withJSONObject: input, options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys]) else { return nil }
                        return String(decoding: data, as: UTF8.self)
                    },
                    options: options.compactMap {
                        guard let id = $0["optionId"] as? String, let name = $0["name"] as? String else { return nil }
                        return ACPPermission.Option(id: id, name: name)
                    }
                ))
            } else {
                let code = method == "session/request_permission" ? -32602 : -32601
                try await send(["jsonrpc": "2.0", "id": id, "error": [
                    "code": code, "message": code == -32602 ? "Invalid params" : "Method not found"
                ]], to: socket)
            }
        } else if method == "$/cancel_request", let request = params["requestId"] as? NSObject {
            permissions.removeAll { request.isEqual($0.requestID) }
        } else if method == "_johnny/prompt_started", let sessionID {
            peerTurns.insert(sessionID)
            prompting.insert(sessionID)
        } else if method == "_johnny/prompt_finished", let sessionID {
            peerTurns.remove(sessionID)
            prompting.remove(sessionID)
            permissions.removeAll { $0.sessionID == sessionID }
            let reason = params["stopReason"] as? String
            let detail = (params["error"] as? [String: Any])?["message"] as? String
            if let status = detail ?? reason, status != "end_turn" {
                updateTranscript(sessionID) { history, _ in
                    history.append(ACPEntry(kind: .status, text: status))
                    return history.count - 1
                }
            }
        } else if method == "session/update", let sessionID, let update = params["update"] as? [String: Any] {
            apply(update, to: sessionID)
        }
    }

    private func updateTranscript(_ id: String, _ apply: (inout [ACPEntry], inout TranscriptIndex) -> Int?) {
        if replayHistory[id] != nil {
            _ = apply(&replayHistory[id, default: []], &transcriptIndexes[id, default: TranscriptIndex()])
        } else if let offset = apply(&entries[id, default: []], &transcriptIndexes[id, default: TranscriptIndex()]) {
            publishEntry(in: id, at: offset)
        }
    }

    private func apply(_ update: [String: Any], to id: String) {
        let kind = update["sessionUpdate"] as? String
        switch kind {
        case "agent_message_chunk", "user_message_chunk", "agent_thought_chunk":
            guard let content = update["content"] as? [String: Any] else { return }
            let messageID = update["messageId"] as? String
            let meta = update["_meta"] as? [String: Any]
            let jetBrains = meta?["jetbrains"] as? [String: Any]
            let air = jetBrains?["air"] as? [String: Any]
            let phase = (air?["phase"] as? String).flatMap(ACPEntry.MessagePhase.init(rawValue:))
            let entryKind: ACPEntry.Kind
            switch kind {
            case "user_message_chunk": entryKind = .user
            case "agent_thought_chunk": entryKind = .thought
            default: entryKind = .agent
            }
            let attachment = entryKind == .user ? ACPAttachment.replayPreview(content) : nil
            let text = attachment == nil ? content["text"] as? String ?? "[\(content["type"] as? String ?? "内容")]" : ""
            updateTranscript(id) { history, index in
                let key = messageID.map { TranscriptIndex.Message(kind: entryKind, id: $0) }
                let previousIndex: Int?
                if let last = history.indices.last,
                   history[last].kind == entryKind, history[last].messageID == messageID,
                   (messageID != nil || (entryKind != .user && (phase == nil || history[last].phase == phase))) {
                    previousIndex = last
                } else {
                    previousIndex = key.flatMap { index.messages[$0] }
                }
                if let previousIndex {
                    history[previousIndex].text += text
                    if let attachment { history[previousIndex].attachments.append(attachment) }
                    if let phase { history[previousIndex].phase = phase }
                    return previousIndex
                } else {
                    if let key { index.messages[key] = history.count }
                    history.append(ACPEntry(kind: entryKind, text: text, messageID: messageID, phase: phase,
                                            attachments: attachment.map { [$0] } ?? []))
                    return history.count - 1
                }
            }
        case "tool_call", "tool_call_update":
            guard let toolID = update["toolCallId"] as? String else { return }
            updateTranscript(id) { history, index in
                let offset = index.tools[toolID] ?? history.count
                if offset == history.count {
                    index.tools[toolID] = offset
                    history.append(ACPEntry(kind: .tool, text: "", toolID: toolID, toolStatus: "pending"))
                }
                if let title = update["title"] as? String { history[offset].text = title }
                if let kind = update["kind"] as? String { history[offset].toolKind = kind }
                if let status = update["status"] as? String { history[offset].toolStatus = status }
                if let locations = update["locations"] as? [[String: Any]] {
                    history[offset].toolLocations = locations.compactMap { decodeACP(ACPEntry.ToolLocation.self, from: $0) }
                }
                if let blocks = update["content"] as? [[String: Any]] {
                    history[offset].toolContent = blocks.compactMap { block in
                        switch block["type"] as? String {
                        case "content":
                            guard let content = block["content"] as? [String: Any] else { return nil }
                            return .text(content["text"] as? String ?? "[\(content["type"] as? String ?? "内容")]")
                        case "diff":
                            guard let path = block["path"] as? String else { return nil }
                            return .diff(path: path, oldText: block["oldText"] as? String, newText: block["newText"] as? String)
                        case "terminal":
                            return (block["terminalId"] as? String).map(ACPEntry.ToolContent.terminal)
                        default:
                            return nil
                        }
                    }
                }
                return offset
            }
        case "plan":
            guard let rawSteps = update["entries"] as? [[String: Any]] else { return }
            let steps = rawSteps.compactMap { decodeACP(ACPEntry.PlanStep.self, from: $0) }
            updateTranscript(id) { history, _ in
                let turnStart = (history.lastIndex { $0.kind == .user } ?? -1) + 1
                if let index = history[turnStart...].lastIndex(where: { $0.kind == .plan }) {
                    history[index].planSteps = steps
                    return index
                } else if !steps.isEmpty {
                    history.append(ACPEntry(kind: .plan, text: "", planSteps: steps))
                    return history.count - 1
                }
                return nil
            }
        case "available_commands_update":
            guard let commands = update["availableCommands"] as? [[String: Any]] else { return }
            var names: Set<String> = []
            sessionOptions[id, default: ACPSessionOptions()].commands = commands
                .compactMap { decodeACP(ACPCommand.self, from: $0) }
                .filter { !$0.name.isEmpty && names.insert($0.name).inserted }
        case "config_option_update":
            guard let config = update["configOptions"] as? [[String: Any]] else { return }
            sessionOptions[id, default: ACPSessionOptions()].config = ACPConfigOption.decode(config)
        case "current_mode_update":
            guard let mode = update["currentModeId"] as? String else { return }
            sessionOptions[id, default: ACPSessionOptions()].currentModeID = mode
        case "session_info_update":
            if let title = update["title"] as? String {
                updateSessionTitle(title, in: id)
            }
        default:
            break
        }
    }
}
