//
//  JohnnyBotTests.swift
//  JohnnyBotTests
//
//  Created by 林满佳 on 2026/11/22.
//

import Testing
@testable import JohnnyBot
#if os(macOS)
import AppKit
#endif

@MainActor
struct JohnnyBotTests {
    @Test func findsTheHomeDirectoryOnOlderServers() {
        let client = ACPClient(address: "", token: "")

        #expect(client.projectHomeDirectory(defaultPath: "/home/mj/dev/project") == "/home/mj")
        #expect(client.projectHomeDirectory(defaultPath: "/Users/example/project") == "/Users/example")
        #expect(client.projectHomeDirectory(defaultPath: "/root/workspace") == "/root")
        #expect(client.projectHomeDirectory(defaultPath: "/srv/project") == nil)
    }

    @Test func groupsIntermediateWorkWithoutHidingTheFinalResponse() throws {
        let turns = TranscriptTurn.group([
            ACPEntry(kind: .user, text: "First request"),
            ACPEntry(kind: .agent, text: "Initial progress"),
            ACPEntry(kind: .tool, text: "Read file"),
            ACPEntry(kind: .agent, text: "Follow-up progress"),
            ACPEntry(kind: .agent, text: "Final response"),
            ACPEntry(kind: .status, text: "max_tokens"),
            ACPEntry(kind: .user, text: "Second request"),
            ACPEntry(kind: .agent, text: "Direct response")
        ])

        #expect(turns.count == 2)
        let first = try #require(turns.first)
        #expect(first.entries[..<first.responseStart].map(\.text) == ["Initial progress", "Read file", "Follow-up progress"])
        #expect(first.entries[first.responseStart...].map(\.text) == ["Final response", "max_tokens"])

        let second = try #require(turns.last)
        #expect(second.entries.startIndex == second.responseStart)
    }

    @Test func keepsAllExplicitFinalMessagesVisible() throws {
        let turns = TranscriptTurn.group([
            ACPEntry(kind: .user, text: "Request"),
            ACPEntry(kind: .agent, text: "Progress", phase: .commentary),
            ACPEntry(kind: .agent, text: "First answer", phase: .finalAnswer),
            ACPEntry(kind: .agent, text: "Second answer", phase: .finalAnswer)
        ])

        let turn = try #require(turns.first)
        #expect(turn.entries[..<turn.responseStart].map(\.text) == ["Progress"])
        #expect(turn.entries[turn.responseStart...].map(\.text) == ["First answer", "Second answer"])
    }

#if os(macOS)
    @Test func restoresTerminalOnTheCurrentDisplay() {
        let primary = NSRect(x: 0, y: 0, width: 1600, height: 950)
        let secondary = NSRect(x: -1280, y: 200, width: 1280, height: 750)
        let original = NSRect(x: 95, y: 180, width: 780, height: 470)
        let restore = TerminalWindowRestoreFrame(frame: original, display: primary)

        #expect(restore.isFilled(secondary, in: secondary))
        #expect(!restore.isFilled(primary, in: secondary))
        #expect(restore.restored(in: primary) == original)
        #expect(restore.restored(in: secondary) == NSRect(x: -1185, y: 200, width: 780, height: 470))

        let smaller = NSRect(x: 1600, y: -250, width: 640, height: 420)
        #expect(restore.restored(in: smaller) == smaller)
    }
#endif
}
