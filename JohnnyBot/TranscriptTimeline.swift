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
        private var current: TranscriptTurn?
        @ObservationIgnored private var historicalEntries: ArraySlice<ACPEntry>?

        var turn: TranscriptTurn {
            get {
                if let current { return current }
                if let historicalTurn { return historicalTurn }
                let value = TranscriptTimeline.turn(historicalEntries!)
                historicalTurn = value
                historicalEntries = nil
                return value
            }
            set {
                current = newValue
                historicalTurn = nil
                historicalEntries = nil
            }
        }

        // Multiple historical rows share the immutable array from the initial replay.
        // Only a row that enters the transcript window builds its grouped content.
        @ObservationIgnored private var historicalTurn: TranscriptTurn?

        init(_ turn: TranscriptTurn, index: Int) {
            id = turn.id
            self.index = index
            current = turn
        }

        init(history: ArraySlice<ACPEntry>, index: Int) {
            id = history.first!.id
            self.index = index
            historicalEntries = history
        }
    }

    private(set) var rows: [Row] = []
    @ObservationIgnored private var rowForOffset: [Int] = []
    @ObservationIgnored private var starts: [Int] = []

    private(set) var entryCount = 0

    func replace(_ history: [ACPEntry]) {
        starts = history.indices.filter { $0 == 0 || history[$0].kind == .user }
        var offsets: [Int] = []
        offsets.reserveCapacity(history.count)
        rows = starts.indices.map { index in
            let end = index + 1 < starts.count ? starts[index + 1] : history.count
            let range = starts[index]..<end
            offsets.append(contentsOf: repeatElement(index, count: range.count))
            return Row(history: history[range], index: index)
        }
        rowForOffset = offsets
        entryCount = history.count
    }

    func update(_ history: [ACPEntry], at offset: Int) {
        defer { entryCount = history.count }
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
        defer { entryCount = history.count }
        if rows.isEmpty { replace(history); return }
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
