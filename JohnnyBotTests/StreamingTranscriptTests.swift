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
            SessionTranscript(entries: [reply], isResponding: live, permissions: [],
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
}
#endif
