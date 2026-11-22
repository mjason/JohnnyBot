import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct JohnnyBotApp: App {
    @State private var terminals = RemoteTerminalWindows()

    var body: some Scene {
#if os(macOS)
        mainWindow
            .defaultSize(width: 1020, height: 680)
            .defaultLaunchBehavior(.presented)

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
        .windowIdealPlacement { _, context in
            let frame = context.defaultDisplay.visibleRect
            return WindowPlacement(frame.origin, size: frame.size)
        }
#else
        mainWindow
#endif
    }

    private var mainWindow: some Scene {
        WindowGroup("JohnnyBot", id: "main") {
            ContentView()
                .environment(terminals)
#if os(macOS)
                .background(HideTitlebarSeparator())
#endif
        }
    }
}

#if os(macOS)
private struct HideTitlebarSeparator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { TitlebarView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class TitlebarView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.titlebarSeparatorStyle = .none
        }
    }
}

private struct TerminalTitlebar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        private var mouseMonitor: Any?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if let mouseMonitor {
                NSEvent.removeMonitor(mouseMonitor)
                self.mouseMonitor = nil
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titlebarSeparatorStyle = .none
            // A transparent title bar needs a drag region above the content.
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak window] event in
                guard let window, event.window === window,
                      !window.styleMask.contains(.fullScreen),
                      event.locationInWindow.y >= window.contentLayoutRect.maxY else { return event }
                let point = window.convertPoint(toScreen: event.locationInWindow)
                for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    if let button = window.standardWindowButton(kind), let buttonWindow = button.window,
                       buttonWindow.convertToScreen(button.convert(button.bounds, to: nil)).contains(point) {
                        return event
                    }
                }

                if event.clickCount == 2 {
                    switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                    case "Minimize": window.miniaturize(nil)
                    case "None": break
                    default: window.performZoom(nil)
                    }
                } else {
                    window.performDrag(with: event)
                }
                return nil
            }
        }
    }
}
#endif
