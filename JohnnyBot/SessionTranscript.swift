import SwiftUI
import SwiftStreamingMarkdown
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum ConversationLayout {
    static let maxContentWidth: CGFloat = 680
    static let horizontalMargin: CGFloat = 20
    static let settingsGutter: CGFloat = 34
#if os(macOS)
    static let composerSpacing: CGFloat = 24
    fileprivate static let transcriptTextSize: CGFloat = 14
#else
    static let composerSpacing: CGFloat = 18
    fileprivate static let transcriptTextSize: CGFloat = 16
#endif
}

struct SessionTranscript: View {
    let entries: [ACPEntry]
    let isResponding: Bool
    let permissions: [ACPPermission]
    let horizontalMargin: CGFloat
    let composerSpacing: CGFloat
    let respondToPermission: (ACPPermission, String?) -> Void

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var showsJumpToLatest = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            messages
            if !permissions.isEmpty {
                TranscriptPermissions(
                    permissions: permissions, horizontalMargin: horizontalMargin, respond: respondToPermission
                )
            }
        }
        .padding(.bottom, composerSpacing)
        .overlay(alignment: .bottom) {
            if showsJumpToLatest {
                jumpButton
                    .padding(.bottom, 10)
            }
        }
    }

    private var messages: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(entries) { entry in
                    TranscriptEntryRow(entry: entry, isStreaming: isResponding && entry.id == entries.last?.id)
                }
                if isResponding, entries.last?.kind == .user {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("等待 Agent 回复").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: ConversationLayout.maxContentWidth)
            .padding(.horizontal, horizontalMargin)
            .padding(.top, 20)
            .padding(.bottom, max(8, composerSpacing))
            .frame(maxWidth: .infinity)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.height > geometry.visibleRect.maxY + 90
        } action: { _, awayFromBottom in
            showsJumpToLatest = awayFromBottom
        }
        .scrollEdgeEffectHidden(true, for: .bottom)
#if os(macOS)
        .scrollEdgeEffectHidden(true, for: .top)
#endif
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("开始对话", systemImage: "text.bubble",
                                       description: Text("向 Agent 发送一条消息。"))
                    .allowsHitTesting(false)
            }
        }
    }

    private var jumpButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                position.scrollTo(edge: .bottom)
            }
        } label: {
            Label("回到最新消息", systemImage: "arrow.down")
                .labelStyle(.iconOnly)
                .font(.system(.callout, weight: .semibold))
                .frame(width: 34, height: 34)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .help("回到最新消息")
    }
}

private struct TranscriptEntryRow: View {
    let entry: ACPEntry
    let isStreaming: Bool

    @ScaledMetric(relativeTo: .body) private var textSize = ConversationLayout.transcriptTextSize

    var body: some View {
        switch entry.kind {
        case .user:
            userMessage
        case .agent:
            VStack(alignment: .leading, spacing: 7) {
                Label("Agent", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TranscriptMarkdown(text: entry.text, isStreaming: isStreaming)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .thought:
            if !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DisclosureGroup {
                    TranscriptMarkdown(text: entry.text, isStreaming: isStreaming)
                        .padding(.top, 5)
                } label: {
                    Label("思考过程", systemImage: "text.alignleft")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .modifier(TranscriptPanel())
            }
        case .tool:
            toolRow
        case .plan:
            if !entry.planSteps.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Label("计划", systemImage: "list.bullet.clipboard")
                        .font(.callout.weight(.semibold))
                    ForEach(Array(entry.planSteps.enumerated()), id: \.offset) { _, step in
                        Label(step.content, systemImage: TranscriptStatus(step.status).symbol)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .accessibilityValue(TranscriptStatus(step.status).label)
                    }
                }
                .modifier(TranscriptPanel())
            }
        case .status:
            Label(TranscriptStatus(entry.text).label, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var userMessage: some View {
        let bubble = RoundedRectangle(cornerRadius: 15)
        return HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 44)
            Text(entry.text)
                .font(.system(size: textSize))
                .lineSpacing(3)
                .textSelection(.enabled)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(.primary.opacity(0.045), in: bubble)
                .overlay { bubble.strokeBorder(.primary.opacity(0.075)).allowsHitTesting(false) }
                .accessibilityLabel("你：\(entry.text)")
                .frame(maxWidth: 470, alignment: .trailing)
        }
    }

    @ViewBuilder private var toolRow: some View {
        if entry.toolContent.isEmpty {
            toolLabel
                .modifier(TranscriptPanel())
        } else {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(entry.toolContent.enumerated()), id: \.offset) { _, content in
                        switch content {
                        case let .text(text):
                            output(text)
                        case let .diff(path, oldText, newText):
                            VStack(alignment: .leading, spacing: 6) {
                                Label(path, systemImage: "doc.text")
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                if let oldText {
                                    DisclosureGroup("修改前") { output(oldText) }
                                }
                                if let newText {
                                    DisclosureGroup("修改后") { output(newText) }
                                }
                            }
                        case let .terminal(id):
                            Label("终端 \(id)", systemImage: "terminal")
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                toolLabel
            }
            .modifier(TranscriptPanel())
        }
    }

    private var toolLabel: some View {
        HStack(spacing: 8) {
            Label(entry.text, systemImage: toolSymbol)
                .font(.callout.weight(.medium))
                .lineLimit(2)
            Spacer(minLength: 8)
            if let status = entry.toolStatus {
                let presentation = TranscriptStatus(status)
                Label(presentation.label, systemImage: presentation.symbol)
                    .font(.caption)
                    .foregroundStyle(presentation.tint)
            }
        }
    }

    private var toolSymbol: String {
        switch entry.toolKind {
        case "read": "doc.text"
        case "edit": "square.and.pencil"
        case "search": "magnifyingglass"
        case "execute": "terminal"
        case "fetch": "network"
        default: "wrench"
        }
    }

    private func output(_ text: String) -> some View {
        Text(text)
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct TranscriptMarkdown: View {
    let text: String
    let isStreaming: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var textSize = ConversationLayout.transcriptTextSize

    private static let defaultConfig = makeConfig(textSize: ConversationLayout.transcriptTextSize)

    var body: some View {
        let base = textSize == ConversationLayout.transcriptTextSize ? Self.defaultConfig : Self.makeConfig(textSize: textSize)
        Group {
            if isStreaming {
                LiveTranscriptMarkdown(text: text, config: base.withShouldAnimateText(value: !reduceMotion))
            } else {
                MarkdownView(text: text, config: base)
            }
        }
        .id(textSize)
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            guard let scheme = url.scheme?.lowercased(),
                  ["https", "http"].contains(scheme), url.host != nil else { return .discarded }
            return .systemAction
        })
    }

    private static func makeConfig(textSize: CGFloat) -> MarkdownRenderConfig {
        let body = fonts(size: textSize)
        let small = fonts(size: textSize * 0.9)
        let subheading = fonts(size: textSize * 1.08, weight: .semibold)
        let code = MDFont.monospacedSystemFont(ofSize: textSize * 0.9, weight: .regular)
        let surface = Color.primary.opacity(0.045)
        let border = Color.primary.opacity(0.10)

        return MarkdownRenderConfig(
            blockQuoteStyle: .init(textFonts: body, textColor: .secondary),
            headingStyle: .init(
                h1Font: fonts(size: textSize * 1.5, weight: .semibold),
                h2Font: fonts(size: textSize * 1.28, weight: .semibold),
                h3Font: subheading, h4Font: subheading, h5Font: subheading, h6Font: subheading,
                textColor: .primary
            ),
            orderedListStyle: .init(textFonts: body, textColor: .secondary),
            paragraphStyle: .init(textFonts: body, textColor: .primary),
            tableStyle: .init(
                textFonts: small, headerTextColor: .primary, regularTextColor: .primary,
                headerBackgroundColor: surface, borderColor: border, actionButtonColor: .secondary
            ),
            inlineStyle: .init(
                boldTextColor: .primary, linkTextFont: body.normal, linkTextColor: .accentColor,
                linkUnderlineStyle: .single, codeTextFont: code, codeTextColor: .primary,
                codeBackgroundColor: surface, codeUnderlineColor: .clear
            ),
            codeBlockConfig: .init(
                theme: .xcode, backgroundColor: surface, foregroundColor: .secondary,
                codeTextFonts: .init(normal: code, italic: nil, bold: nil, boldItalic: nil,
                                     preferredLetterSpacing: nil, preferredLineHeight: nil),
                chromeTextFonts: small
            ),
            blockSpacing: 12,
            thematicBreakColor: border
        )
    }

    private static func fonts(size: CGFloat, weight: MDFont.Weight = .regular) -> TextFonts {
        let normal = MDFont.systemFont(ofSize: size, weight: weight)
        let bold = MDFont.systemFont(ofSize: size, weight: .bold)
        return TextFonts(normal: normal, italic: italic(normal), bold: bold, boldItalic: italic(bold),
                         preferredLetterSpacing: nil, preferredLineHeight: nil)
    }

    private static func italic(_ font: MDFont) -> MDFont {
#if os(macOS)
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
#else
        let traits = font.fontDescriptor.symbolicTraits.union(.traitItalic)
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
#endif
    }
}

private struct LiveTranscriptMarkdown: View {
    let text: String
    let config: MarkdownRenderConfig

    @State private var source: TranscriptMarkdownSource?

    var body: some View {
        Group {
            if let source {
                StreamedMarkdownView(source: source, config: config)
            }
        }
        .onAppear { source = TranscriptMarkdownSource(text) }
        .onChange(of: text) { _, value in source?.continuation.yield(value) }
        .onDisappear {
            source?.continuation.finish()
            source = nil
        }
    }
}

private nonisolated struct TranscriptMarkdownSource: StreamedMarkdownSource {
    let text: AsyncStream<String>
    let continuation: AsyncStream<String>.Continuation

    init(_ initialText: String) {
        (text, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(1))
        continuation.yield(initialText)
    }
}

private struct TranscriptPermissions: View {
    let permissions: [ACPPermission]
    let horizontalMargin: CGFloat
    let respond: (ACPPermission, String?) -> Void

    var body: some View {
        ViewThatFits(in: .vertical) {
            cards.fixedSize(horizontal: false, vertical: true)
            ScrollView { cards }
                .defaultScrollAnchor(.top)
        }
        .frame(maxHeight: 200)
    }

    private var cards: some View {
        VStack(spacing: 8) {
            ForEach(permissions) { permission in
                TranscriptPermissionCard(permission: permission) { option in
                    respond(permission, option)
                }
            }
        }
        .frame(maxWidth: ConversationLayout.maxContentWidth)
        .padding(.horizontal, horizontalMargin)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }
}

private struct TranscriptPermissionCard: View {
    let permission: ACPPermission
    let respond: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("审批请求", systemImage: "lock.shield")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                Spacer()
                Menu("审批选项") {
                    ForEach(permission.options) { option in
                        Button(option.name) { respond(option.id) }
                    }
                    Button("取消请求") { respond(nil) }
                }
            }
            Text(permission.title).font(.callout).textSelection(.enabled)
            if let details = permission.details, !details.isEmpty {
                DisclosureGroup("工具参数") {
                    ScrollView {
                        Text(details)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 110)
                }
                .font(.caption)
            }
        }
        .modifier(TranscriptPanel())
    }
}

private struct TranscriptPanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct TranscriptStatus {
    let value: String

    init(_ value: String) { self.value = value }

    var label: String {
        switch value {
        case "pending": "等待中"
        case "in_progress": "进行中"
        case "completed": "已完成"
        case "failed": "失败"
        case "cancelled", "canceled": "已取消"
        case "max_tokens": "已达到回复长度上限"
        case "max_turn_requests": "已达到本轮请求上限"
        case "refusal": "Agent 拒绝了此次请求"
        default: value
        }
    }

    var symbol: String {
        switch value {
        case "completed": "checkmark.circle"
        case "failed": "exclamationmark.circle"
        case "in_progress": "circle.dotted"
        case "cancelled", "canceled": "xmark.circle"
        default: "circle"
        }
    }

    var tint: Color {
        switch value {
        case "completed": .green
        case "failed": .red
        case "in_progress": .accentColor
        default: .secondary
        }
    }
}
