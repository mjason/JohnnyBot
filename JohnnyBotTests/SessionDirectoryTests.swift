import Observation
import Testing
@testable import JohnnyBot

@MainActor
struct SessionDirectoryTests {
    let directory = SessionDirectory()
    let all = ACPProject(path: nil)
    let project = ACPProject(path: "/work")

    private func list(_ ids: [String], in project: ACPProject, retaining loaded: Set<String> = [], complete: Bool = true) {
        let items = ids.map { ListedSession(id: $0, title: $0, cwd: "/work") }
        directory.replace(items, ids: Set(ids), in: project, retaining: loaded, complete: complete)
    }

    @Test func keepsSharedRowsAcrossRefreshRenameAndRemoval() throws {
        list(["a", "b"], in: all)
        list(["a", "b"], in: project)
        let shared = try #require(directory.session(id: "a"))
        #expect(directory.rows(in: project).first === shared)
        list(["b", "a"], in: project)
        #expect(directory.rows(in: project).last === shared)
        directory.updateTitle("new", for: "a")
        #expect(directory.rows(in: all).first?.title == "new")
        list([], in: project)
        #expect(directory.session(id: "a") === shared)
        directory.remove("a")
        #expect(directory.session(id: "a") == nil)
        #expect(directory.rows(in: all).map(\.id) == ["b"])
        #expect(directory.contains("a", in: all) == false)
    }

    @Test func mergesFirstPageAndFullListWithLocallyLoadedSessions() throws {
        let local = ACPSession(id: "local", title: "local")
        directory.insert(local, in: project, atFront: true)
        list(["a"], in: project, retaining: ["local"], complete: false)
        #expect(!directory.hasListed(project))
        #expect(directory.rows(in: project).map(\.id) == ["a", "local"])
        list(["b", "a"], in: project, retaining: ["local"])
        #expect(directory.hasListed(project))
        #expect(directory.rows(in: project).map(\.id) == ["b", "a", "local"])
        list(["a"], in: project)
        #expect(directory.session(id: "local") == nil)
        #expect(directory.session(id: "b") == nil)
        directory.removeAll()
        #expect(!directory.hasListed(project))
        #expect(directory.session(id: "a") == nil)
    }

    @Test func unchangedRefreshAndRetitlePreserveRowCollection() throws {
        list(["a", "b"], in: project)
        withObservationTracking {
            _ = directory.rows(in: project)
        } onChange: {
            Issue.record("The row collection changed without a membership or order change")
        }
        list(["a", "b"], in: project)
        directory.updateTitle("renamed", for: "b")
        #expect(directory.session(id: "b")?.title == "renamed")
    }
}
