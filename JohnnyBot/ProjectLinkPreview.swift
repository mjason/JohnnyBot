import SwiftUI
import CodeEditorView
import LanguageSupport
import SwiftStreamingMarkdown

private struct ProjectReference: Identifiable {
    let id = UUID()
    let path: String
    let line: Int?
    let workspace: String?

    init(path: String, workspace: String) {
        self.path = path
        self.workspace = workspace
        line = nil
    }

    init?(_ url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.host == nil || (url.isFileURL && ["", "localhost"].contains(parts.host ?? "")),
              parts.query == nil else { return nil }
        // Foundation interprets a bare filename followed by ":42" as a URL scheme.
        var path = parts.path
        if let scheme = parts.scheme, scheme.lowercased() != "file" {
            guard scheme.contains("."), Int(path) != nil else { return nil }
            path = scheme + ":" + path
        }
        var line = parts.fragment.flatMap { value in
            value.hasPrefix("L") ? Int(value.dropFirst().prefix(while: \.isNumber)) : nil
        }
        if let colon = path.lastIndex(of: ":"), let number = Int(path[path.index(after: colon)...]) {
            path = String(path[..<colon])
            line = number
        }
        guard !path.isEmpty else { return nil }
        self.path = path
        self.line = line
        workspace = nil
    }
}

struct ProjectLinkPreview: ViewModifier {
    let client: ACPClient
    let session: String?
    @State private var choosingPath = false
    @State private var workspace = ""
    @State private var path = ""
#if !os(macOS)
    @State private var reference: ProjectReference?
#endif

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                if ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
                    return .systemAction
                }
                guard let file = ProjectReference(url) else { return .discarded }
                open(file)
                return .handled
            })
            .toolbar {
                if client.connected, !client.workspaceIDs.isEmpty {
                    ToolbarItem {
                        Menu {
                            ForEach(client.workspaceIDs, id: \.self) { id in
                                Button(id) {
                                    workspace = id
                                    path = ""
                                    choosingPath = true
                                }
                            }
                        } label: {
                            Label("打开远程文件", systemImage: "doc.text.magnifyingglass")
                        }
                        .help("打开远程文件")
                    }
                }
            }
            .alert("打开远程文件", isPresented: $choosingPath) {
                TextField("文件路径", text: $path)
                Button("打开") {
                    open(ProjectReference(path: path.trimmingCharacters(in: .whitespacesAndNewlines), workspace: workspace))
                }
                .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
                Button("取消", role: .cancel) {}
            } message: {
                Text("输入绝对路径，或相对于工作区「\(workspace)」的文件路径。")
            }
#if !os(macOS)
            .sheet(item: $reference) { file in
                ProjectFilePreview(file: file, client: client, session: session)
            }
#endif
    }

    private func open(_ file: ProjectReference) {
#if os(macOS)
        ProjectFileWindow.open(file, client: client, session: session)
#else
        reference = file
#endif
    }
}

#if os(macOS)
@MainActor
private final class ProjectFileWindow: NSWindowController, NSWindowDelegate {
    private static var openWindows: [UUID: ProjectFileWindow] = [:]
    private let id = UUID()

    static func open(_ file: ProjectReference, client: ACPClient, session: String?) {
        let preview = ProjectFilePreview(file: file, client: client, session: session)
            .background(ResizableWindowTitlebar())
        let window = NSWindow(contentViewController: NSHostingController(rootView: preview))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.title = (file.path as NSString).lastPathComponent
        window.subtitle = file.path
        window.setContentSize(NSSize(width: 780, height: 540))
        window.center()
        let controller = ProjectFileWindow(window: window)
        openWindows[controller.id] = controller
        window.delegate = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        Self.openWindows.removeValue(forKey: id)
    }
}
#endif

private struct ProjectFilePreview: View {
    let file: ProjectReference
    let client: ACPClient
    let session: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var source: String?
    @State private var error: String?
    @State private var position = CodeEditor.Position()

    private var language: LanguageConfiguration? {
        switch previewHighlightLanguage(for: file.path) {
        case "swift": .swift()
        case "python": .python()
        case "sql": .sqlite()
        case "hs": .haskell()
        case "agda": .agda()
        case "cabal": .cabal()
        case "cypher": .cypher()
        default: nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
#if !os(macOS)
            HStack {
                VStack(alignment: .leading) {
                    Text((file.path as NSString).lastPathComponent).font(.headline)
                    Text(file.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
            Divider()
#endif
            if let source {
                if let language {
                    ReadOnlyEditor(editor: CodeEditor(text: .constant(source), position: $position,
                                                      messages: .constant([]), language: language)
                        .environment(\.codeEditorTheme, colorScheme == .dark ? Theme.defaultDark : Theme.defaultLight))
                } else {
                    HighlightedFile(source: source, path: file.path, line: file.line)
                }
            } else if let error {
                ContentUnavailableView("无法预览文件", systemImage: "doc.text", description: Text(error))
            } else {
                ProgressView("正在读取文件").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
#if os(macOS)
        .frame(minWidth: 560, maxWidth: .infinity, minHeight: 380, maxHeight: .infinity)
#endif
        .task {
            do {
                let text = try await client.readProjectFile(file.path, session: session, workspace: file.workspace)
                if let line = file.line, line > 1 {
                    let start = text.lineRangeStart(line)
                    position = .init(selections: [NSRange(location: start, length: 0)], verticalScrollPosition: 0)
                }
                source = text
            } catch { self.error = error.localizedDescription }
        }
    }
}

func previewHighlightLanguage(for path: String) -> String {
    let filename = (path as NSString).lastPathComponent.lowercased()
    switch filename {
    case "dockerfile", "containerfile": return "dockerfile"
    case "makefile", "gnumakefile": return "makefile"
    case ".bashrc", ".zshrc", ".zprofile", ".profile": return "bash"
    case ".editorconfig", ".gitconfig", ".gitmodules": return "ini"
    case ".prettierrc", ".eslintrc", ".babelrc": return "yaml"
    default: break
    }

    let ext = (filename as NSString).pathExtension
    switch ext {
    case "py", "pyi", "pyw": return "python"
    case "toml", "ini", "cfg": return "ini" // Highlight.js shares a grammar for TOML and INI.
    case "json", "jsonc", "jsonl", "ndjson", "ipynb": return "json"
    case "yaml", "yml": return "yaml"
    case "rs": return "rust"
    case "ts", "tsx", "mts", "cts": return "typescript"
    case "js", "jsx", "mjs", "cjs": return "javascript"
    case "sh", "bash", "zsh": return "bash"
    case "h", "hpp", "cc", "cxx": return "cpp"
    case "m", "mm": return "objectivec"
    case "html", "htm", "xml", "svg", "plist", "vue", "svelte": return "xml"
    case "md", "markdown": return "markdown"
    case "proto": return "protobuf"
    default: return ext
    }
}

private struct HighlightedFile: View {
    let source: String
    let path: String
    let line: Int?
    @Environment(\.colorScheme) private var colorScheme
    @State private var highlighted: AttributedString?

    var body: some View {
        HighlightedFileText(text: highlighted ?? AttributedString(source), line: line)
            .task(id: colorScheme) {
                let alias = previewHighlightLanguage(for: path)
                guard !alias.isEmpty, source.utf8.count <= 512 * 1024,
                      !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                let result = try? await highlightSource(source, language: alias, colorScheme: colorScheme)
                if !Task.isCancelled { highlighted = result }
            }
    }
}

#if os(macOS)
private struct HighlightedFileText: NSViewRepresentable {
    let text: AttributedString
    let line: Int?

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.textContainerInset = NSSize(width: 12, height: 12)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let firstLoad = view.textStorage?.length == 0
        let content = NSMutableAttributedString(attributedString: NSAttributedString(text))
        content.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                             range: NSRange(location: 0, length: content.length))
        guard let storage = view.textStorage, !storage.isEqual(to: content) else { return }
        storage.setAttributedString(content)
        if firstLoad, let line, line > 1 {
            let range = NSRange(location: content.string.lineRangeStart(line), length: 0)
            view.setSelectedRange(range)
            DispatchQueue.main.async { view.scrollRangeToVisible(range) }
        }
    }
}
#else
private struct HighlightedFileText: UIViewRepresentable {
    let text: AttributedString
    let line: Int?

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let firstLoad = view.textStorage.length == 0
        let content = NSMutableAttributedString(attributedString: NSAttributedString(text))
        content.addAttribute(.font, value: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                             range: NSRange(location: 0, length: content.length))
        guard !view.textStorage.isEqual(to: content) else { return }
        view.textStorage.setAttributedString(content)
        if firstLoad, let line, line > 1 {
            let range = NSRange(location: content.string.lineRangeStart(line), length: 0)
            view.selectedRange = range
            DispatchQueue.main.async { view.scrollRangeToVisible(range) }
        }
    }
}
#endif

private extension String {
    func lineRangeStart(_ line: Int) -> Int {
        let string = self as NSString
        var offset = 0
        for _ in 1..<line {
            guard offset < string.length else { break }
            offset = NSMaxRange(string.lineRange(for: NSRange(location: offset, length: 0)))
        }
        return offset
    }
}

// Scope native text view configuration to this editor, keeping selection and scrolling active.
#if os(macOS)
private struct ReadOnlyEditor<Editor: View>: NSViewRepresentable {
    let editor: Editor
    final class Host: NSHostingView<Editor> {
        override func layout() {
            super.layout()
            lockText(in: self)
        }
        private func lockText(in view: NSView) {
            if let text = view as? NSTextView { text.isEditable = false }
            else { view.subviews.forEach { lockText(in: $0) } }
        }
    }
    func makeNSView(context: Context) -> Host { Host(rootView: editor) }
    func updateNSView(_ host: Host, context: Context) { host.rootView = editor }
}
#else
private struct ReadOnlyEditor<Editor: View>: UIViewControllerRepresentable {
    let editor: Editor
    final class Host: UIHostingController<Editor> {
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            lockText(in: view)
        }
        private func lockText(in view: UIView) {
            if let text = view as? UITextView { text.isEditable = false }
            else { view.subviews.forEach { lockText(in: $0) } }
        }
    }
    func makeUIViewController(context: Context) -> Host { Host(rootView: editor) }
    func updateUIViewController(_ host: Host, context: Context) { host.rootView = editor }
}
#endif
