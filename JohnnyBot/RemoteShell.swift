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

    private struct Request: Encodable {
        let type: String
        var cwd: String?
        var tab: String?
        var cols: Int?
        var rows: Int?
        var direction: ViewportDirection?
    }

    enum ViewportDirection: String, Encodable, CaseIterable, Identifiable {
        case left, right, up, down, follow

        var id: Self { self }
        var label: String {
            switch self {
            case .left: "向左"
            case .right: "向右"
            case .up: "向上"
            case .down: "向下"
            case .follow: "跟随光标"
            }
        }
        var icon: String {
            switch self {
            case .left: "arrow.left"
            case .right: "arrow.right"
            case .up: "arrow.up"
            case .down: "arrow.down"
            case .follow: "scope"
            }
        }
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

    private struct Event: Decodable {
        let type: String
        var cwd: String?
        var code: Int?
        var message: String?
        var tabs: [Tab]?
        var selectedTab: String?
        var completed: Bool?
        var tab: String?
        var hasControl: Bool?
        var hasController: Bool?

        var access: Access? {
            hasControl.map { Access(hasControl: $0, hasController: hasController ?? $0) }
        }
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
    var canSendInput: Bool { state == .attached && activeTab != nil && (access?.hasControl ?? true) }

    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private var writer: Task<Void, Never>?
    @ObservationIgnored private var outgoing: AsyncStream<URLSessionWebSocketTask.Message>.Continuation?
    @ObservationIgnored private var dimensions = (cols: 80, rows: 24)
    @ObservationIgnored private var closingLastTab = false

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

    func attach(request: URLRequest, directory: String?) {
        guard socket == nil else { return }
        view.resetToInitialState()
        state = .connecting
        let connection = URLSession.shared.webSocketTask(with: request)
        connection.maximumMessageSize = 1024 * 1024
        socket = connection
        let (messages, continuation) = AsyncStream<URLSessionWebSocketTask.Message>.makeStream(bufferingPolicy: .bufferingOldest(256))
        outgoing = continuation
        enqueue(Request(type: "attach", cwd: directory, tab: selectedTab, cols: dimensions.cols, rows: dimensions.rows))
        connection.resume()

        writer = Task { [weak self] in
            do {
                for await message in messages { try await connection.send(message) }
            } catch {
                self?.connectionFailed(connection, error: error)
            }
        }
        reader = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await connection.receive()
                    guard let self, self.socket === connection else { return }
                    self.receive(message)
                }
            } catch {
                self?.connectionFailed(connection, error: error)
            }
        }
    }

    func detach() {
        finish(.detached)
    }

    func createTab(in directory: String?) {
        changeTab(Request(type: "newTab", cwd: directory))
    }

    func selectTab(_ id: String) {
        guard id != selectedTab else { return }
        changeTab(Request(type: "selectTab", tab: id))
    }

    func closeTab(_ id: String) {
        guard state == .attached, !isChangingTab else { return }
        closingLastTab = tabs.count == 1 && tabs.first?.id == id
        changeTab(Request(type: "closeTab", tab: id))
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
        guard let selectedTab, access?.hasControl == false else { return }
        changeTab(Request(type: "takeControl", tab: selectedTab))
    }

    func releaseControl() {
        guard let selectedTab, access?.hasControl == true else { return }
        changeTab(Request(type: "releaseControl", tab: selectedTab))
    }

    func moveViewport(_ direction: ViewportDirection) {
        guard let selectedTab, access?.hasControl == false else { return }
        changeTab(Request(type: "pan", tab: selectedTab, direction: direction))
    }

#if !os(macOS)
    func updateInputFocus() {
        guard let view = view as? IOSRemoteTerminalView else { return }
        view.inputEnabled = canSendInput
        if !canSendInput, view.isFirstResponder { _ = view.resignFirstResponder() }
    }
#endif

    private func changeTab(_ request: Request) {
        guard state == .attached, !isChangingTab else { return }
        isChangingTab = true
        enqueue(request)
    }

    private func finish(_ nextState: State) {
        let connection = socket
        socket = nil
        outgoing?.finish()
        outgoing = nil
        writer?.cancel()
        reader?.cancel()
        writer = nil
        reader = nil
        isChangingTab = false
        closingLastTab = false
        access = nil
        connection?.cancel(with: .normalClosure, reason: nil)
        state = nextState
    }

    private func connectionFailed(_ connection: URLSessionWebSocketTask, error: Error) {
        guard socket === connection else { return }
        finish(.failed(error.localizedDescription))
    }

    private func receive(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            view.feed(byteArray: Array(data)[...])
        case .string(let text):
            guard let event = try? JSONDecoder().decode(Event.self, from: Data(text.utf8)) else { return }
            switch event.type {
            case "ready":
                updateTabs(event.tabs ?? [])
                selectedTab = event.selectedTab
                access = event.access
                state = .attached
                reportSize()
            case "tabs":
                if event.tabs?.isEmpty == true {
                    finishEmpty()
                    return
                }
                if let nextTabs = event.tabs { updateTabs(nextTabs) }
                if selectedTab != event.selectedTab { selectedTab = event.selectedTab }
                if access != event.access { access = event.access }
                if event.completed == true {
                    isChangingTab = false
                    closingLastTab = false
                }
            case "control":
                if event.tab == selectedTab, let updated = event.access { access = updated }
            case "commandError":
                isChangingTab = false
                closingLastTab = false
                commandError = event.message ?? "无法更新终端标签"
            case "exit":
                if closingLastTab && (event.code ?? 0) == 0 { finishEmpty() }
                else { finish(.ended(event.code ?? 0)) }
            case "error": finish(.failed(event.message ?? "无法连接远程终端"))
            default: break
            }
        @unknown default: break
        }
    }

    private func updateTabs(_ newTabs: [Tab]) {
        guard newTabs != tabs else { return }
        tabs = newTabs
        hiddenTabs.formIntersection(newTabs.map(\.id))
    }

    private func finishEmpty() {
        updateTabs([])
        selectedTab = nil
        finish(.empty)
    }

    private func enqueue(_ request: Request) {
        guard let json = try? JSONEncoder().encode(request) else { return }
        enqueue(.string(String(decoding: json, as: UTF8.self)))
    }

    private func enqueue(_ message: URLSessionWebSocketTask.Message) {
        if case .dropped? = outgoing?.yield(message) {
            finish(.failed("终端连接拥堵，请重新接入"))
        }
    }

    private func reportSize() {
        guard state == .attached else { return }
        enqueue(Request(type: "resize", cols: dimensions.cols, rows: dimensions.rows))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard newCols > 0, newRows > 0 else { return }
        let size = (cols: min(500, newCols), rows: min(500, newRows))
        guard size != dimensions else { return }
        dimensions = size
        reportSize()
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard state == .attached, activeTab != nil, !isChangingTab else { return }
        if access?.hasControl == false {
            // Viewing uses SGR wheel reports to move this device's viewport.
            let report = String(decoding: data.prefix(32), as: UTF8.self)
            if report.hasPrefix("\u{1B}[<"), report.hasSuffix("M"),
               let separator = report.firstIndex(of: ";"),
               let button = Int(report[report.index(report.startIndex, offsetBy: 3)..<separator]) {
                switch button & ~28 {
                case 64: moveViewport(.up)
                case 65: moveViewport(.down)
                default: break
                }
            }
            return
        }
        // Keep large pastes below the server's WebSocket frame limit while preserving byte order.
        var remaining = data
        while !remaining.isEmpty, state == .attached {
            let chunk = remaining.prefix(64 * 1024)
            enqueue(.data(Data(chunk)))
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
