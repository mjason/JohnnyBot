import SwiftUI

struct TranscriptActivity: View {
    let entries: ArraySlice<ACPEntry>
    let isAwaitingPermission: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let activity = activity
        HStack(spacing: 7) {
            Image(systemName: activity.symbol)
                .font(.callout)
                .foregroundStyle(isAwaitingPermission ? Color.orange : Color.secondary)
                .frame(width: 18)
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion && scenePhase == .active && !isAwaitingPermission)
                .accessibilityHidden(true)
            Text(activity.title)
                .fontWeight(.medium)
                .layoutPriority(1)
            if let detail = activity.detail {
                Text(detail)
                    .lineLimit(1)
                }
        }
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var activity: Activity {
        if isAwaitingPermission {
            return Activity(title: "等待审批", symbol: "lock.shield")
        }
        if let call = entries.last(where: { $0.kind == .tool && $0.toolStatus == "in_progress" }) {
            let tool = ToolPresentation(call)
            return Activity(title: "正在\(tool.action)", symbol: tool.symbol, detail: call.text.isEmpty ? nil : call.text)
        }
        if let call = entries.last(where: { $0.kind == .tool && $0.toolStatus == "pending" }) {
            return Activity(title: "工具等待运行", symbol: "clock", detail: call.text.isEmpty ? nil : call.text)
        }
        switch entries.last?.kind {
        case .agent: return Activity(title: "正在输出回复", symbol: "text.bubble")
        case .thought: return Activity(title: "正在思考", symbol: "sparkles")
        case nil: return Activity(title: "等待 Agent 回复", symbol: "ellipsis")
        default: return Activity(title: "Agent 正在处理", symbol: "sparkles")
        }
    }

    private struct Activity: Equatable {
        let title: String
        let symbol: String
        var detail: String? = nil
    }
}

struct TranscriptToolGroup: View {
    let calls: [ACPEntry]
    let isLive: Bool

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if calls.count == 1, let call = calls.first {
                    ToolDetails(call: call)
                } else {
                    ForEach(calls) { call in
                        DisclosureGroup {
                            ToolDetails(call: call)
                                .padding(.top, 4)
                        } label: {
                            toolHeading(call)
                        }
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            if calls.count == 1, let call = calls.first {
                toolHeading(call)
            } else {
                HStack(spacing: 8) {
                    Label("\(calls.count) 项工具调用", systemImage: "wrench.and.screwdriver")
                        .fontWeight(.medium)
                        .layoutPriority(1)
                    Text(actions)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    groupStatus
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
    }

    private var actions: String {
        var shown: Set<String> = []
        return calls.map { ToolPresentation($0).action }
            .filter { shown.insert($0).inserted }
            .joined(separator: " · ")
    }

    @ViewBuilder
    private var groupStatus: some View {
        let active = isLive ? calls.count { $0.toolStatus == "in_progress" || $0.toolStatus == "pending" } : 0
        let failed = calls.count { $0.toolStatus == "failed" }
        if active > 0 {
            Text("\(active) 项处理中").foregroundStyle(Color.accentColor)
        } else if failed > 0 {
            Text("\(failed) 项失败").foregroundStyle(.red)
        } else if calls.allSatisfy({ $0.toolStatus == "completed" }) {
            Text("已完成")
        }
    }

    private func toolHeading(_ call: ACPEntry) -> some View {
        let tool = ToolPresentation(call)
        return HStack(spacing: 8) {
            Label(tool.title, systemImage: tool.symbol)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let value = call.toolStatus {
                let status = TranscriptStatus(value)
                if !isLive && (value == "pending" || value == "in_progress") {
                    Text("未报告结果").font(.caption)
                } else {
                    Text(status.label)
                        .font(.caption)
                        .foregroundStyle(value == "completed" ? Color.secondary : status.tint)
                }
            }
        }
    }
}

private struct ToolDetails: View {
    let call: ACPEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !call.text.isEmpty {
                Text(call.text)
                    .textSelection(.enabled)
            }
            ForEach(call.toolLocations, id: \.self) { location in
                let label = location.line.map { "\(location.path):\($0)" } ?? location.path
                Label(label, systemImage: "doc.text")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            ForEach(Array(call.toolContent.enumerated()), id: \.offset) { _, content in
                switch content {
                case let .text(text):
                    output(text)
                case let .diff(path, oldText, newText):
                    VStack(alignment: .leading, spacing: 6) {
                        if !call.toolLocations.contains(where: { $0.path == path }) {
                            Label(path, systemImage: "doc.text")
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                        if let oldText {
                            DisclosureGroup("修改前") { output(oldText) }
                        }
                        if let newText {
                            DisclosureGroup("修改后") { output(newText) }
                        }
                    }
                case let .terminal(id):
                    Label("终端 \(id)", systemImage: "terminal")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            if call.text.isEmpty, call.toolLocations.isEmpty, call.toolContent.isEmpty {
                Text("Agent 暂未提供详情").font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func output(_ text: String) -> some View {
        Text(text)
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct ToolPresentation {
    let title: String
    let action: String
    let symbol: String

    init(_ entry: ACPEntry) {
        (action, symbol) = switch entry.toolKind {
        case "read": ("读取文件", "doc.text")
        case "edit": ("编辑文件", "square.and.pencil")
        case "delete": ("删除文件", "trash")
        case "move": ("移动文件", "arrow.right.doc.on.clipboard")
        case "search": ("搜索", "magnifyingglass")
        case "execute": ("运行命令", "terminal")
        case "think": ("思考", "sparkles")
        case "fetch": ("获取数据", "network")
        case "switch_mode": ("切换模式", "slider.horizontal.3")
        default: ("调用工具", "wrench")
        }
        title = entry.text.isEmpty ? action : entry.text
    }
}
