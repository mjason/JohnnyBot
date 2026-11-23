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
    private let turns: [TranscriptTurn]
    let isResponding: Bool
    let permissions: [ACPPermission]
    let horizontalMargin: CGFloat
    let composerSpacing: CGFloat
    let respondToPermission: (ACPPermission, String?) -> Void

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var showsJumpToLatest = false
    @State private var markdownCache = TranscriptMarkdownCache()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(entries: [ACPEntry], isResponding: Bool, permissions: [ACPPermission], horizontalMargin: CGFloat,
         composerSpacing: CGFloat, respondToPermission: @escaping (ACPPermission, String?) -> Void) {
        turns = TranscriptTurn.group(entries)
        self.isResponding = isResponding
        self.permissions = permissions
        self.horizontalMargin = horizontalMargin
        self.composerSpacing = composerSpacing
        self.respondToPermission = respondToPermission
    }

    var body: some View {
        VStack(spacing: 0) {
            messages
            if !permissions.isEmpty {
                TranscriptPermissions(
                    permissions: permissions, horizontalMargin: horizontalMargin, respond: respondToPermission
                )
                .padding(.bottom, composerSpacing)
            }
        }
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
                ForEach(turns) { turn in
                    TranscriptTurnRow(
                        turn: turn, isLive: isResponding && turn.id == turns.last?.id,
                        isAwaitingPermission: !permissions.isEmpty
                    )
                }
            }
            .frame(maxWidth: ConversationLayout.maxContentWidth)
            .padding(.horizontal, horizontalMargin)
            .padding(.top, 20)
            .padding(.bottom, max(8, composerSpacing))
            .frame(maxWidth: .infinity)
        }
        .environment(\.transcriptMarkdownCache, markdownCache)
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .onChange(of: turns.count) { previousCount, count in
            if count > previousCount, turns.last?.user != nil {
                position.scrollTo(edge: .bottom)
            }
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.height > geometry.visibleRect.maxY + 90
        } action: { _, awayFromBottom in
            showsJumpToLatest = awayFromBottom
        }
#if os(macOS)
        .scrollEdgeEffectHidden(true, for: .top)
#endif
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .safeAreaBar(edge: .bottom, spacing: 0) {
            if permissions.isEmpty {
                Color.clear
                    .frame(height: composerSpacing)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay {
            if turns.isEmpty, !isResponding {
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

struct TranscriptTurn: Identifiable {
    let id: UUID
    let user: ACPEntry?
    let entries: ArraySlice<ACPEntry>
    let replyTiming: ACPReplyTiming?
    let responseStart: Int

    private init?(user: ACPEntry?, entries: ArraySlice<ACPEntry>) {
        guard let id = user?.id ?? entries.first?.id else { return nil }
        self.id = id
        self.user = user
        self.entries = entries
        replyTiming = entries.reversed().lazy.compactMap(\.replyTiming).first ?? user?.replyTiming
        responseStart = Self.startOfResponse(in: entries)
    }

    static func group(_ entries: [ACPEntry]) -> [Self] {
        var turns: [Self] = []
        var user: ACPEntry?
        var start = entries.startIndex

        for index in entries.indices where entries[index].kind == .user {
            if let turn = Self(user: user, entries: entries[start..<index]) { turns.append(turn) }
            user = entries[index]
            start = index + 1
        }
        if let turn = Self(user: user, entries: entries[start...]) { turns.append(turn) }
        return turns
    }

    private static func startOfResponse(in entries: ArraySlice<ACPEntry>) -> Int {
        guard let lastWork = entries.lastIndex(where: {
            $0.kind == .tool || $0.kind == .thought || $0.kind == .plan || $0.phase == .commentary
        }) else { return entries.startIndex }

        if let finalAnswer = entries.firstIndex(where: { $0.phase == .finalAnswer }) {
            return finalAnswer
        }

        let afterWork = entries.index(after: lastWork)
        return entries[afterWork...].lastIndex(where: { $0.kind == .agent }) ?? afterWork
    }
}

private struct TranscriptTurnRow: View {
    let turn: TranscriptTurn
    let isLive: Bool
    let isAwaitingPermission: Bool

    @State private var expansionOverride: Bool?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let responseStart = turn.responseStart
        let isExpanded = expansionOverride ?? isLive
        let hasCancelStatus = turn.entries.last?.kind == .status
            && ["cancelled", "canceled"].contains(turn.entries.last?.text ?? "")
        let summary = (isLive ? nil : turn.replyTiming).map { timing in
            let elapsed = timing.elapsed.formatted(
                .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated).locale(Locale(identifier: "zh-Hans"))
            )
            return timing.wasStopped ? "在 \(elapsed) 后停止" : "用时 \(elapsed)"
        }
        let response = turn.entries[responseStart...]
        VStack(alignment: .leading, spacing: 14) {
            if let user = turn.user {
                TranscriptEntryRow(entry: user, isStreaming: false)
            }
            if responseStart > turn.entries.startIndex {
                VStack(alignment: .leading, spacing: 10) {
                    workToggle(summary: summary, isExpanded: isExpanded)
                    if isExpanded {
                        VStack(alignment: .leading, spacing: 12) {
                            blocks(turn.entries[..<responseStart], showAgentLabel: false)
                        }
                    }
                }
            } else if let summary {
                Text(summary)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            blocks(hasCancelStatus && summary != nil ? response.dropLast() : response)
            if isLive {
                TranscriptActivity(entries: turn.entries, isAwaitingPermission: isAwaitingPermission)
            }
        }
    }

    private func workToggle(summary: String?, isExpanded: Bool) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                expansionOverride = !isExpanded
            }
        } label: {
            HStack(spacing: 8) {
                Text(summary ?? "工作过程")
                    .monospacedDigit()
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .font(.callout.weight(.medium))
#if os(macOS)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
#else
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
#endif
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(summary.map { "工作过程，\($0)" } ?? "工作过程")
        .accessibilityValue(isExpanded ? "已展开" : "已收起")
    }

    private func blocks(_ entries: ArraySlice<ACPEntry>, showAgentLabel: Bool = true) -> some View {
        ForEach(TranscriptBlock.group(entries)) { block in
            switch block {
            case .message(let entry):
                TranscriptEntryRow(entry: entry, isStreaming: isLive && turn.entries.last?.id == entry.id,
                                   showAgentLabel: showAgentLabel)
            case .tools(_, let calls):
                TranscriptToolGroup(calls: calls, isLive: isLive)
            }
        }
    }
}

private enum TranscriptBlock: Identifiable {
    case message(ACPEntry)
    case tools(UUID, [ACPEntry])

    var id: UUID {
        switch self {
        case .message(let entry): entry.id
        case .tools(let id, _): id
        }
    }

    static func group(_ entries: ArraySlice<ACPEntry>) -> [Self] {
        var blocks: [Self] = []
        var tools: [ACPEntry] = []

        func flushTools() {
            guard let first = tools.first else { return }
            blocks.append(.tools(first.id, tools))
            tools = []
        }

        for entry in entries {
            if entry.kind == .tool {
                tools.append(entry)
            } else {
                flushTools()
                blocks.append(.message(entry))
            }
        }
        flushTools()
        return blocks
    }
}

private struct TranscriptEntryRow: View {
    let entry: ACPEntry
    let isStreaming: Bool
    var showAgentLabel = true

    @ScaledMetric(relativeTo: .body) private var textSize = ConversationLayout.transcriptTextSize

    var body: some View {
        switch entry.kind {
        case .user:
            userMessage
        case .agent:
            VStack(alignment: .leading, spacing: 7) {
                if showAgentLabel {
                    Label("Agent", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                TranscriptMarkdown(entryID: entry.id, text: entry.text, isStreaming: isStreaming)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .thought:
            if !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DisclosureGroup {
                    TranscriptMarkdown(entryID: entry.id, text: entry.text, isStreaming: isStreaming)
                        .padding(.top, 5)
                } label: {
                    Label("思考过程", systemImage: "text.alignleft")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .modifier(TranscriptPanel())
            }
        case .tool:
            EmptyView()
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
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(entry.attachments) { attachment in
                    AttachmentBadge(preview: attachment)
                }
                if !entry.text.isEmpty {
                    Text(entry.text)
                        .font(.system(size: textSize))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(.primary.opacity(0.045), in: bubble)
                        .overlay { bubble.strokeBorder(.primary.opacity(0.075)).allowsHitTesting(false) }
                        .accessibilityLabel("你：\(entry.text)")
                }
            }
            .frame(maxWidth: 470, alignment: .trailing)
        }
    }
}

private struct TranscriptMarkdown: View {
    let entryID: UUID
    let text: String
    let isStreaming: Bool

    @ScaledMetric(relativeTo: .body) private var textSize = ConversationLayout.transcriptTextSize

    private static let defaultConfig = makeConfig(textSize: ConversationLayout.transcriptTextSize)

    var body: some View {
        let base = textSize == ConversationLayout.transcriptTextSize ? Self.defaultConfig : Self.makeConfig(textSize: textSize)
        TranscriptMarkdownDocument(entryID: entryID, text: text, textSize: textSize, isStreaming: isStreaming, config: base)
        .id(textSize)
        .textSelection(.enabled)

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

private struct TranscriptMarkdownDocument: View {
    let entryID: UUID
    let text: String
    let textSize: CGFloat
    let isStreaming: Bool
    let config: MarkdownRenderConfig

    private struct Snapshot: Equatable {
        let text: String
        let isStreaming: Bool
    }

    @Environment(\.transcriptMarkdownCache) private var cache
    @State private var parsed: (text: String, document: RenderableDocument)?
    private final class Updates {
        var latest: Snapshot?
        var continuation: AsyncStream<Snapshot>.Continuation?

        func submit(_ value: Snapshot) {
            latest = value
            continuation?.yield(value)
        }
    }
    @State private var updates = Updates()

    var body: some View {
        let snapshot = Snapshot(text: text, isStreaming: isStreaming)
        let cached = cache?.document(for: entryID, text: text, size: textSize)
        VStack(alignment: .leading, spacing: 0) {
            if let document = parsed?.document ?? cached {
                DocumentView(renderableDocument: document, config: config)
            } else if !isStreaming {
                Text(verbatim: text)
                    .font(.system(size: textSize))
                    .lineSpacing(3)
            }
        }
        .onChange(of: snapshot, initial: true) { _, next in updates.submit(next) }
        .task {
            let (stream, continuation) = AsyncStream.makeStream(of: Snapshot.self, bufferingPolicy: .bufferingNewest(1))
            updates.continuation = continuation
            defer { continuation.finish() }
            continuation.yield(updates.latest ?? snapshot)
            let parser = MarkdownParserImpl()
            for await next in stream {
                guard !Task.isCancelled else { break }
                let document: RenderableDocument
                if let parsed, parsed.text == next.text {
                    document = parsed.document
                } else if let cached = cache?.document(for: entryID, text: next.text, size: textSize) {
                    document = cached
                } else {
                    document = await parser.parse(text: next.text, config: config)
                }
                guard !Task.isCancelled else { break }
                parsed = (next.text, document)
                if !next.isStreaming {
                    cache?.store(document, for: entryID, text: next.text, size: textSize)
                }
            }
        }
    }
}

@MainActor
private final class TranscriptMarkdownCache {
    private final class Entry {
        let text: String
        let document: RenderableDocument

        init(text: String, document: RenderableDocument) {
            self.text = text
            self.document = document
        }
    }

    private let entries = NSCache<NSString, Entry>()

    init() {
        entries.countLimit = 512
        entries.totalCostLimit = 16 * 1024 * 1024
    }

    func document(for id: UUID, text: String, size: CGFloat) -> RenderableDocument? {
        let cached = entries.object(forKey: key(for: id, size: size))
        return cached?.text == text ? cached?.document : nil
    }

    func store(_ document: RenderableDocument, for id: UUID, text: String, size: CGFloat) {
        entries.setObject(Entry(text: text, document: document), forKey: key(for: id, size: size),
                          cost: max(512, text.utf8.count * 6))
    }

    private func key(for id: UUID, size: CGFloat) -> NSString {
        "\(id.uuidString)/\(size)" as NSString
    }
}

private extension EnvironmentValues {
    @Entry var transcriptMarkdownCache: TranscriptMarkdownCache?
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

struct TranscriptStatus {
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
