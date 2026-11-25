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
    let timeline: TranscriptTimeline
    let isResponding: Bool
    let permissions: [ACPPermission]
    let horizontalMargin: CGFloat
    let composerSpacing: CGFloat
    let respondToPermission: (ACPPermission, String?) -> Void

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var showsJumpToLatest = false
    @ScaledMetric(relativeTo: .body) private var textSize = ConversationLayout.transcriptTextSize
    @State private var markdownCache = TranscriptMarkdownCache()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(timeline: TranscriptTimeline, isResponding: Bool, permissions: [ACPPermission], horizontalMargin: CGFloat,
         composerSpacing: CGFloat, respondToPermission: @escaping (ACPPermission, String?) -> Void) {
        self.timeline = timeline
        self.isResponding = isResponding
        self.permissions = permissions
        self.horizontalMargin = horizontalMargin
        self.composerSpacing = composerSpacing
        self.respondToPermission = respondToPermission
    }

    var body: some View {
        VStack(spacing: 0) {
            messages
#if !os(iOS)
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    if permissions.isEmpty {
                        Color.clear
                            .frame(height: composerSpacing)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
#endif
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
#if os(macOS)
        GeometryReader { viewport in
            messageScrollView(minHeight: viewport.size.height)
        }
#else
        messageScrollView(minHeight: 0)
#endif
    }

    private func messageScrollView(minHeight: CGFloat) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(timeline.rows) { row in
                    TranscriptTurnRow(
                        row: row, isLive: isResponding && row.id == timeline.rows.last?.id,
                        isAwaitingPermission: !permissions.isEmpty
                    )
                    .onAppear {
                        markdownCache.prefetch(around: row.index, in: timeline, size: textSize, streaming: isResponding)
                    }
                }
            }
            .frame(maxWidth: ConversationLayout.maxContentWidth)
            .padding(.horizontal, horizontalMargin)
            .padding(.top, 20)
            .padding(.bottom, max(8, composerSpacing))
            // Anchor short replies at the top so each new line grows downwards.
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .top)
        }
        .environment(\.transcriptMarkdownCache, markdownCache)
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.top, for: .alignment)
#if os(macOS)
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
#endif
        .onChange(of: timeline.rows.count) { previousCount, count in
            if count > previousCount, timeline.rows.last?.turn.user != nil {
                position.scrollTo(edge: .bottom)
            }
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.height > geometry.visibleRect.maxY + 90
        } action: { _, awayFromBottom in
            showsJumpToLatest = awayFromBottom
        }
        .scrollEdgeEffectStyle(.soft, for: .bottom)
#if os(iOS)
        .scrollDismissesKeyboard(.interactively)
#endif
        .overlay {
            if timeline.rows.isEmpty, !isResponding {
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
        }
#if os(visionOS)
        .buttonStyle(.bordered)
#else
        .buttonStyle(.glass)
#endif
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .help("回到最新消息")
    }
}

private struct TranscriptTurnRow: View {
    let row: TranscriptTimeline.Row
    private var turn: TranscriptTurn { row.turn }
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
                    TranscriptPlainText(text: entry.text, size: textSize, lineSpacing: 3)
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

#if os(iOS)
private struct TranscriptPlainText: UIViewRepresentable {
    let text: String
    let size: CGFloat
    let lineSpacing: CGFloat

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        guard view.text != text || view.font?.pointSize != size else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        view.attributedText = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: size), .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph
        ])
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        // Measure the unwrapped width independently of the previous layout pass.
        let natural = uiView.attributedText.size().width.rounded(.up)
        return CGSize(width: min(width, natural), height: ceil(fit.height))
    }
}
#else
private struct TranscriptPlainText: View {
    let text: String
    let size: CGFloat
    let lineSpacing: CGFloat

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: size))
            .lineSpacing(lineSpacing)
            .textSelection(.enabled)
    }
}
#endif

private struct TranscriptMarkdown: View {
    let entryID: UUID
    let text: String
    let isStreaming: Bool
    @State private var usedStreamingRenderer = false

    @ScaledMetric(relativeTo: .body) private var textSize = ConversationLayout.transcriptTextSize

    private static let defaultConfig = makeConfig(textSize: ConversationLayout.transcriptTextSize)

    static func config(for size: CGFloat) -> MarkdownRenderConfig {
        size == ConversationLayout.transcriptTextSize ? defaultConfig : makeConfig(textSize: size)
    }

    // A single unmarked paragraph can be displayed immediately with system text.
    // Route punctuation with Markdown, entity, URL or math semantics to the parser.
    static func isPlainParagraph(_ text: String) -> Bool {
        guard let first = text.first, !first.isWhitespace, text.last?.isWhitespace == false else { return false }
        return text.rangeOfCharacter(from: markdownSyntax) == nil
    }

    private static let markdownSyntax = CharacterSet(charactersIn: "\n\r\t`*_~[]<>\\&$!#|{}:./=-@^+\u{2028}\u{2029}")

    var body: some View {
        content.onChange(of: isStreaming, initial: true) { _, live in
            if live { usedStreamingRenderer = true }
        }
    }

    @ViewBuilder private var content: some View {
        if !isStreaming && !usedStreamingRenderer && Self.isPlainParagraph(text) {
            TranscriptPlainText(text: text, size: textSize, lineSpacing: 5)
        } else {
            TranscriptMarkdownDocument(entryID: entryID, text: text, textSize: textSize,
                                       isStreaming: isStreaming, config: Self.config(for: textSize))
                .id(textSize)
                .textSelection(.enabled)
        }
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
    @State private var parsed: (snapshot: Snapshot, document: RenderableDocument)?
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
            let clock = ContinuousClock()
            var nextUpdate = clock.now
            for await submitted in stream {
                if submitted.isStreaming, clock.now < nextUpdate {
                    try? await clock.sleep(until: nextUpdate)
                }
                let next = updates.latest ?? submitted
                guard !Task.isCancelled else { break }
                let document: RenderableDocument
                if parsed?.snapshot == next {
                    continue
                } else if !next.isStreaming, let cache {
                    document = await cache.finishedDocument(for: entryID, text: next.text, size: textSize, config: config)
                } else {
                    document = await parser.parse(text: next.text, config: config, speculativeRewrite: next.isStreaming)
                }
                guard !Task.isCancelled else { break }
                parsed = (next, document)
                nextUpdate = clock.now.advanced(by: .milliseconds(16))
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
    private struct Job: Hashable {
        let id: UUID
        let text: String
        let size: CGFloat
    }
    private var pending: [Job] = []
    private var worker: Task<Void, Never>?
    private var parsing: [Job: Task<RenderableDocument, Never>] = [:]

    func finishedDocument(for id: UUID, text: String, size: CGFloat, config: MarkdownRenderConfig) async -> RenderableDocument {
        if let document = document(for: id, text: text, size: size) { return document }
        let job = Job(id: id, text: text, size: size)
        if let task = parsing[job] { return await task.value }
        let task = Task.detached(priority: Task.currentPriority) {
            await MarkdownParserImpl().parse(text: text, config: config)
        }
        parsing[job] = task
        let result = await task.value
        parsing.removeValue(forKey: job)
        store(result, for: id, text: text, size: size)
        return result
    }

    func prefetch(around index: Int, in timeline: TranscriptTimeline, size: CGFloat, streaming: Bool) {
        // Limit look-ahead to neighboring replies. Skip collapsed work, live
        // output and stale requests left behind by a fast scroll.
        for neighbor in [index - 1, index + 1, index - 2, index + 2] where timeline.rows.indices.contains(neighbor) {
            if streaming && neighbor == timeline.rows.count - 1 { continue }
            let turn = timeline.rows[neighbor].turn
            for entry in turn.entries[turn.responseStart...].prefix(2) where entry.kind == .agent {
                guard !TranscriptMarkdown.isPlainParagraph(entry.text),
                      document(for: entry.id, text: entry.text, size: size) == nil,
                      !pending.contains(where: { $0.id == entry.id && $0.size == size }) else { continue }
                pending.append(Job(id: entry.id, text: entry.text, size: size))
            }
        }
        if pending.count > 8 { pending.removeFirst(pending.count - 8) }
        guard worker == nil, !pending.isEmpty else { return }
        worker = Task(priority: .utility) { [weak self] in
            while let self, !pending.isEmpty {
                let job = pending.removeFirst()
                _ = await finishedDocument(for: job.id, text: job.text, size: job.size, config: TranscriptMarkdown.config(for: job.size))
            }
            self?.worker = nil
        }
    }


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
                    Button("停止本轮对话") { respond(nil) }
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
