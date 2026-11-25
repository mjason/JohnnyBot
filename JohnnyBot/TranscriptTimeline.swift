import Foundation
import Observation

struct TranscriptTurn: Identifiable {
    let id: UUID
    let user: ACPEntry?
    let entries: ArraySlice<ACPEntry>
    let replyTiming: ACPReplyTiming?
    let responseStart: Int

    fileprivate init?(user: ACPEntry?, entries: ArraySlice<ACPEntry>) {
        guard let id = user?.id ?? entries.first?.id else { return nil }
        self.id = id
        self.user = user
        self.entries = Array(entries)[...]
        replyTiming = entries.reversed().lazy.compactMap(\.replyTiming).first ?? user?.replyTiming
        responseStart = Self.startOfResponse(in: self.entries)
    }

    static func group(_ entries: [ACPEntry]) -> [Self] {
        var turns: [Self] = []
        var user: ACPEntry?
        var start = entries.startIndex

        for index in entries.indices where entries[index].kind == .user {
            if let turn = Self(user: user, entries: entries[start..<index]) { turns.append(turn) }
            user = entries[index]
            start = index + 1
        }
        if let turn = Self(user: user, entries: entries[start...]) { turns.append(turn) }
        return turns
    }

    private static func startOfResponse(in entries: ArraySlice<ACPEntry>) -> Int {
        guard let lastWork = entries.lastIndex(where: {
            $0.kind == .tool || $0.kind == .thought || $0.kind == .plan || $0.phase == .commentary
        }) else { return entries.startIndex }

        if let finalAnswer = entries.firstIndex(where: { $0.phase == .finalAnswer }) {
            return finalAnswer
        }

        let afterWork = entries.index(after: lastWork)
        return entries[afterWork...].lastIndex(where: { $0.kind == .agent }) ?? afterWork
    }
}

/// Stable rows let a streaming chunk refresh just the affected turn. Each turn
/// owns its small slice so the flat ACP history remains uniquely mutable.
@MainActor @Observable
final class TranscriptTimeline {
    @Observable final class Row: Identifiable {
        let id: UUID
        let index: Int
        var turn: TranscriptTurn
        init(_ turn: TranscriptTurn, index: Int) { id = turn.id; self.index = index; self.turn = turn }
    }

    private(set) var rows: [Row] = []
    @ObservationIgnored private var rowForOffset: [Int] = []
    @ObservationIgnored private var starts: [Int] = []

    func replace(_ history: [ACPEntry]) {
        var newRows: [Row] = []
        var newStarts: [Int] = []
        var offsets: [Int] = []
        offsets.reserveCapacity(history.count)
        for turn in TranscriptTurn.group(history) {
            newStarts.append(offsets.count)
            let count = turn.entries.count + (turn.user == nil ? 0 : 1)
            offsets.append(contentsOf: repeatElement(newRows.count, count: count))
            newRows.append(Row(turn, index: newRows.count))
        }
        starts = newStarts
        rowForOffset = offsets
        rows = newRows
    }

    func update(_ history: [ACPEntry], at offset: Int) {
        if offset == rowForOffset.count && history.count == offset + 1 {
            if rows.isEmpty || history[offset].kind == .user {
                starts.append(offset)
                rowForOffset.append(rows.count)
                rows.append(Row(Self.turn(history[offset...]), index: rows.count))
                return
            }
            rowForOffset.append(rows.count - 1)
        }
        guard history.count == rowForOffset.count, rowForOffset.indices.contains(offset) else {
            replace(history)
            return
        }
        let index = rowForOffset[offset]
        refresh(index, from: history)
    }

    func update(_ history: [ACPEntry], changedOffsets: Set<Int>) {
        if changedOffsets.count == 1, let offset = changedOffsets.first {
            update(history, at: offset)
            return
        }
        guard history.count >= rowForOffset.count else { replace(history); return }
        let existingRows = rows.count
        var changedRows = Set(changedOffsets.compactMap { rowForOffset.indices.contains($0) ? rowForOffset[$0] : nil })
        for offset in rowForOffset.count..<history.count {
            if starts.isEmpty || history[offset].kind == .user { starts.append(offset) }
            let index = starts.count - 1
            changedRows.insert(index)
            rowForOffset.append(index)
        }
        for index in changedRows where index < existingRows { refresh(index, from: history) }
        for index in existingRows..<starts.count {
            rows.append(Row(snapshot(index, from: history), index: index))
        }
    }

    private func refresh(_ index: Int, from history: [ACPEntry]) {
        rows[index].turn = snapshot(index, from: history)
    }

    private func snapshot(_ index: Int, from history: [ACPEntry]) -> TranscriptTurn {
        let end = index + 1 < starts.count ? starts[index + 1] : history.count
        return Self.turn(history[starts[index]..<end])
    }

    private static func turn(_ entries: ArraySlice<ACPEntry>) -> TranscriptTurn {
        let user = entries.first.flatMap { $0.kind == .user ? $0 : nil }
        let body = user == nil ? entries : entries.dropFirst()
        // All callers supply a non-empty range.
        return TranscriptTurn(user: user, entries: body)!
    }
}
