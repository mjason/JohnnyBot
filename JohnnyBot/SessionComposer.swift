import SwiftUI

struct SessionComposer: View {
    @Binding var draft: String
    let commands: [ACPCommand]
    let isPrompting: Bool
    let isManaging: Bool
    let horizontalMargin: CGFloat
    let send: () -> Void
    let stop: () -> Void

    @FocusState private var focused: Bool
    @State private var highlighted = 0
    @State private var dismissedQuery: String?

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
            HStack(spacing: 5) {
                input
                if isPrompting {
                    Button(action: stop) { icon("stop.circle") }
                        .buttonStyle(ComposerSendStyle())
                        .accessibilityLabel("停止回复")
                        .help("停止回复")
                } else if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          ACPCommand.commandText(in: draft.trimmingCharacters(in: .whitespacesAndNewlines)) != "/" {
                    Button(action: send) { icon("arrow.up.circle") }
                        .buttonStyle(ComposerSendStyle())
                        .accessibilityLabel("发送")
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("发送消息（↩），换行（⇧↩）")
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
                            .frame(width: 34, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("斜杠命令")
                    .help("查看可用的斜杠命令")
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .frame(minHeight: 48)
            .background { ComposerSurface(focused: focused) }
        }
        .frame(maxWidth: ConversationLayout.maxContentWidth)
        .padding(.horizontal, horizontalMargin)
        .padding(.bottom, 16)
#if os(macOS)
        .onAppear { focused = true }
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

    private var input: some View {
        TextField("向 Agent 发送消息", text: $draft,
                  prompt: Text("向 Agent 发送消息").foregroundStyle(.primary.opacity(0.28)), axis: .vertical)
            .focused($focused)
            .lineLimit(1...6)
            .fixedSize(horizontal: false, vertical: true)
            .textFieldStyle(.plain)
            .font(.system(size: 14, weight: .medium))
            .padding(.vertical, 10)
#if os(macOS)
            .onKeyPress(keys: [.return, .tab, .upArrow, .downArrow, .escape], phases: .down, action: handleKey)
#else
            .submitLabel(.send)
            .onSubmit { send() }
#endif
    }

#if os(macOS)
    private func handleKey(_ key: KeyPress) -> KeyPress.Result {
        let editor = NSApp.keyWindow?.firstResponder as? NSTextView
        if editor?.hasMarkedText() == true { return .ignored }
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
#endif

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
            .frame(width: 34, height: 36)
    }
}

private struct ComposerSendStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.9 : 1)
    }
}

private struct ComposerSurface: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var scheme

    let focused: Bool

    var body: some View {
        let outline = RoundedRectangle(cornerRadius: 24, style: .continuous)
        let base = scheme == .dark ? Color(white: 0.14) : .white
        Group {
            if focused && scenePhase == .active {
                TimelineView(.animation(minimumInterval: 1 / 24, paused: reduceMotion)) { frame in
                    let drift = reduceMotion ? 0 : sin(frame.date.timeIntervalSinceReferenceDate * .pi / 22)
                    let wash = LinearGradient(stops: [
                        .init(color: Color(red: 0.53, green: 0.88, blue: 0.94), location: 0),
                        .init(color: Color(red: 1, green: 0.86, blue: 0.64), location: 0.46 + 0.12 * drift),
                        .init(color: Color(red: 0.99, green: 0.66, blue: 0.77), location: 1)
                    ], startPoint: .leading, endPoint: .trailing)
                    ZStack {
                        outline.stroke(wash, lineWidth: 6 + drift).blur(radius: 7)
                        outline.fill(base)
                        outline.fill(wash.opacity(scheme == .dark ? 0.15 : 0.25))
                        outline.fill(LinearGradient(colors: [.clear, .purple.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                        outline.strokeBorder(.white.opacity(scheme == .dark ? 0.55 : 0.96), lineWidth: 1.5)
                    }
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
