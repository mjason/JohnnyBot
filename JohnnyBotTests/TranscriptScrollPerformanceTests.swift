#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import JohnnyBot

@MainActor
struct TranscriptScrollPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JOHNNYBOT_SCROLL_PERF"] == "1"))
    func scrollHistoryWhileReceivingAReply() async throws {
        let timeline = TranscriptTimeline()
        let replies = [
            "这份报告记录了处理步骤和复核结果。",
            "**处理完毕**，共检查了 28 个文件。\n\n- 读取原始数据\n- 校验输出文件\n- 记录变更",
            "以下是本次结果。\n\n| 分类 | 数量 |\n| --- | --- |\n| 已检查 | 26 |\n| 待复核 | 2 |",
            "示例代码和 [接口说明](https://example.org/guide)。\n\n```swift\nlet count = 42\nprint(count)\n```"
        ]
        var entries: [ACPEntry] = []
        for index in 0..<3500 {
            entries.append(ACPEntry(kind: .user, text: "检查第 \(index) 份报告"))
            entries.append(ACPEntry(kind: .agent, text: "正在梳理输入资料。", phase: .commentary))
            entries.append(ACPEntry(kind: .tool, text: "读取数据", toolID: String(index), toolStatus: "completed"))
            entries.append(ACPEntry(kind: .agent, text: replies[index % replies.count], phase: .finalAnswer))
        }
        timeline.replace(entries)
        let host = NSHostingView(rootView: SessionTranscript(timeline: timeline, isResponding: true, permissions: [],
                                                              horizontalMargin: 20, composerSpacing: 24) { _, _ in })
        let screen = try #require(NSScreen.screens.max { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond })
        let window = NSWindow(contentRect: CGRect(x: 30, y: 30, width: 900, height: 680),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false, screen: screen)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        func transcriptScrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.bounds.width > 450,
               let document = scroll.documentView, document.bounds.height > 2000 { return scroll }
            for child in view.subviews {
                if let found = transcriptScrollView(in: child) { return found }
            }
            return nil
        }
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if transcriptScrollView(in: host) != nil { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let scroll = try #require(transcriptScrollView(in: host))
        let document = try #require(scroll.documentView)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, document.bounds.height - scroll.bounds.height - 400)))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(500))
        let probe = ScrollProbe(scroll: scroll) {
            let index = entries.count - 1
            entries[index].text += " 新片段"
            timeline.update(entries, at: index)
        }
        await probe.run(on: screen)
        #expect(probe.intervals.count > 0)
        #expect(probe.distance > 1000)
        let sorted = probe.intervals.sorted()
        if !sorted.isEmpty {
            let p99 = sorted[Int(Double(sorted.count - 1) * 0.99)]
            let rate = Double(sorted.count) / sorted.reduce(0, +)
            print("Threadlist: display \(screen.maximumFramesPerSecond) Hz, callbacks \(rate.formatted()) Hz, P99 \((p99 * 1000).formatted()) ms, missed intervals \(probe.missed)")
        }
    }

    /// Drive native scroll-wheel input on the test screen. Production scrolling
    /// has no display link. Each interval is compared with its own target budget.
    private final class ScrollProbe: NSObject {
        let scroll: NSScrollView
        let appendChunk: () -> Void
        private var first: CFTimeInterval?
        private var previous: CFTimeInterval = 0
        private var budget: CFTimeInterval = 0
        private var lastY: CGFloat
        private var nextChunk: CFTimeInterval = 0
        private var finish: CheckedContinuation<Void, Never>?
        var intervals: [CFTimeInterval] = []
        var distance: CGFloat = 0
        var missed = 0

        init(scroll: NSScrollView, appendChunk: @escaping () -> Void) {
            self.scroll = scroll
            self.appendChunk = appendChunk
            lastY = scroll.contentView.bounds.minY
        }

        func run(on screen: NSScreen) async {
            await withCheckedContinuation { continuation in
                finish = continuation
                let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
                let rate = Float(screen.maximumFramesPerSecond)
                link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
                link.add(to: .main, forMode: .common)
            }
        }

        @objc private func tick(_ link: CADisplayLink) {
            let now = link.timestamp
            if first == nil { first = now }
            if budget > 0 {
                let gap = now - previous
                intervals.append(gap)
                missed += max(0, Int((gap / budget).rounded()) - 1)
            }
            previous = now
            budget = link.targetTimestamp - now
            let elapsed = now - (first ?? now)
            let y = scroll.contentView.bounds.minY
            distance += abs(y - lastY)
            lastY = y
            if elapsed >= 8 {
                link.invalidate()
                finish?.resume()
                finish = nil
                return
            }
            if elapsed >= nextChunk {
                appendChunk()
                nextChunk = elapsed + 0.05
            }
            let speeds = [1000.0, 2800.0, 5500.0, -3000.0]
            let pixels = Int32((speeds[Int(elapsed / 2)] * budget).rounded())
            if let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                   wheel1: pixels, wheel2: 0, wheel3: 0) {
                wheel.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                if let event = NSEvent(cgEvent: wheel) { scroll.scrollWheel(with: event) }
            }
        }
    }
}
#endif
