import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

struct SessionComposer: View {
    @Binding var draft: String
    let attachments: [ACPAttachment]
    let supportsImages: Bool
    let supportsFiles: Bool
    let commands: [ACPCommand]
    let isPrompting: Bool
    let isManaging: Bool
    let horizontalMargin: CGFloat
    let send: () -> Void
    let stop: () -> Void
    let addAttachments: ([ACPAttachment]) -> Void
    let removeAttachment: (UUID) -> Void
    let attachmentFailed: (Error) -> Void

    @FocusState private var focused: Bool
    @State private var highlighted = 0
    @State private var dismissedQuery: String?
    @State private var choosingFiles = false
    @State private var targetingDrop = false
#if os(iOS)
    @State private var choosingPhoto = false
    @State private var photo: PhotosPickerItem?
#endif

#if os(iOS)
    private let actionSize = CGSize(width: 44, height: 44)
    private let attachmentSize = CGSize(width: 44, height: 44)
    private let bottomInset: CGFloat = 6
#else
    private let actionSize = CGSize(width: 34, height: 36)
    private let attachmentSize = CGSize(width: 30, height: 32)
    private let bottomInset: CGFloat = 16
#endif

    private var canAttach: Bool { supportsImages || supportsFiles }

    private var canSend: Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return (!text.isEmpty || !attachments.isEmpty) && ACPCommand.commandText(in: text) != "/"
    }

    private var commandQuery: String? {
        guard focused, draft != dismissedQuery, let query = ACPCommand.commandText(in: draft),
              !query.contains(where: \.isWhitespace) else { return nil }
        return query
    }

    private var matches: [ACPCommand] {
        guard let commandQuery else { return [] }
        return ACPCommand.matches(for: commandQuery, commands: commands)
    }

    private var argumentHint: String? {
        guard focused, draft.last?.isWhitespace == true,
              let command = ACPCommand.commandText(in: draft) else { return nil }
        let invocation = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return commands.first { $0.invocation.lowercased() == invocation }?.input?.hint
    }

    var body: some View {
        VStack(spacing: 8) {
            if commandQuery != nil {
                if matches.isEmpty {
                    Text(commands.isEmpty ? "Agent 暂未提供命令" : "没有匹配的命令")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                } else {
                    commandList
                }
            } else if let hint = argumentHint, !hint.isEmpty {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 16)
            }
            VStack(alignment: .leading, spacing: 0) {
                if !attachments.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(attachments) { attachment in
                                AttachmentBadge(preview: attachment.preview) { removeAttachment(attachment.id) }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .scrollIndicators(.hidden)
                    .padding(.top, 9)
                    .padding(.horizontal, 11)
                }
                composerRow
            }
            .background { ComposerSurface(focused: focused) }
            .overlay {
                if targetingDrop {
                    RoundedRectangle(cornerRadius: 24).strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL, .image], isTargeted: $targetingDrop) { providers in
                guard canAttach else { return false }
                addProviders(providers)
                return true
            }
        }
        .frame(maxWidth: ConversationLayout.maxContentWidth)
        .padding(.horizontal, horizontalMargin)
        .padding(.bottom, bottomInset)
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: supportsFiles ? [.item] : [.image],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importFiles(urls)
            case .failure(let error): attachmentFailed(error)
            }
        }
#if os(macOS)
        .onAppear { focused = true }
#else
        .photosPicker(isPresented: $choosingPhoto, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw AttachmentError.invalidImage }
                    importImage(data, name: "照片")
                } catch { attachmentFailed(error) }
            }
        }
#endif
        .onChange(of: draft) { _, newValue in
            highlighted = 0
            if newValue != dismissedQuery { dismissedQuery = nil }
        }
        .onChange(of: matches.map(\.id)) { _, ids in
            highlighted = min(highlighted, max(0, ids.count - 1))
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { dismissedQuery = nil }
        }
    }

    private var composerRow: some View {
        HStack(spacing: 5) {
            if canAttach { attachmentMenu }
            input
            if isPrompting {
                Button(action: stop) { icon("stop.circle") }
                    .buttonStyle(ComposerSendStyle())
                    .accessibilityLabel("停止回复")
                    .help("停止回复")
            } else if canSend {
                Button(action: send) { icon("arrow.up.circle") }
                    .buttonStyle(ComposerSendStyle())
                    .accessibilityLabel("发送")
                    .keyboardShortcut(.return, modifiers: .command)
#if os(iOS)
                    .help("发送消息")
#else
                    .help("发送消息（↩），换行（⇧↩）")
#endif
                    .disabled(isManaging)
            } else {
                Button {
                    dismissedQuery = nil
                    draft = "/"
                    focused = true
                } label: {
                    Text("/")
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: actionSize.width, height: actionSize.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("斜杠命令")
                .help("查看可用的斜杠命令")
            }
        }
        .padding(.leading, canAttach ? 8 : 16)
        .padding(.trailing, 8)
        .frame(minHeight: 48)
    }

    private var attachmentMenu: some View {
        Menu {
            Button { choosingFiles = true } label: {
                Label(supportsFiles ? "添加文件…" : "添加图片…", systemImage: "paperclip")
            }
            if supportsImages {
#if os(macOS)
                Button {
                    ComposerScreenshot.shared.take { result in
                        switch result {
                        case .success(let attachment):
                            if let attachment { addAttachments([attachment]) }
                        case .failure(let error): attachmentFailed(error)
                        }
                    }
                } label: { Label("截取窗口或屏幕…", systemImage: "camera.viewfinder") }
#else
                Button { choosingPhoto = true } label: { Label("从照片添加…", systemImage: "photo") }
#endif
            }
#if os(macOS)
            Button { _ = pasteAttachment() } label: {
                Label("粘贴附件", systemImage: "document.on.clipboard")
            }
#endif
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: attachmentSize.width, height: attachmentSize.height)
                .contentShape(Rectangle())
        }
#if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 30)
#endif
        .accessibilityLabel("添加附件")
        .help("添加截图、图片或文件")
    }

    private var input: some View {
#if os(iOS)
        let prompt = Text("向 Agent 发送消息").foregroundStyle(.secondary)
#else
        let prompt = Text("向 Agent 发送消息").foregroundStyle(.primary.opacity(0.28))
#endif
        return TextField("向 Agent 发送消息", text: $draft, prompt: prompt, axis: .vertical)
            .focused($focused)
            .lineLimit(1...6)
            .fixedSize(horizontal: false, vertical: true)
            .textFieldStyle(.plain)
#if os(iOS)
            .font(.body)
            .accessibilityLabel("消息输入框")
#else
            .font(.system(size: 14, weight: .medium))
#endif
            .padding(.vertical, 10)
#if os(macOS)
            .onKeyPress(keys: [.return, .tab, .upArrow, .downArrow, .escape, "v"], phases: .down, action: handleKey)
#elseif !os(iOS)
            .submitLabel(.send)
            .onSubmit { send() }
#endif
    }

#if os(macOS)
    private func handleKey(_ key: KeyPress) -> KeyPress.Result {
        let editor = NSApp.keyWindow?.firstResponder as? NSTextView
        if editor?.hasMarkedText() == true { return .ignored }
        if key.key == "v", key.modifiers == .command, pasteAttachment() { return .handled }
        if key.key == .return, key.modifiers == .shift, let editor {
            editor.insertText("\n", replacementRange: editor.selectedRange())
            return .handled
        }
        guard key.modifiers.isEmpty else { return .ignored }
        let choices = matches
        if choices.indices.contains(highlighted) {
            switch key.key {
            case .downArrow:
                highlighted = min(highlighted + 1, choices.count - 1)
            case .upArrow:
                highlighted = max(0, highlighted - 1)
            case .return, .tab:
                complete(choices[highlighted])
            case .escape:
                dismissedQuery = draft
            default:
                return .ignored
            }
            return .handled
        }
        if key.key == .escape, commandQuery != nil {
            dismissedQuery = draft
            return .handled
        }
        guard key.key == .return else { return .ignored }
        if commandQuery != "/" { send() }
        return .handled
    }

    private func pasteAttachment() -> Bool {
        guard canAttach else { return false }
        let pasteboard = NSPasteboard.general
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            importFiles(urls)
            return true
        }
        guard let type = pasteboard.availableType(from: [.png, .tiff]), let data = pasteboard.data(forType: type) else { return false }
        importImage(data, name: "粘贴的图片")
        return true
    }
#endif

    private func importFiles(_ urls: [URL]) {
        Task {
            for url in urls {
                do {
                    let attachment = try await Task.detached { try ACPAttachment.file(at: url) }.value
                    addAttachments([attachment])
                } catch { attachmentFailed(error) }
            }
        }
    }

    private func importImage(_ data: Data, name: String) {
        guard supportsImages else { attachmentFailed(AttachmentError.unsupportedImage); return }
        Task {
            do {
                let attachment = try await Task.detached { try ACPAttachment.image(data, name: name) }.value
                addAttachments([attachment])
            } catch { attachmentFailed(error) }
        }
    }

    private func addProviders(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
                    let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    Task { @MainActor in
                        if let url, url.isFileURL { importFiles([url]) }
                        else { attachmentFailed(error ?? AttachmentError.fileRequired) }
                    }
                }
            } else if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
                let name = provider.suggestedName ?? "图片"
                provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                    Task { @MainActor in
                        if let data { importImage(data, name: name) }
                        else { attachmentFailed(error ?? AttachmentError.invalidImage) }
                    }
                }
            }
        }
    }

    private var commandList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, command in
                        Button { complete(command) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(command.invocation).font(.callout.monospaced().weight(.medium))
                                Text(command.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                            .background(index == highlighted ? Color.accentColor.opacity(0.14) : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .id(command.id)
                    }
                }
                .padding(5)
            }
            .defaultScrollAnchor(.top)
            .frame(idealHeight: CGFloat(min(matches.count, 5) * 46 + 10), maxHeight: CGFloat(min(matches.count, 5) * 46 + 10))
            .onChange(of: highlighted) {
                if matches.indices.contains(highlighted) { proxy.scrollTo(matches[highlighted].id) }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary).allowsHitTesting(false) }
    }

    private func complete(_ command: ACPCommand) {
        let completion = command.invocation + (command.input == nil ? "" : " ")
        draft = completion
        dismissedQuery = completion
        focused = true
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 21, weight: .medium))
            .foregroundStyle(LinearGradient(
                colors: [
                    Color(red: 0.27, green: 0.60, blue: 0.66),
                    Color(red: 0.74, green: 0.53, blue: 0.34),
                    Color(red: 0.80, green: 0.47, blue: 0.56)
                ], startPoint: .leading, endPoint: .trailing))
            .frame(width: actionSize.width, height: actionSize.height)
            .contentShape(Rectangle())
    }
}

private struct ComposerSendStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.9 : 1)
    }
}

private struct ComposerSurface: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var scheme

    let focused: Bool

    var body: some View {
        let outline = RoundedRectangle(cornerRadius: 24, style: .continuous)
        let base = scheme == .dark ? Color(white: 0.14) : .white
        Group {
            if focused && scenePhase == .active {
                let wash = LinearGradient(stops: [
                    .init(color: Color(red: 0.53, green: 0.88, blue: 0.94), location: 0),
                    .init(color: Color(red: 1, green: 0.86, blue: 0.64), location: 0.46),
                    .init(color: Color(red: 0.99, green: 0.66, blue: 0.77), location: 1)
                ], startPoint: .leading, endPoint: .trailing)
                ZStack {
                    outline.stroke(wash, lineWidth: 6).blur(radius: 7)
                    outline.fill(base)
                    outline.fill(wash.opacity(scheme == .dark ? 0.15 : 0.25))
                    outline.fill(LinearGradient(colors: [.clear, .purple.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                    outline.strokeBorder(.white.opacity(scheme == .dark ? 0.55 : 0.96), lineWidth: 1.5)
                }
            } else {
                outline.fill(base)
                    .overlay { outline.strokeBorder(.secondary.opacity(0.25), lineWidth: 1) }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
