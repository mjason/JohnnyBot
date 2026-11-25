//
//  JohnnyBotTests.swift
//  JohnnyBotTests
//
//  Created by 林满佳 on 2026/11/22.
//

import Foundation
import CryptoKit
import Testing
@testable import JohnnyBot
#if os(macOS)
import AppKit
import SwiftUI
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

    @Test func identityIsStableAndExportsOpenSSHPublicKey() throws {
        let key = Curve25519.Signing.PrivateKey()
        let identity = DeviceIdentity(key: key)
        let restored = DeviceIdentity(key: try .init(rawRepresentation: key.rawRepresentation))
        #expect(restored.id == identity.id && identity.id.count == 32)
        let parts = identity.publicLine.split(separator: " ")
        #expect(parts.first == "ssh-ed25519")
        let bytes = try #require(Data(base64Encoded: String(parts[1])))
        #expect(bytes == Data([0, 0, 0, 11]) + Data("ssh-ed25519".utf8) + Data([0, 0, 0, 32]) + key.publicKey.rawRepresentation)
    }

    @Test func resumesFragmentedPagesAndRejectsStaleReplies() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = "thread/demo"
        func page(after: Int64, seq: Int64, part: Int64, last: Bool, text: String) -> [String: Any] {
            let fragment: [String: Any] = ["id": "f", "kind": "session.setup", "part": part, "last": last,
                                           "bytes": Data(text.utf8).base64EncodedString()]
            return ["scope": scope, "epoch": "one", "after": after, "through": Int64(17), "more": !last,
                    "events": [["seq": seq, "kind": "event.fragment", "data": fragment]]]
        }
        let first = try GoReplica(name: "test", directory: directory)
        let initial = try first.cursor(scope)
        let a = page(after: 0, seq: 3, part: 0, last: false, text: "{\"ok\":")
        #expect(try first.apply(a, scope: scope, expected: initial, epoch: "one").isEmpty)
        let second = try GoReplica(name: "test", directory: directory)
        let checkpoint = try second.cursor(scope)
        #expect(checkpoint.after == 3 && checkpoint.through == 17)
        #expect(throws: ACPFailure.self) { try second.apply(a, scope: scope, expected: initial, epoch: "one") }
        let b = page(after: 3, seq: 17, part: 1, last: true, text: "true}")
        let emitted = try second.apply(b, scope: scope, expected: checkpoint, epoch: "one")
        #expect(emitted.count == 1 && emitted.first?.data["ok"] as? Bool == true)
        #expect(try first.history(scope).count == 1)
        #expect(try first.cursor(scope).through == 0)
        let payload = Data("original bytes".utf8)
        try first.queue(id: "queued", epoch: "one", payload: payload)
        #expect(try second.pending(epoch: "two").isEmpty)
        #expect(try second.pending(epoch: "one").first?.payload == payload)
        try second.complete(id: "queued", reply: ["ok": true])
        #expect(try first.pending(epoch: "one").isEmpty)
    }

    @Test func opensCompletedCacheBeforeConnecting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = ACPClient(address: "mqtts://localhost:8883/test", fingerprint: "test-pin")
        let identity = DeviceIdentity(key: .init())
        let name = [client.address, client.fingerprint, identity.id].joined(separator: "\n")
        let epochKey = "goEpoch." + name
        UserDefaults.standard.set("one", forKey: epochKey)
        defer { UserDefaults.standard.removeObject(forKey: epochKey) }
        let cache = try GoReplica(name: name, directory: directory)
        func seed(_ scope: String, kind: String, items: [[String: Any]], more: Bool = false) throws {
            let count = Int64(items.count)
            let events = items.enumerated().map { i, data -> [String: Any] in
                ["seq": Int64(i + 1), "kind": kind, "data": data]
            }
            _ = try cache.apply(["epoch": "one", "scope": scope, "after": Int64(0), "through": more ? count + 1 : count,
                                 "more": more, "events": events], scope: scope, expected: .init(), epoch: "one")
        }
        try seed("threads/test", kind: "thread.upsert", items: ["ready", "partial", "missing", "stale"].map {
            ["thread_id": $0, "workspace_id": "test", "path": ".", "history_imported": true]
        })
        let prompt = ["prompt": [["type": "text", "text": "cached"]]]
        try seed("thread/ready", kind: "message.user", items: [prompt])
        try seed("thread/partial", kind: "message.user", items: [prompt], more: true)
        try seed("thread/stale", kind: "turn.started", items: [["turn_id": "finished-while-offline"]])
        try client.prepareReplica(identity: identity, directory: directory)
        try client.restoreCachedDirectory(.init(path: "test"))
        for id in ["ready", "partial", "missing", "stale"] { try client.restoreCachedTranscript(id) }
        #expect(!client.connected)
        #expect(client.loaded == ["ready", "stale"])
        #expect(!client.prompting.contains("stale"))
        #expect(client.awaitingTurnStatus("stale"))
        #expect(client.timelines["ready"]?.rows.first?.turn.user?.text == "cached")
        #expect(client.timelines["partial"]?.entryCount == 1)
    }

    @Test func replaysACPv2ChildInItsOwnActivity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = ACPClient(address: "mqtts://localhost:8883/test", fingerprint: "test-pin")
        let identity = DeviceIdentity(key: .init())
        let name = [client.address, client.fingerprint, identity.id].joined(separator: "\n")
        let epochKey = "goEpoch." + name
        UserDefaults.standard.set("one", forKey: epochKey)
        defer { UserDefaults.standard.removeObject(forKey: epochKey) }
        let cache = try GoReplica(name: name, directory: directory)
        let updates: [(String, [String: Any])] = [
            ("root", ["sessionUpdate": "user_message", "messageId": "1", "content": [["text": "request"]]]),
            ("root", ["sessionUpdate": "subagent_update", "sessionId": "child", "title": "Investigator"]),
            ("child", ["sessionUpdate": "agent_message_chunk", "messageId": "2", "content": ["text": "draft"]]),
            ("child", ["sessionUpdate": "agent_message", "messageId": "2", "content": [["text": "finding"]]]),
            ("child", ["sessionUpdate": "state_update", "state": "idle"]),
            ("root", ["sessionUpdate": "agent_message", "messageId": "2", "content": [["text": "answer"]]])
        ]
        let events = updates.enumerated().map { offset, item -> [String: Any] in
            ["seq": Int64(offset + 1), "kind": "acp.history", "data": ["protocolVersion": 2,
             "rootSessionId": "root", "sessionId": item.0, "update": item.1] as [String: Any]]
        }
        let scope = "thread/root"
        _ = try cache.apply(["epoch": "one", "scope": scope, "after": Int64(0), "through": Int64(events.count),
                             "more": false, "events": events], scope: scope, expected: .init(), epoch: "one")
        try client.prepareReplica(identity: identity, directory: directory)
        try client.restoreCachedTranscript("root")
        let turn = try #require(client.timelines["root"]?.rows.first?.turn)
        #expect(turn.user?.text == "request")
        #expect(turn.entries.map(\.text) == ["Investigator", "answer"])
        let child = try #require(turn.entries.first)
        #expect(child.toolStatus == "completed")
        #expect(child.toolContent.count == 1)
        if case let .text(value) = child.toolContent.first { #expect(value == "finding") }
        else { Issue.record("Missing child response") }
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
    @Test func projectFileLinkOpensIndependentResizableWindow() async throws {
        struct FileLink: View {
            @Environment(\.openURL) var openURL
            let url: URL
            var body: some View { Color.clear.onAppear { openURL(url) } }
        }

        let url = URL(filePath: "/remote/preview-\(UUID()).swift")
        let link = FileLink(url: url).modifier(ProjectLinkPreview(
            client: ACPClient(address: ""), session: "preview"
        ))
        let parent = NSWindow(contentViewController: NSHostingController(rootView: link))
        parent.orderBack(nil)
        defer { parent.orderOut(nil) }
        for _ in 0..<100 {
            if NSApp.windows.contains(where: { $0.title == url.lastPathComponent }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let editor = try #require(NSApp.windows.first { $0.title == url.lastPathComponent })
        defer { editor.close() }
        #expect(editor.sheetParent == nil)
        #expect(editor.collectionBehavior.contains(.fullScreenPrimary))
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try #require(editor.standardWindowButton(kind))
            #expect(button.isEnabled && !button.isHidden)
        }
        editor.miniaturize(nil)
        for _ in 0..<100 where !editor.isMiniaturized { try await Task.sleep(for: .milliseconds(20)) }
        #expect(editor.isMiniaturized)
        editor.deminiaturize(nil)
        for _ in 0..<100 where editor.isMiniaturized { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!editor.isMiniaturized)
    }

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
