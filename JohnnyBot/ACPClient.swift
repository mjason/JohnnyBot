import Foundation
import Observation
import CryptoKit

struct ACPFailure: LocalizedError {
    let message: String
    let reason: String?
    init(message: String, reason: String? = nil) {
        self.message = message
        self.reason = reason
    }
    var errorDescription: String? { message }

}

struct ACPProject: Hashable, Identifiable {
    let path: String?
    var id: String { path ?? "" }

    var isDefaultWorkspaceRoot: Bool { id == "default" }

    var workspaceID: String { id.split(separator: "/").first.map(String.init) ?? "" }
    var relativePath: String { id.split(separator: "/", maxSplits: 1).dropFirst().first.map(String.init) ?? "." }

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
    var childContentIndexes: [String: Int] = [:]
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
    @ObservationIgnored private var batchOffsets: [String: Set<Int>]?

    private struct TranscriptIndex {
        struct Message: Hashable {
            let kind: ACPEntry.Kind
            let id: String
        }

        var messages: [Message: Int] = [:]
        var tools: [String: Int] = [:]
    }

    static let defaultAddress = ProcessInfo.processInfo.environment["JOHNNY_MQTT_URL"] ?? ""
    var address: String
    var fingerprint: String
    init(address: String, fingerprint: String = "") {
        self.address = address
        self.fingerprint = fingerprint
    }
    var displayName: String {
        let components = URLComponents(string: address)
        guard let host = components?.host else { return address.isEmpty ? "新服务器" : address }
        return components?.port.map { "\(host):\($0)" } ?? host
    }

    private(set) var status = "未连接"
    private(set) var connected = false
    var available: Bool { connected || offline }
    private(set) var offline = false
    var supportsSessionLoad: Bool { available }
    var supportsSessionList: Bool { available }
    var supportsDirectoryListing: Bool { connected }
    private var capabilities: [String: Bool] = [:]
    var supportsTerminalWait: Bool { capabilities["terminal_wait"] == true }
    var supportsRemoteShell: Bool { connected && capabilities["terminal"] == true }
    var supportsConfig: Bool { connected && capabilities["thread_config"] == true }
    var supportsMode: Bool { connected && capabilities["thread_mode"] == true }
    var supportsSessionRename: Bool { connected }
    func canDelete(_ session: ACPSession) -> Bool {
        guard connected else { return false }
        if session.agent == "antigravity" { return capabilities["thread_forget_antigravity"] == true }
        return capabilities["thread_delete"] == true && deletionSupport[session.id] != false
    }
    var supportsPromptImages: Bool { available }
    var supportsPromptFiles: Bool { available }
    let directory = SessionDirectory()
    private(set) var sessionOptions: [String: ACPSessionOptions] = [:]
    private(set) var loaded: Set<String> = []
    private var confirmedThreads: Set<String> = []
    private(set) var submitting: Set<String> = []
    private var steerableTurns: [String: String] = [:]
    private var steering: [String: String] = [:]

    func steeringTarget(in id: String) -> String? {
        guard prompting.contains(id), let turn = turns[id], steerableTurns[id] == turn else { return nil }
        return turn
    }

    func canSubmit(in id: String) -> Bool {
        guard loaded.contains(id), !awaitingTurnStatus(id), steering[id] == nil else { return false }
        if prompting.contains(id) { return steeringTarget(in: id) != nil }
        return !submitting.contains(id)
    }

    var prompting: Set<String> { connected ? confirmedThreads.intersection(turns.keys) : [] }

    func awaitingTurnStatus(_ id: String) -> Bool {
        turns[id] != nil && !confirmedThreads.contains(id)
    }
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
    private var recordedPermissions: [ACPPermission] = []
    var permissions: [ACPPermission] {
        connected ? recordedPermissions.filter { confirmedThreads.contains($0.sessionID) } : []
    }

    @ObservationIgnored private var broker: GoBroker?
    @ObservationIgnored private var reads: QuicReadClient?
    private struct ScopeFollower {
        let id: UUID
        let task: Task<Void, Never>
    }
    @ObservationIgnored private var followers: [String: ScopeFollower] = [:]
    @ObservationIgnored private var nextQuicAttempt = ContinuousClock.now
    @ObservationIgnored private var replica: GoReplica?
    @ObservationIgnored private var identity: DeviceIdentity?
    @ObservationIgnored private var replicaName = ""
    @ObservationIgnored private var transcriptIndexes: [String: TranscriptIndex] = [:]
    @ObservationIgnored private var threads: [String: [String: Any]] = [:]
    @ObservationIgnored private var projects = Set<ACPProject>()
    @ObservationIgnored private var hydrated = Set<String>()
    @ObservationIgnored private var subscriptions = Set<String>()
    @ObservationIgnored private var pulling: [String: Task<Void, Error>] = [:]
    @ObservationIgnored private var dirty = Set<String>()
    @ObservationIgnored private var sendStarted: [String: ContinuousClock.Instant] = [:]
    private let timingStore = ACPReplyTimingStore()
    @ObservationIgnored private var timings: [String: [String: ACPReplyTiming]] = [:]
    private var turns: [String: String] = [:]
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var epoch = ""
    private(set) var workspaceIDs: [String] = []
    private(set) var agents = ["codex"]
    private(set) var showingArchives = false
    struct QueuedPrompt: Identifiable { let id: String; let text: String }
    private(set) var queuedPrompts: [String: [QueuedPrompt]] = [:]
    @ObservationIgnored private var activeCommands = Set<String>()
    private var deletionSupport: [String: Bool] = [:]
    var deviceID: String { identity?.id ?? "" }

    func devicePublicKey() throws -> String { try deviceIdentity().publicLine }

    private func deviceIdentity() throws -> DeviceIdentity {
        if let identity { return identity }
        let key: Curve25519.Signing.PrivateKey
        if let stored = try ServerCredentialStore.deviceKey() {
            key = try .init(rawRepresentation: stored)
        } else {
            key = try .init(rawRepresentation: ServerCredentialStore.installDeviceKey(Curve25519.Signing.PrivateKey().rawRepresentation))
        }
        let result = DeviceIdentity(key: key)
        identity = result
        return result
    }

    func prepareReplica(identity: DeviceIdentity, directory: URL?) throws {
        let name = [address, fingerprint.lowercased(), identity.id].joined(separator: "\n")
        if replicaName != name {
            clearMemory()
            replica = try GoReplica(name: name, directory: directory)
            replicaName = name
        }
        epoch = UserDefaults.standard.string(forKey: "goEpoch." + name) ?? ""
        workspaceIDs = UserDefaults.standard.stringArray(forKey: "goWorkspaces." + name) ?? []
        try restoreQueue()
        offline = !workspaceIDs.isEmpty && !epoch.isEmpty
    }

    func restoreCache() throws {
        guard !fingerprint.isEmpty else { return }
        try prepareReplica(identity: deviceIdentity(), directory: nil)
    }

    func connect(testIdentity: DeviceIdentity? = nil, cacheDirectory: URL? = nil) async throws {
        if broker != nil { disconnect(reason: URLError(.cancelled)) }
        let device = try testIdentity ?? deviceIdentity()
        identity = device
        let transport = try GoBroker(address: address, fingerprint: fingerprint, identity: device)
        try prepareReplica(identity: device, directory: cacheDirectory)
        broker = transport
        status = "正在连接 MQTT…"
        transport.onClose = { [weak self, weak transport] error in
            guard let self, self.broker === transport else { return }
            self.disconnect(reason: error)
        }
        transport.onHint = { [weak self] scope in self?.hint(scope) }
        do {
            try await transport.start()
            let info = try await command("workspaces.list")
            guard let newEpoch = info["epoch"] as? String, !newEpoch.isEmpty,
                  let ids = info["workspaces"] as? [String], !ids.isEmpty else { throw ACPFailure(message: "服务器没有配置工作区") }
            if epoch != newEpoch {
                clearMemory()
            }
            epoch = newEpoch
            workspaceIDs = ids
            agents = (info["agents"] as? [String] ?? ["codex"]).filter { $0 != "pi" }
            capabilities = info["capabilities"] as? [String: Bool] ?? [:]
            if capabilities["quic_reads_v1"] == true {
                reads = QuicReadClient(address: address, fingerprint: fingerprint, identity: device)
                nextQuicAttempt = .now
            }
            UserDefaults.standard.set(epoch, forKey: "goEpoch." + replicaName)
            UserDefaults.standard.set(ids, forKey: "goWorkspaces." + replicaName)
            connected = true
            offline = false
            status = displayName
            for scope in hydrated { hint(scope) }
            poll = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(8)) } catch { return }
                    self?.catchUp()
                }
            }
            try restoreQueue()
            resumeOutbox()
        } catch {
            if broker === transport { disconnect(reason: error) }
            throw error
        }
    }

    func disconnect(reason: Error? = nil) {
        let old = broker
        broker = nil
        old?.close()
        reads?.close()
        reads = nil
        for follower in followers.values { follower.task.cancel() }
        followers.removeAll()
        poll?.cancel()
        poll = nil
        for task in pulling.values { task.cancel() }
        pulling.removeAll()
        subscriptions.removeAll()
        dirty.removeAll()
        confirmedThreads.removeAll()
        connected = false
        offline = reason != nil && !workspaceIDs.isEmpty
        status = offline ? "离线 · " + displayName : "未连接"
    }

    private func clearMemory() {
        threads.removeAll()
        projects.removeAll()
        hydrated.removeAll()
        entries.removeAll()
        timelines.removeAll()
        transcriptIndexes.removeAll()
        loaded.removeAll()
        confirmedThreads.removeAll()
        submitting.removeAll()
        turns.removeAll()
        steerableTurns.removeAll()
        steering.removeAll()
        sendStarted.removeAll()
        timings.removeAll()
        recordedPermissions.removeAll()
        sessionOptions.removeAll()
        observedCommands.removeAll()
        queuedPrompts.removeAll()
        deletionSupport.removeAll()
        directory.removeAll()
    }

    private func checked(_ reply: [String: Any]) throws -> [String: Any] {
        guard reply["ok"] as? Bool == true else {
            let fault = reply["error"] as? [String: Any]
            throw ACPFailure(message: fault?["message"] as? String ?? "服务端命令失败", reason: fault?["code"] as? String)
        }
        return reply["result"] as? [String: Any] ?? [:]
    }

    @discardableResult
    func command(_ op: String, _ fields: [String: Any] = [:], write: Bool = false, durable: Bool = false, commandID: String = UUID().uuidString.lowercased()) async throws -> [String: Any] {
        let isPrompt = op == "prompt.send" || op == "prompt.steer"
        let id = commandID
        var message = fields
        message["cmd_id"] = id
        message["op"] = op
        if write { message["epoch"] = epoch }
        let payload = try JSONSerialization.data(withJSONObject: message)
        guard payload.count <= 128 * 1024 else { throw ACPFailure(message: "消息和附件合计超过服务端 128 KiB 上限") }
        let cache = replica
        if durable {
            guard !epoch.isEmpty, let cache else { throw ACPFailure(message: "请先配对服务器") }
            if broker == nil && op != "prompt.send" { throw URLError(.notConnectedToInternet) }
            try cache.queue(id: id, epoch: epoch, payload: payload)
            if isPrompt { try restoreQueue() }
        }
        guard let broker else {
            if durable && isPrompt { return ["queued": true] }
            throw URLError(.notConnectedToInternet)
        }
        activeCommands.insert(id)
        defer { activeCommands.remove(id) }
        let reply: [String: Any]
        do {
            reply = try await broker.request(id: id, payload: payload, timeout: isPrompt ? .seconds(86400) : .seconds(60))
        } catch {
            if durable && isPrompt { return ["queued": true] }
            throw error
        }
        if durable {
            try cache?.complete(id: id, reply: reply)
            if isPrompt { try restoreQueue() }
        }
        return try checked(reply)
    }

    @ObservationIgnored private var observedCommands = Set<String>()

    private func restoreQueue() throws {
        var queued: [String: [QueuedPrompt]] = [:]
        for item in try replica?.pending(epoch: epoch) ?? [] {
            guard !observedCommands.contains(item.id),
                  let message = try JSONSerialization.jsonObject(with: item.payload) as? [String: Any],
                  let op = message["op"] as? String, ["prompt.send", "prompt.steer"].contains(op), let thread = message["thread_id"] as? String,
                  let blocks = message["prompt"] as? [[String: Any]] else { continue }
            let text = blocks.compactMap { $0["text"] as? String }.joined()
            queued[thread, default: []].append(.init(id: item.id, text: text.isEmpty ? "附件" : text))
        }
        queuedPrompts = queued
    }

    private func resumeOutbox() {
        guard connected, let cache = replica, let broker, let pending = try? cache.pending(epoch: epoch) else { return }
        var chains: [String: Task<Void, Never>] = [:]
        for item in pending where !activeCommands.contains(item.id) {
            guard let msg = try? JSONSerialization.jsonObject(with: item.payload) as? [String: Any] else { continue }
            activeCommands.insert(item.id)
            let scope = msg["thread_id"] as? String ?? item.id
            let isSteer = msg["op"] as? String == "prompt.steer"
            let previous = isSteer ? nil : chains[scope]
            let task = Task { [weak self] in
                defer { self?.activeCommands.remove(item.id) }
                await previous?.value
                guard let self, self.broker === broker else { return }
                do {
                    let reply = try await broker.request(id: item.id, payload: item.payload, timeout: .seconds(86400))
                    try cache.complete(id: item.id, reply: reply)
                    try restoreQueue()
                    _ = try checked(reply)
                } catch {
                    if self.broker === broker { self.notice(error.localizedDescription, in: scope) }
                }
            }
            if !isSteer { chains[scope] = task }
        }
    }

    func catchUp(afterForeground: Bool = false) {
        if afterForeground {
            confirmedThreads.removeAll()
            for follower in followers.values { follower.task.cancel() }
            followers.removeAll()
        }
        for scope in hydrated where followers[scope] == nil { hint(scope) }
        resumeOutbox()
    }

    private func hint(_ scope: String) {
        guard connected, hydrated.contains(scope) else { return }
        if pulling[scope] != nil { dirty.insert(scope); return }
        Task {
            guard connected, hydrated.contains(scope) else { return }
            do { try await sync(scope) } catch { if connected { status = error.localizedDescription } }
        }
    }

    private func cursorFields(_ position: GoReplica.Cursor, scope: String) -> [String: Any] {
        var fields: [String: Any] = ["scope": scope, "after": position.after, "limit": 100]
        if !position.epoch.isEmpty { fields["epoch"] = position.epoch }
        if position.through != 0 { fields["through"] = position.through }
        return fields
    }

    private func confirmActivity(_ scope: String) {
        if scope.hasPrefix("thread/") { confirmedThreads.insert(String(scope.dropFirst(7))) }
    }

    private func streamPages(_ reads: QuicReadClient, cache: GoReplica, scope: String, follow: Bool,
                             transport: GoBroker) async throws {
        let fields = cursorFields(try cache.cursor(scope), scope: scope)
        var complete = false
        let workspace = scope.hasPrefix("threads/") ? String(scope.dropFirst(8)) : nil
        var listNeedsRefresh = false
        defer {
            if listNeedsRefresh, let workspace, broker === transport { rebuildLists(workspace) }
        }
        try await reads.pages(fields, follow: follow) { page in
            try Task.checkCancellation()
            guard broker === transport, hydrated.contains(scope) else { throw CancellationError() }
            guard page["reset"] as? Bool != true else { throw ACPFailure(message: "同步游标需要重置") }
            let position = try cache.cursor(scope)
            // An idle heartbeat already matches the committed cursor.
            if position.epoch == epoch, page["epoch"] as? String == epoch, page["scope"] as? String == scope,
               page["after"] as? Int64 == position.after, page["through"] as? Int64 == position.after,
               page["more"] as? Bool == false, (page["events"] as? [Any])?.isEmpty == true {
                complete = true
                confirmActivity(scope)
                return
            }
            let events = try cache.apply(page, scope: scope, expected: position, epoch: epoch)
            complete = page["more"] as? Bool == false
            applyEvents(events, scope: scope, replay: false, refreshList: false)
            if complete { confirmActivity(scope) }
            if let workspace {
                listNeedsRefresh = listNeedsRefresh || !events.isEmpty
                if complete, listNeedsRefresh {
                    rebuildLists(workspace)
                    listNeedsRefresh = false
                }
            }
        }
        guard complete, !follow else { throw URLError(.networkConnectionLost) }
    }

    private func follow(_ scope: String, reads: QuicReadClient, cache: GoReplica, transport: GoBroker) {
        let id = UUID()
        let task = Task {
            do { try await streamPages(reads, cache: cache, scope: scope, follow: true, transport: transport) }
            catch {
                guard !Task.isCancelled, followers[scope]?.id == id, broker === transport else { return }
                followers.removeValue(forKey: scope)
                if scope.hasPrefix("thread/") { confirmedThreads.remove(String(scope.dropFirst(7))) }
                nextQuicAttempt = .now.advanced(by: .seconds(30))
                hint(scope)
            }
        }
        followers[scope] = ScopeFollower(id: id, task: task)
    }

    private func hydrate(_ scope: String, from cache: GoReplica) throws {
        let cursor = try cache.cursor(scope)
        if !cursor.epoch.isEmpty, cursor.epoch != epoch { try cache.clear(scope); resetProjection(scope) }
        if !hydrated.contains(scope) {
            let history = try cache.history(scope)
            hydrated.insert(scope)
            applyEvents(history, scope: scope, replay: true)
        }
    }

    private func sync(_ scope: String) async throws {
        guard let cache = replica else { throw ACPFailure(message: "会话缓存尚未打开") }
        try hydrate(scope, from: cache)
        guard connected, let transport = broker else { return }
        if let task = pulling[scope] { return try await task.value }
        let task = Task {
            defer { if broker === transport { pulling.removeValue(forKey: scope) } }
            followers.removeValue(forKey: scope)?.task.cancel()
            if let reads, ContinuousClock.now >= nextQuicAttempt {
                do {
                    try await streamPages(reads, cache: cache, scope: scope, follow: false, transport: transport)
                    try Task.checkCancellation()
                    guard broker === transport else { throw CancellationError() }
                    if followers.count < 16 {
                        if subscriptions.contains(scope) {
                            try await transport.subscribe("ev/" + scope, enabled: false)
                            subscriptions.remove(scope)
                        }
                        follow(scope, reads: reads, cache: cache, transport: transport)
                        return
                    }
                } catch {
                    try Task.checkCancellation()
                    guard broker === transport else { throw CancellationError() }
                    nextQuicAttempt = .now.advanced(by: .seconds(30))
                }
            }
            if !subscriptions.contains(scope) {
                try await transport.subscribe("ev/" + scope)
                subscriptions.insert(scope)
            }
            repeat {
                dirty.remove(scope)
                while true {
                    try Task.checkCancellation()
                    let position = try cache.cursor(scope)
                    let args = cursorFields(position, scope: scope)
                    let page: [String: Any]
                    do { page = try await command("sync.pull", args) }
                    catch let error as ACPFailure where error.reason == "not_found" && scope.hasPrefix("thread/") {
                        guard broker === transport else { throw CancellationError() }
                        purge(String(scope.dropFirst(7)))
                        throw error
                    }
                    try Task.checkCancellation()
                    guard broker === transport, hydrated.contains(scope) else { throw CancellationError() }
                    if page["reset"] as? Bool == true {
                        guard page["epoch"] as? String == epoch else {
                            let error = ACPFailure(message: "服务端数据库已更换，正在重新连接")
                            disconnect(reason: error)
                            throw error
                        }
                        try cache.clear(scope)
                        resetProjection(scope)
                        continue
                    }
                    let events = try cache.apply(page, scope: scope, expected: position, epoch: epoch)
                    applyEvents(events, scope: scope, replay: false)
                    if page["more"] as? Bool != true {
                        confirmActivity(scope)
                        break
                    }
                }
            } while dirty.contains(scope)
        }
        pulling[scope] = task
        try await task.value
    }

    private func resetProjection(_ scope: String) {
        if scope.hasPrefix("threads/") {
            let workspace = String(scope.dropFirst(8))
            threads = threads.filter { $0.value["workspace_id"] as? String != workspace }
            rebuildLists(workspace)
        } else {
            let id = String(scope.dropFirst(7))
            entries[id] = []
            transcriptIndexes[id] = nil
            timelines[id]?.replace([])
            turns[id] = nil
            steerableTurns[id] = nil
            confirmedThreads.remove(id)
            recordedPermissions.removeAll { $0.sessionID == id }
            sessionOptions[id] = nil
            deletionSupport[id] = nil
        }
    }

    private func applyEvents(_ events: [GoReplica.Event], scope: String, replay: Bool, refreshList: Bool = true) {
        if scope.hasPrefix("threads/") {
            for event in events {
                guard let id = event.data["thread_id"] as? String else { continue }
                if event.kind == "thread.upsert" {
                    threads[id] = event.data
                }
                if event.kind == "thread.deleted" { purge(id) }
            }
            if refreshList && (replay || !events.isEmpty) { rebuildLists(String(scope.dropFirst(8))) }
            return
        }
        let id = String(scope.dropFirst(7))
        if timelines[id] == nil { timelines[id] = TranscriptTimeline() }
        if timings[id] == nil, let url = URL(string: address) {
            timings[id] = timingStore.timings(endpoint: url, sessionID: id)
        }
        guard !events.isEmpty else { return }
        batchOffsets = [:]
        for event in events {
            let data = event.data
            switch event.kind {
            case "session.setup":
                applySessionSetup(data, to: id)
                if let allowed = data["canDelete"] as? Bool { deletionSupport[id] = allowed }
            case "session.config": apply(["sessionUpdate": "config_option_update", "configOptions": data["configOptions"] ?? []], to: id)
            case "session.mode":
                if let mode = data["currentModeId"] as? String { sessionOptions[id, default: .init()].currentModeID = mode }
            case "turn.started":
                if data["device_id"] as? String == deviceID, let cmd = data["cmd_id"] as? String {
                    if steering[id] == cmd { steering[id] = nil }
                    observedCommands.insert(cmd)
                    queuedPrompts[id]?.removeAll { $0.id == cmd }
                }
                turns[id] = data["turn_id"] as? String
                steerableTurns[id] = data["can_steer"] as? Bool == true ? turns[id] : nil
            case "message.user":
                if data["device_id"] as? String == deviceID, let cmd = data["cmd_id"] as? String {
                    if steering[id] == cmd { steering[id] = nil }
                    observedCommands.insert(cmd)
                    queuedPrompts[id]?.removeAll { $0.id == cmd }
                }
                let blocks = data["prompt"] as? [[String: Any]] ?? []
                let entry = ACPEntry(kind: .user, text: blocks.compactMap { $0["text"] as? String }.joined(),
                                     attachments: blocks.compactMap(ACPAttachment.replayPreview))
                updateTranscript(id) { history, _ in history.append(entry); return history.count - 1 }
            case "acp.history", "acp.update":
                let notification = data["notification"] as? [String: Any] ?? data
                guard let update = notification["update"] as? [String: Any] else { continue }
                let kind = update["sessionUpdate"] as? String
                if notification["protocolVersion"] as? Int == 2,
                   let session = notification["sessionId"] as? String,
                   let root = notification["rootSessionId"] as? String {
                    if kind == "subagent_update", let child = update["sessionId"] as? String {
                        applyChild(update, child: child, to: id)
                        continue
                    }
                    if session != root {
                        applyChild(update, child: session, to: id)
                        continue
                    }
                    if kind == "session_message" || kind == "session_message_chunk" {
                        let sender = update["senderSessionId"] as? String
                        if let child = sender == root ? update["recipientSessionId"] as? String : sender {
                            applyChild(update, child: child, to: id)
                        }
                        continue
                    }
                }
                if event.kind == "acp.history" || (kind != "user_message" && kind != "user_message_chunk") {
                    apply(update, to: id)
                }
            case "prompt.steer.failed":
                notice("追加失败：" + (data["message"] as? String ?? "Agent 未能处理补充消息"), in: id)
            case "permission.requested":
                guard let permission = data["permission_id"] as? String, let request = data["request"] as? [String: Any] else { continue }
                let tool = request["toolCall"] as? [String: Any]
                let options = (request["options"] as? [[String: Any]] ?? []).compactMap { item -> ACPPermission.Option? in
                    guard let option = item["optionId"] as? String, let name = item["name"] as? String else { return nil }
                    return .init(id: option, name: name)
                }
                recordedPermissions.append(.init(requestID: permission, sessionID: id, title: tool?["title"] as? String ?? "工具调用",
                                         details: tool?["rawInput"].map { String(describing: $0) }, options: options))
            case "permission.resolved":
                let key = data["permission_id"] as? String
                recordedPermissions.removeAll { $0.sessionID == id && $0.requestID as? String == key }
            case "turn.finished":
                if let turn = data["turn_id"] as? String, let url = URL(string: address) {
                    if !replay, let start = sendStarted.removeValue(forKey: id) {
                        let value = ACPReplyTiming(elapsed: start.duration(to: .now), wasStopped: data["status"] as? String == "cancelled")
                        timings[id, default: [:]][turn] = value
                        timingStore.record(value, for: turn, endpoint: url, sessionID: id)
                    }
                    if let timing = timings[id]?[turn], let last = entries[id]?.indices.last {
                        entries[id]?[last].replyTiming = timing
                        publishEntry(in: id, at: last)
                    }
                }
                if turns[id] == data["turn_id"] as? String {
                    turns[id] = nil
                    steerableTurns[id] = nil
                    recordedPermissions.removeAll { $0.sessionID == id }
                }
                if let status = data["status"] as? String, status != "finished" { notice(status, in: id) }
            default: break
            }
        }
        let offsets = batchOffsets?[id] ?? []
        batchOffsets = nil
        if !offsets.isEmpty { timelines[id]?.update(entries[id] ?? [], changedOffsets: offsets) }
    }

    private func notice(_ text: String, in id: String) {
        updateTranscript(id) { rows, _ in rows.append(ACPEntry(kind: .status, text: text)); return rows.count - 1 }
    }

    private func purge(_ id: String) {
        threads.removeValue(forKey: id)
        directory.remove(id)
        loaded.remove(id)
        if let url = URL(string: address) { timingStore.remove(endpoint: url, sessionID: id) }
        timings[id] = nil
        sendStarted[id] = nil
        let scope = "thread/" + id
        followers.removeValue(forKey: scope)?.task.cancel()
        pulling[scope]?.cancel()
        hydrated.remove(scope)
        resetProjection(scope)
        try? replica?.clear(scope)
    }

    private func rebuildLists(_ workspace: String) {
        let sorted = threads.values.filter { $0["workspace_id"] as? String == workspace && (showingArchives || $0["archived"] as? Bool != true) }
            .sorted { ($0["updated_at"] as? String ?? "") > ($1["updated_at"] as? String ?? "") }
        for project in projects where project.workspaceID == workspace {
            let rows = sorted.compactMap { item -> ListedSession? in
                guard let id = item["thread_id"] as? String, let path = item["path"] as? String,
                      project.relativePath == "." || project.relativePath == path else { return nil }
                let title = item["title"] as? String ?? ""
                return ListedSession(id: id, title: title.isEmpty ? "新会话" : title, cwd: path, agent: item["agent"] as? String)
            }
            directory.replace(rows, ids: Set(rows.map(\.id)), in: project, retaining: [], complete: true)
        }
    }

    func projectHomeDirectory(defaultPath: String?) -> String? { defaultPath ?? workspaceIDs.first }

    func listDirectories(path: String? = nil) async throws -> ACPDirectoryListing {
        let project = ACPProject(path: path ?? workspaceIDs.first)
        var dirs: [ACPDirectoryListing.Directory] = []
        var after = ""
        repeat {
            let page = try await command("directories.list", ["workspace_id": project.workspaceID, "path": project.relativePath, "name_after": after])
            let names = page["directories"] as? [String] ?? []
            dirs += names.map { .init(name: $0, path: project.id + "/" + $0) }
            guard page["more"] as? Bool == true else { break }
            guard let last = names.last, last != after else { throw ACPFailure(message: "目录分页无效") }
            after = last
        } while true
        return .init(path: project.id, parent: project.relativePath == "." ? nil : String(project.id.split(separator: "/").dropLast().joined(separator: "/")), directories: dirs)
    }

    func readProjectFile(_ path: String, session: String?, workspace: String?,
                         firstPage: ((String) -> Void)? = nil) async throws -> String {
        var location: [String: Any] = ["path": path]
        if let session { location["thread_id"] = session }
        if let workspace { location["workspace_id"] = workspace }
        if let reads, ContinuousClock.now >= nextQuicAttempt {
            do { return try await reads.file(location, firstPage: firstPage) }
            catch {
                try Task.checkCancellation()
                guard self.reads === reads else { throw CancellationError() }
                if !(error is ACPFailure) { nextQuicAttempt = .now.advanced(by: .seconds(30)) }
            }
        }
        for attempt in 0...1 {
            var bytes = Data()
            var version = ""
            do {
                while true {
                    try Task.checkCancellation()
                    var arguments: [String: Any] = ["path": path, "offset": bytes.count, "version": version, "limit": 168 * 1024]
                    if let session { arguments["thread_id"] = session }
                    if let workspace { arguments["workspace_id"] = workspace }
                    let page = try await command("file.read", arguments)
                    try Task.checkCancellation()
                    guard let encoded = page["bytes"] as? String, let part = Data(base64Encoded: encoded),
                          let v = page["version"] as? String, version.isEmpty || version == v,
                          page["next_offset"] as? Int == bytes.count + part.count else { throw ACPFailure(message: "文件分块无效") }
                    bytes.append(part)
                    version = v
                    if page["more"] as? Bool != true { return String(decoding: bytes, as: UTF8.self) }
                    guard !part.isEmpty else { throw ACPFailure(message: "文件分块为空") }
                }
            } catch let error as ACPFailure where error.reason == "file_changed" && attempt == 0 { continue }
        }
        throw ACPFailure(message: "读取期间文件已变更")
    }

    func listSessions(in project: ACPProject) async throws {
        let inserted = projects.insert(project).inserted
        try await sync("threads/" + project.workspaceID)
        if inserted { rebuildLists(project.workspaceID) }
    }

    func refreshSessions(in project: ACPProject, agent: String = "codex") async throws {
        try await command("thread.refresh", ["workspace_id": project.workspaceID, "agent": agent], write: true, durable: true)
        try await listSessions(in: project)
    }

    func createSession(in project: ACPProject, agent: String = "codex") async throws -> String {
        let row = try await command("thread.create", ["workspace_id": project.workspaceID, "path": project.relativePath, "agent": agent], write: true, durable: true)
        guard let id = row["thread_id"] as? String else { throw ACPFailure(message: "服务器未返回会话 ID") }
        try await listSessions(in: project)
        try await sync("thread/" + id)
        loaded.insert(id)
        return id
    }

    func restoreCachedTranscript(_ id: String) throws {
        let scope = "thread/" + id
        guard let cache = replica, !epoch.isEmpty else { return }
        let cursor = try cache.cursor(scope)
        guard cursor.epoch == epoch else { return }
        try hydrate(scope, from: cache)
        // A completed local snapshot can be opened while the transport catches up.
        // A first import interrupted between pages still uses the normal load path.
        guard cursor.through == 0, threads[id]?["history_imported"] as? Bool == true,
              loaded.insert(id).inserted else { return }
        if connected, followers[scope] == nil, pulling[scope] == nil { hint(scope) }
    }

    func restoreCachedDirectory(_ project: ACPProject) throws {
        guard let cache = replica, !epoch.isEmpty else { return }
        let scope = "threads/" + project.workspaceID
        guard try cache.cursor(scope).epoch == epoch else { return }
        let inserted = projects.insert(project).inserted
        try hydrate(scope, from: cache)
        if inserted { rebuildLists(project.workspaceID) }
    }

    func load(_ session: ACPSession) async throws {
        let scope = "thread/" + session.id
        try restoreCachedTranscript(session.id)
        if loaded.contains(session.id) { return }
        if connected {
            // Imported threads already have a durable transcript. Prompt and
            // settings commands attach the upstream agent when they need it.
            if threads[session.id]?["history_imported"] as? Bool != true {
                do { try await command("thread.open", ["thread_id": session.id], write: true) }
                catch let error as ACPFailure where error.reason == "thread_busy" {
                    // An active turn can already be followed via its durable event stream.
                }
            }
        }
        else if try replica?.cursor(scope).epoch.isEmpty != false { throw ACPFailure(message: "此会话尚未缓存") }
        try await sync(scope)
        loaded.insert(session.id)
    }

    func restoreUnlistedSession(_ session: ACPSession, in project: ACPProject) async throws {
        try await load(session)
        directory.insert(session, in: project, atFront: false)
    }

    func close(_ id: String) async throws {
        let scope = "thread/" + id
        loaded.remove(id)
        followers.removeValue(forKey: scope)?.task.cancel()
        pulling[scope]?.cancel()
        hydrated.remove(scope)
        resetProjection(scope)
        if subscriptions.remove(scope) != nil, let broker { try await broker.subscribe("ev/" + scope, enabled: false) }
    }

    func toggleArchives() {
        showingArchives.toggle()
        for workspace in workspaceIDs { rebuildLists(workspace) }
    }
    func isArchived(_ id: String) -> Bool { threads[id]?["archived"] as? Bool == true }
    func setArchived(_ archived: Bool, in id: String) async throws {
        try await command("thread.archive", ["thread_id": id, "archived": archived], write: true, durable: true)
        if let workspace = threads[id]?["workspace_id"] as? String { try await sync("threads/" + workspace) }
    }

    func deleteSession(_ session: ACPSession) async throws {
        let operation = session.agent == "antigravity" ? "thread.forget" : "thread.delete"
        try await command(operation, ["thread_id": session.id], write: true, durable: true)
        purge(session.id)
    }

    func renameSession(_ session: ACPSession, to draft: String) async throws {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ACPFailure(message: "会话名称不能为空") }
        let row = try await command("thread.rename", ["thread_id": session.id, "title": title], write: true, durable: true)
        directory.updateTitle(row["title"] as? String ?? title, for: session.id)
        if let ws = threads[session.id]?["workspace_id"] as? String { try await sync("threads/" + ws) }
    }

    func setConfigOption(_ option: ACPConfigOption, value: String, in id: String) async throws {
        try await setConfig(option.id, value: value, in: id)
    }
    func setConfigOption(_ option: ACPConfigOption, enabled: Bool, in id: String) async throws {
        try await setConfig(option.id, value: enabled, in: id)
    }
    private func setConfig(_ config: String, value: Any, in id: String) async throws {
        let result = try await command("thread.set_config", ["thread_id": id, "config_id": config, "value": value], write: true, durable: true)
        applySessionSetup(result, to: id)
    }
    func setMode(_ mode: String, in id: String) async throws {
        let result = try await command("thread.set_mode", ["thread_id": id, "mode_id": mode], write: true, durable: true)
        sessionOptions[id, default: .init()].currentModeID = result["currentModeId"] as? String ?? mode
    }
    private func applySessionSetup(_ result: [String: Any], to id: String) {
        var options = sessionOptions[id, default: ACPSessionOptions()]
        if let config = result["configOptions"] as? [[String: Any]] { options.config = ACPConfigOption.decode(config) }
        if let raw = result["modes"], let modes = decodeACP(ACPSessionModes.self, from: raw) {
            options.modes = modes
            options.currentModeID = modes.currentModeId
        }
        if let meta = result["_meta"] as? [String: Any], let commands = meta["johnnybotAvailableCommands"] as? [[String: Any]] {
            options.commands = commands.compactMap { decodeACP(ACPCommand.self, from: $0) }
        }
        sessionOptions[id] = options
    }
    func prompt(_ text: String, attachments: [ACPAttachment] = [], in id: String, steeringTurn: String? = nil) async throws {
        guard loaded.contains(id), steeringTurn != nil || (canSubmit(in: id) && !prompting.contains(id)) else { throw ACPFailure(message: "会话尚未就绪") }
        var blocks: [[String: Any]] = text.isEmpty ? [] : [["type": "text", "text": text]]
        blocks += attachments.map(\.promptBlock)
        guard (1...32).contains(blocks.count) else { throw ACPFailure(message: "每条消息支持 1 至 32 项内容") }
        if let turn = steeringTurn {
            guard connected, steering[id] == nil else { throw ACPFailure(message: "暂时无法追加消息") }
            let cmd = UUID().uuidString.lowercased()
            steering[id] = cmd
            defer { if steering[id] == cmd { steering[id] = nil } }
            do {
                _ = try await command("prompt.steer", ["thread_id": id, "turn_id": turn, "prompt": blocks], write: true, durable: true, commandID: cmd)
            } catch let error as ACPFailure where error.reason == "not_active" {
                try await sync("thread/" + id)
                guard turns[id] == nil else { throw error }
                let next = UUID().uuidString.lowercased()
                steering[id] = next
                defer { if steering[id] == next { steering[id] = nil } }
                _ = try await command("prompt.send", ["thread_id": id, "prompt": blocks], write: true, durable: true, commandID: next)
            }
            return
        }
        submitting.insert(id)
        if connected { sendStarted[id] = .now }
        defer { submitting.remove(id) }
        let result = try await command("prompt.send", ["thread_id": id, "prompt": blocks], write: true, durable: true)
        if result["queued"] as? Bool == true { sendStarted[id] = nil }
        else { try await sync("thread/" + id) }
    }
    func cancelPrompt(in id: String) async throws {
        guard prompting.contains(id), let turn = turns[id] else { return }
        do {
            try await command("turn.cancel", ["thread_id": id, "turn_id": turn], write: true)
        } catch let error as ACPFailure where error.reason == "not_active" {
            if turns[id] == turn { turns[id] = nil }
        }
        try await sync("thread/" + id)
    }
    func respond(to permission: ACPPermission, option: String?) async throws {
        let id = permission.sessionID
        guard let option else { try await cancelPrompt(in: id); return }
        guard let key = permission.requestID as? String, let turn = turns[id] else { return }
        try await command("permission.answer", ["thread_id": id, "turn_id": turn, "permission_id": key, "option_id": option], write: true)
        try await sync("thread/" + id)
    }

    private func updateTranscript(_ id: String, _ apply: (inout [ACPEntry], inout TranscriptIndex) -> Int?) {
        if let offset = apply(&entries[id, default: []], &transcriptIndexes[id, default: TranscriptIndex()]) {
            publishEntry(in: id, at: offset)
        }
    }

    private func applyChild(_ update: [String: Any], child: String, to id: String) {
        guard let kind = update["sessionUpdate"] as? String else { return }
        let key = "johnnybot/subagent/" + child
        updateTranscript(id) { history, index in
            let offset = index.tools[key] ?? history.count
            if offset == history.count {
                index.tools[key] = offset
                history.append(ACPEntry(kind: .tool, text: "子 Agent", toolID: key, toolStatus: "pending"))
            }
            let state = kind == "subagent_update" ? update["state"] as? [String: Any] : update
            switch state?["state"] as? String {
            case "idle": history[offset].toolStatus = state?["stopReason"] as? String == "error" ? "failed" : "completed"
            case "running", "requires_action": history[offset].toolStatus = "in_progress"
            default: break
            }
            if kind == "subagent_update", let title = update["title"] as? String { history[offset].text = title }
            let item: String
            var text: String
            if kind == "subagent_update", let description = update["description"] as? String {
                item = "description"
                text = description
            } else if let tool = update["toolCallId"] as? String, let title = update["title"] as? String {
                item = "tool/" + tool
                text = title
            } else if let message = update["messageId"] as? String, let content = update["content"] {
                item = "message/" + message
                let blocks = content as? [[String: Any]] ?? [content as? [String: Any] ?? [:]]
                text = blocks.compactMap { $0["text"] as? String }.joined()
            } else { return offset }
            if let previous = history[offset].childContentIndexes[item] {
                if kind.hasSuffix("_chunk"), case let .text(old) = history[offset].toolContent[previous] {
                    text = old + text
                }
                history[offset].toolContent[previous] = .text(text)
            } else {
                history[offset].childContentIndexes[item] = history[offset].toolContent.count
                history[offset].toolContent.append(.text(text))
            }
            return offset
        }
    }

    private func apply(_ update: [String: Any], to id: String) {
        let kind = update["sessionUpdate"] as? String
        switch kind {
        case "agent_message_chunk", "user_message_chunk", "agent_thought_chunk", "agent_message", "user_message", "agent_thought":
            guard let raw = update["content"] else { return }
            let snapshot = kind?.hasSuffix("_chunk") == false
            let blocks = raw as? [[String: Any]] ?? (raw as? [String: Any]).map { [$0] } ?? []
            let messageID = update["messageId"] as? String
            let meta = update["_meta"] as? [String: Any]
            let jetBrains = meta?["jetbrains"] as? [String: Any]
            let air = jetBrains?["air"] as? [String: Any]
            let phase = (air?["phase"] as? String).flatMap(ACPEntry.MessagePhase.init(rawValue:))
            let entryKind: ACPEntry.Kind
            switch kind {
            case "user_message_chunk", "user_message": entryKind = .user
            case "agent_thought_chunk", "agent_thought": entryKind = .thought
            default: entryKind = .agent
            }
            let attachments = entryKind == .user ? blocks.compactMap(ACPAttachment.replayPreview) : []
            let text = blocks.compactMap { content -> String? in
                if let text = content["text"] as? String { return text }
                if entryKind == .user, ACPAttachment.replayPreview(content) != nil { return nil }
                return "[\(content["type"] as? String ?? "内容")]"
            }.joined()
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
                    if snapshot {
                        history[previousIndex].text = text
                        history[previousIndex].attachments = attachments
                    } else {
                        history[previousIndex].text += text
                        history[previousIndex].attachments += attachments
                    }
                    if let phase { history[previousIndex].phase = phase }
                    return previousIndex
                } else {
                    if let key { index.messages[key] = history.count }
                    history.append(ACPEntry(kind: entryKind, text: text, messageID: messageID, phase: phase,
                                            attachments: attachments))
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
        default:
            break
        }
    }
}
