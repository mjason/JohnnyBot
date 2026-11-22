//
//  JohnnyBotTests.swift
//  JohnnyBotTests
//
//  Created by 林满佳 on 2026/11/22.
//

import Testing
@testable import JohnnyBot

@MainActor
struct JohnnyBotTests {
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
}
