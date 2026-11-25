import Testing
@testable import JohnnyBot

@MainActor
struct TranscriptTimelineTests {
    @Test func historyPagesCountEntriesAcrossTurnBoundaries() {
        let timeline = TranscriptTimeline()
        let history = (0..<253).map { i in
            ACPEntry(kind: i == 0 || i == 200 ? .user : .agent, text: String(i))
        }
        timeline.replace(history)
        #expect(timeline.entryCount == history.count)
        for start in [153, 53, 0] {
            let page = timeline.visibleRows(from: start).flatMap { row in
                let turn = timeline.visibleTurn(row, from: start)
                return [turn.user].compactMap { $0 } + Array(turn.entries)
            }
            #expect(page.map(\.id) == history[start...].map(\.id))
        }
    }

    @Test func flushCombinesNewTurnsAndLateToolUpdates() {
        let timeline = TranscriptTimeline()
        var entries = [ACPEntry(kind: .user, text: "first"), ACPEntry(kind: .tool, text: "running")]
        timeline.replace(entries)
        let original = timeline.rows[0]
        entries[1].text = "done"
        entries.append(ACPEntry(kind: .agent, text: "first answer"))
        entries.append(ACPEntry(kind: .user, text: "second"))
        entries.append(ACPEntry(kind: .agent, text: "second answer"))
        timeline.update(entries, changedOffsets: [1, 2, 3, 4])
        #expect(timeline.rows[0] === original)
        #expect(original.turn.entries.map(\.text) == ["done", "first answer"])
        #expect(timeline.rows[1].turn.user?.text == "second")
        #expect(timeline.rows[1].turn.entries.last?.text == "second answer")
    }

    @Test func streamingAndLateEventsKeepUnrelatedTurnsStable() {
        let timeline = TranscriptTimeline()
        var entries = [
            ACPEntry(kind: .agent, text: "会话简介"),
            ACPEntry(kind: .user, text: "第一次"),
            ACPEntry(kind: .tool, text: "读取", toolID: "t"),
            ACPEntry(kind: .agent, text: "回答", phase: .finalAnswer),
            ACPEntry(kind: .user, text: "第二次")
        ]
        timeline.replace(entries)
        let original = timeline.rows
        entries.append(ACPEntry(kind: .agent, text: "新", messageID: "m"))
        timeline.update(entries, at: 5)
        entries[5].text += "内容"
        timeline.update(entries, at: 5)
        entries[2].toolStatus = "completed"
        timeline.update(entries, at: 2)
        #expect(timeline.rows.count == 3)
        #expect(zip(timeline.rows, original).allSatisfy { $0 === $1 })
        #expect(original[0].turn.user == nil)
        #expect(original[1].turn.entries.first?.toolStatus == "completed")
        #expect(original[1].turn.entries[original[1].turn.responseStart].text == "回答")
        #expect(original[2].turn.entries.last?.text == "新内容")
        entries.append(ACPEntry(kind: .user, text: "第三次"))
        timeline.update(entries, at: 6)
        #expect(timeline.rows.last?.turn.user?.text == "第三次")
        #expect(timeline.rows.count == 4)
        entries.remove(at: 4)
        timeline.replace(entries)
        #expect(timeline.rows.count == 3)
        #expect(timeline.rows[1].turn.entries.last?.text == "新内容")
    }
}
