//
//  JohnnyBotTests.swift
//  JohnnyBotTests
//
//  Created by 林满佳 on 2026/11/22.
//

import Foundation
import Testing
@testable import JohnnyBot
#if os(macOS)
import AppKit
#endif

@MainActor
struct JohnnyBotTests {
    @Test func restoresEachServersExpandedFoldersIncludingAnEmptySelection() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = ACPProject(path: nil)
        let folder = ACPProject(path: "/work/project")
        func restore(_ server: String) -> Set<ACPProject> {
            SidebarExpansion.restore(server: server, projects: [root, folder], defaultProject: root, defaults: defaults)
        }
        #expect(restore("A") == [root])
        SidebarExpansion.save([folder, ACPProject(path: "/removed")], server: "A", defaults: defaults)
        #expect(restore("A") == [folder])
        #expect(restore("B") == [root])
        SidebarExpansion.save([], server: "A", defaults: defaults)
        #expect(restore("A").isEmpty)
    }

    @Test func remembersServerTokensIndependentlyAcrossClientInstances() throws {
        let first = "wss://test.invalid/" + UUID().uuidString
        let second = first + "/other"
        defer {
            try? ServerCredentialStore.remove(first)
            try? ServerCredentialStore.remove(second)
        }
        try ServerCredentialStore.save("first-test-token", for: first)
        try ServerCredentialStore.save("second-test-token", for: second)
        try ServerCredentialStore.save("rotated-test-token", for: first)
        #expect(try ServerCredentialStore.token(for: first) == "rotated-test-token")
        try ServerCredentialStore.remove(first)
        #expect(try ServerCredentialStore.token(for: first) == nil)
        #expect(try ServerCredentialStore.token(for: second) == "second-test-token")
    }

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
    @Test func mainWindowKeepsItsSeparatorHiddenAfterToolbarChanges() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        let policy = MainWindowTitlebarView()
        window.contentView = policy
        #expect(window.titlebarSeparatorStyle == .none)
        for style in [NSTitlebarSeparatorStyle.automatic, .line] {
            window.toolbar = NSToolbar(identifier: UUID().uuidString)
            window.titlebarSeparatorStyle = style
            window.update()
            for _ in 0..<20 where window.titlebarSeparatorStyle != .none {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(window.titlebarSeparatorStyle == .none)
        }
        window.contentView = nil
        window.titlebarSeparatorStyle = .line
        await Task.yield()
        #expect(window.titlebarSeparatorStyle == .line)
    }

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
