import SwiftUI
import CodeEditorView
import LanguageSupport

private struct ProjectReference: Identifiable {
    let id = UUID()
    let path: String
    let line: Int?

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
    }
}

struct ProjectLinkPreview: ViewModifier {
    let client: ACPClient
    let session: String
    @State private var reference: ProjectReference?

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                if ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
                    return .systemAction
                }
                guard let file = ProjectReference(url) else { return .discarded }
                reference = file
                return .handled
            })
            .sheet(item: $reference) { file in
                ProjectFileSheet(file: file, client: client, session: session)
            }
    }
}

private struct ProjectFileSheet: View {
    let file: ProjectReference
    let client: ACPClient
    let session: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var source: String?
    @State private var error: String?
    @State private var position = CodeEditor.Position()

    private var language: LanguageConfiguration {
        switch (file.path as NSString).pathExtension.lowercased() {
        case "swift": .swift()
        case "py": .python()
        case "sql": .sqlite()
        case "hs": .haskell()
        case "agda": .agda()
        case "cabal": .cabal()
        case "cypher": .cypher()
        default: .none
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text((file.path as NSString).lastPathComponent).font(.headline)
                    Text(file.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
            Divider()
            if let source {
                ReadOnlyEditor(editor: CodeEditor(text: .constant(source), position: $position,
                                                  messages: .constant([]), language: language)
                    .environment(\.codeEditorTheme, colorScheme == .dark ? Theme.defaultDark : Theme.defaultLight))
            } else if let error {
                ContentUnavailableView("无法预览文件", systemImage: "doc.text", description: Text(error))
            } else {
                ProgressView("正在读取文件").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
#if os(macOS)
        .frame(minWidth: 560, idealWidth: 780, minHeight: 380, idealHeight: 540)
#endif
        .task {
            do {
                let text = try await client.readProjectFile(file.path, session: session)
                if let line = file.line, line > 1 {
                    let start = text.lineRangeStart(line)
                    position = .init(selections: [NSRange(location: start, length: 0)], verticalScrollPosition: 0)
                }
                source = text
            } catch { self.error = error.localizedDescription }
        }
    }
}

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
