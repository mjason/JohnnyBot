import SwiftUI
#if os(macOS)
import AppKit
#endif
#if os(macOS) && !DEBUG
import JohnnyBotUpdater
#endif

@main
struct JohnnyBotApp: App {
    @State private var terminals = RemoteTerminalWindows()
#if os(macOS) && !DEBUG
    private let updateCommands = AppUpdateCommands()
#endif

    var body: some Scene {
#if os(macOS)
        mainWindow
            .defaultSize(width: 1020, height: 680)
            .defaultLaunchBehavior(.presented)
#if !DEBUG
            .commands { updateCommands }
#endif

        Window("远程终端", id: "remote-terminal") {
            Group {
                if let session = terminals.current {
                    RemoteTerminalWindow(session: session).id(session.id)
                } else {
                    ContentUnavailableView("请选择远程项目", systemImage: "terminal")
                }
            }
            .onAppear { terminals.isPresented = true }
            .onDisappear { terminals.isPresented = false }
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .background(TerminalTitlebar())
        }
        .defaultSize(width: 780, height: 470)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .windowStyle(.titleBar)
        .commands { RemoteTerminalCommands() }
#else
        mainWindow
#endif
    }

    private var mainWindow: some Scene {
        WindowGroup("JohnnyBot", id: "main") {
            ContentView()
                .environment(terminals)
#if os(macOS)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .background(HideTitlebarSeparator())
#endif
        }
    }
}

#if os(macOS)
private struct HideTitlebarSeparator: NSViewRepresentable {
    func makeNSView(context: Context) -> MainWindowTitlebarView { MainWindowTitlebarView() }
    func updateNSView(_ nsView: MainWindowTitlebarView, context: Context) {}
}

final class MainWindowTitlebarView: NSView {
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window { NotificationCenter.default.removeObserver(self, name: nil, object: window) }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        applyStyle()
        for event in [NSWindow.didUpdateNotification, NSWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(applyStyle), name: event, object: window)
        }
    }

    @objc private func applyStyle() {
        guard let window, window.titlebarSeparatorStyle != .none else { return }
        window.titlebarSeparatorStyle = .none
    }
}

private struct TerminalTitlebar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        private var mouseMonitor: Any?
        private var titlebarMouseDown: NSEvent?
        private var restoreFrame: TerminalWindowRestoreFrame?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if let mouseMonitor {
                NSEvent.removeMonitor(mouseMonitor)
                self.mouseMonitor = nil
            }
            titlebarMouseDown = nil
            restoreFrame = nil
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titlebarSeparatorStyle = .none
            mouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      !window.styleMask.contains(.fullScreen) else { return event }
                return self.handleTitlebar(event, in: window)
            }
        }

        private func handleTitlebar(_ event: NSEvent, in window: NSWindow) -> NSEvent? {
            switch event.type {
            case .leftMouseDown:
                titlebarMouseDown = nil
                guard isTitlebarBackground(event, in: window) else { return event }
                if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
                if event.clickCount == 2 {
                    switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                    case "Minimize": window.miniaturize(nil)
                    case "None": break
                    default: toggleFill(in: window)
                    }
                } else {
                    titlebarMouseDown = event
                }
                return nil
            case .leftMouseDragged:
                guard let mouseDown = titlebarMouseDown else { return event }
                // Give the window server the original click once the pointer starts dragging.
                titlebarMouseDown = nil
                window.performDrag(with: mouseDown)
                return nil
            case .leftMouseUp:
                titlebarMouseDown = nil
            default:
                break
            }
            return event
        }

        private func isTitlebarBackground(_ event: NSEvent, in window: NSWindow) -> Bool {
            let point = window.convertPoint(toScreen: event.locationInWindow)
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { kind -> NSRect? in
                guard let button = window.standardWindowButton(kind), let buttonWindow = button.window else { return nil }
                return buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            }
            guard !buttons.contains(where: { $0.contains(point) }) else { return false }
            // SwiftUI can extend content under the title bar, so its layout rect alone is not a hit region.
            let titlebarHeight = buttons.first.map { (window.frame.maxY - $0.midY) * 2 } ?? 28
            return point.y >= window.frame.maxY - titlebarHeight
        }

        private func toggleFill(in window: NSWindow) {
            guard let visibleFrame = window.screen?.visibleFrame else { return }
            if let restoreFrame, restoreFrame.isFilled(window.frame, in: visibleFrame) {
                self.restoreFrame = nil
                window.setFrame(restoreFrame.restored(in: visibleFrame), display: true, animate: true)
            } else {
                restoreFrame = TerminalWindowRestoreFrame(frame: window.frame, display: visibleFrame)
                window.setFrame(visibleFrame, display: true, animate: true)
            }
        }
    }
}

struct TerminalWindowRestoreFrame {
    let frame: NSRect
    let display: NSRect

    func isFilled(_ current: NSRect, in visibleFrame: NSRect) -> Bool {
        abs(current.minX - visibleFrame.minX) <= 1 && abs(current.minY - visibleFrame.minY) <= 1
            && abs(current.maxX - visibleFrame.maxX) <= 1 && abs(current.maxY - visibleFrame.maxY) <= 1
    }

    func restored(in visibleFrame: NSRect) -> NSRect {
        let width = min(frame.width, visibleFrame.width)
        let height = min(frame.height, visibleFrame.height)
        let left = min(max(0, frame.minX - display.minX), visibleFrame.width - width)
        let top = min(max(0, display.maxY - frame.maxY), visibleFrame.height - height)
        return NSRect(x: visibleFrame.minX + left, y: visibleFrame.maxY - top - height, width: width, height: height)
    }
}
#endif
