#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import JohnnyBot

@MainActor
struct StreamingTranscriptTests {
    @Test func wrappedParagraphKeepsItsLayoutWhenStreamingFinishes() async throws {
        var reply = ACPEntry(kind: .agent, text: "第一行")
        func transcript(live: Bool) -> SessionTranscript {
            let timeline = TranscriptTimeline()
            timeline.replace([reply])
            return SessionTranscript(timeline: timeline, isResponding: live, permissions: [],
                              horizontalMargin: 20, composerSpacing: 24) { _, _ in }
        }
        let host = NSHostingView(rootView: transcript(live: true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 350, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        func paragraph(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView, text.string.contains("末行标记") { return text }
            return view.subviews.lazy.compactMap { paragraph(in: $0) }.first
        }
        for index in 0..<18 {
            reply.text += " 新增一段会自动换行的文字\(index)。"
            host.rootView = transcript(live: true)
            await Task.yield()
        }
        reply.text += " **末行标记**"
        host.rootView = transcript(live: true)
        for _ in 0..<150 {
            host.layoutSubtreeIfNeeded()
            if paragraph(in: host) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let live = try #require(paragraph(in: host))
        #expect(!live.string.contains("**"))
        let manager = try #require(live.layoutManager)
        let container = try #require(live.textContainer)
        manager.ensureLayout(for: container)
        #expect(live.bounds.height + 1 >= manager.usedRect(for: container).height)

        host.rootView = transcript(live: false)
        try await Task.sleep(for: .milliseconds(120))
        host.layoutSubtreeIfNeeded()
        #expect(paragraph(in: host) === live)
    }
    @Test(arguments: [NSAppearance.Name.aqua.rawValue, NSAppearance.Name.darkAqua.rawValue])
    func unfinishedEmphasisResolvesWhenStreamEnds(appearance: String) async throws {
        let timeline = TranscriptTimeline()
        timeline.replace([ACPEntry(kind: .agent, text: "检查 **末行标记", phase: .finalAnswer)])
        func transcript(live: Bool) -> SessionTranscript {
            SessionTranscript(timeline: timeline, isResponding: live, permissions: [],
                              horizontalMargin: 20, composerSpacing: 24) { _, _ in }
        }
        let host = NSHostingView(rootView: transcript(live: true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 350, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: NSAppearance.Name(appearance))
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        func contains(_ text: String, in view: NSView) -> Bool {
            if let paragraph = view as? NSTextView, paragraph.string == text { return true }
            return view.subviews.contains { contains(text, in: $0) }
        }
        for (live, expected) in [(true, "检查 末行标记"), (false, "检查 **末行标记")] {
            host.rootView = transcript(live: live)
            for _ in 0..<100 {
                host.layoutSubtreeIfNeeded()
                if contains(expected, in: host) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(contains(expected, in: host))
        }
    }

    @Test func copiesAcrossParagraphsWhileReplyGrows() async throws {
        let timeline = TranscriptTimeline()
        var reply = ACPEntry(kind: .agent, text: "第一段落。\n\n第二段落。", phase: .finalAnswer)
        timeline.replace([reply])
        let host = NSHostingView(rootView: SessionTranscript(timeline: timeline, isResponding: true,
            permissions: [], horizontalMargin: 20, composerSpacing: 24) { _, _ in })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 350, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        func paragraph(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView, text.string.contains("第一段落"),
               text.string.contains("第二段落") { return text }
            return view.subviews.lazy.compactMap { paragraph(in: $0) }.first
        }
        for _ in 0..<50 {
            host.layoutSubtreeIfNeeded()
            if paragraph(in: host) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let text = try #require(paragraph(in: host))
        let range = (text.string as NSString).range(of: "段落。\n\n第二")
        try #require(range.location != NSNotFound)
        func firstLineY() -> CGFloat {
            text.convert(NSPoint(x: 0, y: text.isFlipped ? text.bounds.minY : text.bounds.maxY), to: nil).y
        }
        let startY = firstLineY()
        text.setSelectedRange(range)
        reply.text += "\n\n第三段开始换行。\n\n追加内容"
        timeline.update([reply], at: 0)
        for _ in 0..<50 {
            host.layoutSubtreeIfNeeded()
            if text.string.hasSuffix("追加内容") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(text.string.hasSuffix("追加内容"))
        #expect(abs(firstLineY() - startY) <= 1)
        #expect(text.selectedRange() == range)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        #expect(text.writeSelection(to: board, types: [.string]))
        #expect(board.string(forType: .string) == "段落。\n\n第二")
    }

}
#endif
