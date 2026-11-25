import Observation

@MainActor @Observable
final class ACPSession: Identifiable {
    let id: String
    var title: String
    var cwd: String

    init(id: String, title: String, cwd: String = "") {
        self.id = id
        self.title = title
        self.cwd = cwd
    }

    fileprivate func update(title: String, cwd: String) {
        if self.title != title { self.title = title }
        if self.cwd != cwd { self.cwd = cwd }
    }
}

struct ListedSession {
    let id: String
    var title: String
    let cwd: String
}

@MainActor @Observable
final class SessionDirectory {
    @Observable fileprivate final class ProjectList {
        var revision: UInt64 = 0
        var rows: [ACPSession] = [] { didSet { revision &+= 1 } }
        var complete = false
        var ids: Set<String> = []
    }

    private var lists: [ACPProject: ProjectList] = [:]
    private var byID: [String: ACPSession] = [:]

    func session(id: String) -> ACPSession? { byID[id] }
    func rows(in project: ACPProject) -> [ACPSession] { lists[project]?.rows ?? [] }
    func revision(in project: ACPProject) -> UInt64 { lists[project]?.revision ?? 0 }
    func hasListed(_ project: ACPProject) -> Bool { lists[project]?.complete == true }
    func contains(_ id: String, in project: ACPProject) -> Bool { lists[project]?.ids.contains(id) == true }

    private func list(for project: ACPProject) -> ProjectList {
        if let list = lists[project] { return list }
        let list = ProjectList()
        lists[project] = list
        return list
    }

    private func update(_ item: ListedSession) -> ACPSession {
        if let row = byID[item.id] {
            row.update(title: item.title, cwd: item.cwd)
            return row
        }
        let row = ACPSession(id: item.id, title: item.title, cwd: item.cwd)
        byID[item.id] = row
        return row
    }

    func updateTitle(_ title: String, for id: String) {
        if let row = byID[id], row.title != title { row.title = title }
    }

    func replace(_ items: [ListedSession], ids: Set<String>, in project: ACPProject,
                 retaining loaded: Set<String>, complete: Bool) {
        let list = list(for: project)
        if list.rows.count >= items.count,
           zip(list.rows, items).allSatisfy({ $0.id == $1.id }),
           list.rows.dropFirst(items.count).allSatisfy({ loaded.contains($0.id) }) {
            for (row, item) in zip(list.rows, items) {
                row.update(title: item.title, cwd: item.cwd)
            }
        } else {
            let local = loaded.isEmpty ? [] : list.rows.filter { loaded.contains($0.id) && !ids.contains($0.id) }
            let newIDs = ids.union(local.map(\.id))
            let removed = list.ids.subtracting(newIDs)
            list.rows = items.map(update) + local
            list.ids = newIDs
            for id in removed where !lists.values.contains(where: { $0.ids.contains(id) }) {
                byID.removeValue(forKey: id)
            }
        }
        if list.complete != complete { list.complete = complete }
    }

    func insert(_ session: ACPSession, in project: ACPProject, atFront: Bool) {
        let row: ACPSession
        if let existing = byID[session.id] {
            row = existing
            if atFront { row.update(title: session.title, cwd: session.cwd) }
        } else {
            byID[session.id] = session
            row = session
        }
        let list = list(for: project)
        if !list.ids.insert(row.id).inserted {
            guard atFront, list.rows.first?.id != row.id else { return }
            list.rows.removeAll { $0.id == row.id }
        }
        if atFront { list.rows.insert(row, at: 0) } else { list.rows.append(row) }
    }

    func remove(_ id: String) {
        for list in lists.values where list.ids.contains(id) {
            list.ids.remove(id)
            list.rows.removeAll { $0.id == id }
        }
        byID.removeValue(forKey: id)
    }

    func removeAll() {
        lists.removeAll()
        byID.removeAll()
    }
}
