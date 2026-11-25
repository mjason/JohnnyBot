import Foundation
import Observation
import SwiftTerm
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor @Observable
final class RemoteShell: TerminalViewDelegate {
    enum State: Equatable {
        case detached, connecting, attached, empty, ended(Int), failed(String)
    }

    struct Access: Equatable {
        let hasControl: Bool
        let hasController: Bool
    }

    struct Tab: Identifiable, Decodable, Equatable {
        let id: String
        let title: String
        let cwd: String
        let command: String?
    }

    private(set) var state: State = .detached
    private(set) var tabs: [Tab] = []
    private(set) var selectedTab: String?
    private(set) var isChangingTab = false
    private(set) var access: Access?
    private(set) var hiddenTabs: Set<String> = []
    var commandError: String?

    var visibleTabs: [Tab] { tabs.filter { !hiddenTabs.contains($0.id) } }
    var activeTab: Tab? { visibleTabs.first { $0.id == selectedTab } }
    private(set) var running = false
    var canSendInput: Bool { running && state == .attached && activeTab != nil && (access?.hasControl == true) }

    @ObservationIgnored private weak var client: ACPClient?
    @ObservationIgnored private var project = ACPProject(path: nil)
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private var writer: Task<Void, Never>?
    @ObservationIgnored private var inputs: AsyncStream<(String, Data)>.Continuation?
    @ObservationIgnored private var dimensions = (cols: 80, rows: 24)
    @ObservationIgnored private var offset = 0
    @ObservationIgnored private var generation = UUID()

    @ObservationIgnored private(set) lazy var view: TerminalView = {
#if os(macOS)
        let view = TerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        view.nativeForegroundColor = .textColor
        view.nativeBackgroundColor = .textBackgroundColor
        view.setAccessibilityLabel("远程终端")
#else
        let view = IOSRemoteTerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        view.nativeForegroundColor = .label
        view.nativeBackgroundColor = .systemBackground
        view.accessibilityLabel = "远程终端"
#endif
        view.terminalDelegate = self
        return view
    }()

    func attach(client: ACPClient, project: ACPProject) {
        guard self.client == nil || state == .empty else { return }
        detach()
        self.client = client
        self.project = project
        state = .connecting
        let ticket = generation
        let (stream, continuation) = AsyncStream<(String, Data)>.makeStream(bufferingPolicy: .bufferingOldest(64))
        inputs = continuation
        writer = Task {
            for await (id, data) in stream {
                guard generation == ticket else { return }
                do {
                    try await client.command("terminal.input", ["terminal_id": id, "bytes": data.base64EncodedString()], write: true)
                } catch { if generation == ticket { commandError = error.localizedDescription } }
            }
        }
        reader = Task {
            do {
                try await refresh(client, ticket: ticket)
                guard generation == ticket else { return }
                if tabs.isEmpty { try await create(client, ticket: ticket) }
                state = .attached
                var nextList = ContinuousClock.now
                while !Task.isCancelled {
                    if ContinuousClock.now >= nextList {
                        try await refresh(client, ticket: ticket)
                        nextList = .now.advanced(by: .seconds(2))
                    }
                    guard generation == ticket else { return }
                    if let id = selectedTab, !isChangingTab {
                        let start = offset
                        let result = try await client.command("terminal.read", ["terminal_id": id, "offset": offset])
                        guard generation == ticket else { return }
                        if selectedTab == id, offset == start {
                            if let terminal = result["terminal"] as? [String: Any] { updateAccess(terminal, client: client) }
                            if result["reset"] as? Bool == true { view.resetToInitialState() }
                            if let encoded = result["bytes"] as? String, let data = Data(base64Encoded: encoded), !data.isEmpty {
                                view.feed(byteArray: Array(data)[...])
                            }
                            if let next = result["next_offset"] as? Int { offset = next }
                        }
                    }
                    try await Task.sleep(for: .milliseconds(90))
                }
            } catch {
                if generation == ticket { detach(); state = .failed(error.localizedDescription) }
            }
        }
    }

    private func refresh(_ client: ACPClient, ticket: UUID) async throws {
        let result = try await client.command("terminal.list", ["workspace_id": project.workspaceID])
        guard generation == ticket else { return }
        let all = (result["terminals"] as? [[String: Any]] ?? []).filter { $0["workspace_id"] as? String == project.workspaceID && $0["path"] as? String == project.relativePath }
        let nextTabs: [Tab] = all.compactMap { item in
            guard let id = item["terminal_id"] as? String else { return nil }
            return Tab(id: id, title: item["title"] as? String ?? "终端", cwd: item["path"] as? String ?? ".", command: nil)
        }
        if nextTabs != tabs {
            tabs = nextTabs
            hiddenTabs.formIntersection(tabs.map(\.id))
        }
        if !tabs.contains(where: { $0.id == selectedTab }) { switchTo(visibleTabs.first?.id) }
        if let item = all.first(where: { $0["terminal_id"] as? String == selectedTab }) { updateAccess(item, client: client) }
    }

    private func updateAccess(_ terminal: [String: Any], client: ACPClient) {
        let owner = terminal["controller_device_id"] as? String ?? ""
        let nextRunning = terminal["running"] as? Bool == true
        let nextAccess = Access(hasControl: owner == client.deviceID, hasController: !owner.isEmpty)
        if running != nextRunning { running = nextRunning }
        if access != nextAccess { access = nextAccess }
    }

    private func switchTo(_ id: String?) {
        selectedTab = id
        offset = 0
        access = nil
        view.resetToInitialState()
    }

    private func create(_ client: ACPClient, ticket: UUID) async throws {
        let result = try await client.command("terminal.create", ["workspace_id": project.workspaceID, "path": project.relativePath,
                                                                  "cols": dimensions.cols, "rows": dimensions.rows], write: true)
        guard generation == ticket else { return }
        guard let terminal = result["terminal"] as? [String: Any], let id = terminal["terminal_id"] as? String else {
            throw ACPFailure(message: "服务端未返回终端 ID")
        }
        switchTo(id)
        try await refresh(client, ticket: ticket)
    }

    private func change(_ operation: @escaping (ACPClient, UUID) async throws -> Void) {
        guard let client, !isChangingTab else { return }
        let ticket = generation
        isChangingTab = true
        Task {
            defer { if generation == ticket { isChangingTab = false } }
            do { try await operation(client, ticket) }
            catch { if generation == ticket { commandError = error.localizedDescription } }
        }
    }

    func detach() {
        generation = UUID()
        reader?.cancel()
        writer?.cancel()
        reader = nil
        writer = nil
        inputs?.finish()
        inputs = nil
        client = nil
        isChangingTab = false
        state = .detached
        access = nil
    }

    func createTab() {
        change { client, ticket in try await self.create(client, ticket: ticket) }
    }
    func selectTab(_ id: String) {
        guard id != selectedTab else { return }
        switchTo(id)
    }
    func closeTab(_ id: String) {
        change { client, ticket in
            try await client.command("terminal.close", ["terminal_id": id], write: true)
            try await self.refresh(client, ticket: ticket)
            if self.generation == ticket && self.tabs.isEmpty { self.detach(); self.state = .empty }
        }
    }
    func hideTab(_ id: String) {
        let previous = visibleTabs
        guard let index = previous.firstIndex(where: { $0.id == id }) else { return }
        hiddenTabs.insert(id)
        let remaining = visibleTabs
        if selectedTab == id, !remaining.isEmpty {
            selectTab(remaining[min(index, remaining.count - 1)].id)
        }
    }

    func restoreHiddenTabs() {
        hiddenTabs.removeAll()
    }

    func takeControl() {
        guard let id = selectedTab else { return }
        change { client, ticket in
            try await client.command("terminal.claim", ["terminal_id": id], write: true)
            try await self.refresh(client, ticket: ticket)
            if self.generation == ticket { self.reportSize() }
        }
    }

#if !os(macOS)
    func updateInputFocus() {
        guard let view = view as? IOSRemoteTerminalView else { return }
        view.inputEnabled = canSendInput
        if !canSendInput, view.isFirstResponder { _ = view.resignFirstResponder() }
    }
#endif

    private func reportSize() {
        guard let client, let id = selectedTab, canSendInput else { return }
        let size = dimensions
        Task {
            do { try await client.command("terminal.resize", ["terminal_id": id, "cols": size.cols, "rows": size.rows], write: true) }
            catch { commandError = error.localizedDescription }
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard newCols > 0, newRows > 0 else { return }
        let size = (cols: min(512, newCols), rows: min(256, newRows))
        guard size != dimensions else { return }
        dimensions = size
        reportSize()
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard canSendInput, !isChangingTab, let id = selectedTab else { return }
        var remaining = data
        while !remaining.isEmpty {
            let chunk = remaining.prefix(32768)
            if case .dropped? = inputs?.yield((id, Data(chunk))) {
                commandError = "终端输入队列已满，后续内容尚未发送"
                return
            }
            remaining = remaining.dropFirst(chunk.count)
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

#if !os(macOS)
private final class IOSRemoteTerminalView: TerminalView {
    var inputEnabled = false
    override var canBecomeFirstResponder: Bool { inputEnabled && super.canBecomeFirstResponder }
}
#endif
