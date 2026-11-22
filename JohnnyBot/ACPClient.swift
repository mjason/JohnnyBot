import Foundation
import Observation

struct ACPFailure: LocalizedError {
    let message: String
    let code: Int?

    init(message: String, code: Int? = nil) {
        self.message = message
        self.code = code
    }

    var errorDescription: String? { message }
}

struct ACPSession: Identifiable {
    let id: String
    var title: String
    var cwd = ""
}

struct ACPEntry: Identifiable {
    let id = UUID()
    let role: String
    var text: String
    var toolID: String? = nil
    var toolStatus: String?
    var toolOutput: String?
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
    static let defaultAddress = "ws://192.168.2.70:8765/acp"

    var address: String
    var token: String

    init(address: String, token: String) {
        self.address = address
        self.token = token
    }
    private(set) var status = "未连接"
    private(set) var connected = false
    private(set) var supportsSessionDelete = false
    private var supportsSessionClose = false
    private(set) var sessions: [ACPSession] = []
    private(set) var loaded: Set<String> = []
    private(set) var prompting: Set<String> = []
    private(set) var entries: [String: [ACPEntry]] = [:]
    private(set) var permissions: [ACPPermission] = []

    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    @ObservationIgnored private var nextID = 0

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
        let credential = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty, !credential.contains(where: \.isNewline) else {
            throw ACPFailure(message: "请输入有效的令牌")
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        status = "正在连接…"
        task.resume()
        Task { await receive(from: task) }
        do {
            let info = try await call("initialize", ["protocolVersion": 1, "clientCapabilities": [:]])
            guard info["protocolVersion"] as? Int == 1 else {
                throw ACPFailure(message: "服务器未协商 ACP v1")
            }
            let capabilities = info["agentCapabilities"] as? [String: Any]
            let sessionCapabilities = capabilities?["sessionCapabilities"] as? [String: Any]
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

    func disconnect(reason: Error? = nil) {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        connected = false
        supportsSessionDelete = false
        supportsSessionClose = false
        status = reason.map { "连接中断 · \($0.localizedDescription)" } ?? "未连接"
        let requests = pending
        pending.removeAll()
        for continuation in requests.values {
            continuation.resume(throwing: reason ?? ACPFailure(message: "连接已断开"))
        }
        loaded.removeAll()
        prompting.removeAll()
        permissions.removeAll()
        sessions.removeAll()
        entries.removeAll()
    }

    func listSessions() async throws {
        var listed: [ACPSession] = []
        var cursor: String?
        var seenCursors: Set<String> = []
        repeat {
            let result = try await call("session/list", cursor.map { ["cursor": $0] } ?? [:])
            for item in result["sessions"] as? [[String: Any]] ?? [] {
                guard let id = item["sessionId"] as? String, !listed.contains(where: { $0.id == id }) else { continue }
                listed.append(ACPSession(id: id, title: item["title"] as? String ?? "未命名会话", cwd: item["cwd"] as? String ?? ""))
            }
            cursor = result["nextCursor"] as? String
            if let cursor, !cursor.isEmpty, !seenCursors.insert(cursor).inserted {
                throw ACPFailure(message: "服务器返回重复的分页游标")
            }
        } while cursor?.isEmpty == false
        let listedIDs = Set(listed.map(\.id))
        sessions = listed + sessions.filter { loaded.contains($0.id) && !listedIDs.contains($0.id) }
    }

    func createSession() async throws -> String {
        let result = try await call("session/new", ["mcpServers": []])
        guard let id = result["sessionId"] as? String else {
            throw ACPFailure(message: "服务器未返回会话 ID")
        }
        sessions.insert(ACPSession(id: id, title: "新会话"), at: 0)
        loaded.insert(id)
        return id
    }

    func load(_ id: String) async throws {
        guard !loaded.contains(id) else { return }
        entries[id] = []
        do {
            _ = try await call("session/load", ["sessionId": id, "mcpServers": []])
            loaded.insert(id)
        } catch {
            entries.removeValue(forKey: id)
            throw error
        }
    }

    func close(_ id: String) async throws {
        _ = try await call("session/close", ["sessionId": id])
        loaded.remove(id)
        permissions.removeAll { $0.sessionID == id }
    }

    func deleteSession(_ id: String) async throws {
        guard supportsSessionDelete else {
            throw ACPFailure(message: "服务器不支持删除会话")
        }
        guard !prompting.contains(id) else {
            throw ACPFailure(message: "请先停止当前回复")
        }

        if loaded.contains(id), supportsSessionClose {
            do {
                try await close(id)
            } catch let error as ACPFailure where error.code == -32002 {
                loaded.remove(id)
                permissions.removeAll { $0.sessionID == id }
            }
        }
        do {
            _ = try await call("session/delete", ["sessionId": id])
        } catch let error as ACPFailure where error.code == -32002 {
            // The server has already removed this session.
        }
        loaded.remove(id)
        entries.removeValue(forKey: id)
        permissions.removeAll { $0.sessionID == id }
        sessions.removeAll { $0.id == id }
    }

    func prompt(_ text: String, in id: String) async throws {
        guard loaded.contains(id), prompting.insert(id).inserted else { return }
        defer { prompting.remove(id) }
        entries[id, default: []].append(ACPEntry(role: "你", text: text))
        let result = try await call("session/prompt", [
            "sessionId": id, "prompt": [["type": "text", "text": text]]
        ])
        if let reason = result["stopReason"] as? String, reason != "end_turn" {
            entries[id, default: []].append(ACPEntry(role: "状态", text: reason))
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

    private func receive(from socket: URLSessionWebSocketTask) async {
        do {
            while self.socket === socket {
                let frame = try await socket.receive()
                guard self.socket === socket else { return }
                guard case .string(let text) = frame,
                      let message = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                      message["jsonrpc"] as? String == "2.0" else { continue }
                if let method = message["method"] as? String {
                    try await handle(method, message: message, socket: socket)
                } else if let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
                    if let error = message["error"] as? [String: Any] {
                        continuation.resume(throwing: ACPFailure(
                            message: error["message"] as? String ?? "服务器请求失败",
                            code: error["code"] as? Int
                        ))
                    } else if let result = message["result"] {
                        continuation.resume(returning: result as? [String: Any] ?? [:])
                    } else {
                        continuation.resume(throwing: ACPFailure(message: "服务器响应缺少 result"))
                    }
                }
            }
        } catch {
            if self.socket === socket { disconnect(reason: error) }
        }
    }

    private func handle(_ method: String, message: [String: Any], socket: URLSessionWebSocketTask) async throws {
        let params = message["params"] as? [String: Any] ?? [:]
        let sessionID = params["sessionId"] as? String
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
        } else if method == "session/update", let sessionID, let update = params["update"] as? [String: Any] {
            apply(update, to: sessionID)
        }
    }

    private func apply(_ update: [String: Any], to id: String) {
        let kind = update["sessionUpdate"] as? String
        switch kind {
        case "agent_message_chunk", "user_message_chunk", "agent_thought_chunk":
            guard let content = update["content"] as? [String: Any] else { return }
            let text = content["text"] as? String ?? "[\(content["type"] as? String ?? "内容")]"
            let role = kind == "user_message_chunk" ? "你" : kind == "agent_thought_chunk" ? "思考" : "Agent"
            if let last = entries[id]?.indices.last, entries[id]?[last].role == role, role != "你" {
                entries[id]?[last].text += text
            } else {
                entries[id, default: []].append(ACPEntry(role: role, text: text))
            }
        case "tool_call", "tool_call_update":
            guard let toolID = update["toolCallId"] as? String else { return }
            if entries[id]?.contains(where: { $0.toolID == toolID }) != true {
                entries[id, default: []].append(ACPEntry(role: "工具", text: toolID, toolID: toolID))
            }
            guard let index = entries[id]?.firstIndex(where: { $0.toolID == toolID }) else { return }
            if let title = update["title"] as? String { entries[id]?[index].text = title }
            if let status = update["status"] as? String { entries[id]?[index].toolStatus = status }
            if let blocks = update["content"] as? [[String: Any]] {
                entries[id]?[index].toolOutput = blocks.compactMap { block -> String? in
                    switch block["type"] as? String {
                    case "content":
                        return (block["content"] as? [String: Any])?["text"] as? String
                    case "diff":
                        return [block["path"], block["newText"]].compactMap { $0 as? String }.joined(separator: "\n")
                    default:
                        return nil
                    }
                }.joined(separator: "\n")
            }
        case "plan":
            let steps = (update["entries"] as? [[String: Any]] ?? []).compactMap { step -> String? in
                guard let content = step["content"] as? String else { return nil }
                return "\(step["status"] as? String ?? "")  \(content)"
            }
            entries[id, default: []].append(ACPEntry(role: "计划", text: steps.joined(separator: "\n")))
        case "session_info_update":
            if let title = update["title"] as? String, let index = sessions.firstIndex(where: { $0.id == id }) {
                sessions[index].title = title
            }
        default:
            break
        }
    }
}
