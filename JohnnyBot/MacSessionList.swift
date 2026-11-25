#if os(macOS)
import AppKit
import SwiftUI

/// AppKit owns scrolling, row reuse, keyboard navigation and disclosure. SwiftUI
/// provides the project snapshots and the existing window-level hover preview.
struct MacSessionList: View {
    let groups: [SidebarProjectGroup]
    let sectionExpanded: Bool
    let connected: Bool
    let selection: String?
    let client: ACPClient
    let activeProject: () -> ACPProject?
    let toggleSection: (Bool) -> Void
    let toggleProject: (ACPProject, Bool) -> Void
    let activateProject: (ACPProject) -> Void
    let select: (ACPSession, ACPProject) -> Void
    let loadProject: (ACPProject) async -> Void
    let menuForProject: (ACPProject) -> [SidebarMenuItem]
    let menuForSession: (ACPSession) -> [SidebarMenuItem]

    @State private var hover = Hover()

    private final class Hover {
        var last: Entry?
        var rect = CGRect.zero
        var changed: ((Entry?, CGRect) -> Void)?
        func show(_ entry: Entry?, at rect: CGRect = .zero) {
            guard entry !== last || (entry != nil && self.rect != rect) else { return }
            last = entry
            self.rect = rect
            changed?(entry, rect)
        }
    }

    private struct PreviewSource: View {
        let hover: Hover
        @State private var entry: Entry?
        @State private var rect = CGRect.zero

        var body: some View {
            Color.clear
                .allowsHitTesting(false)
                .onAppear {
                    hover.changed = { entry = $0; rect = $1 }
                }
                .onDisappear { hover.changed = nil }
                .anchorPreference(key: SessionPreviewAnchor.self, value: .bounds) { anchor in
                    entry.map { SessionPreviewAnchor.Preview(session: $0.session, anchor: anchor, row: rect) }
                }
        }
    }

    var body: some View {
        Outline(model: self).overlay { PreviewSource(hover: hover) }
    }

    private final class Entry: NSObject {
        let session: ACPSession
        let project: ACPProject
        init(_ session: ACPSession, in project: ACPProject) { self.session = session; self.project = project }
    }

    private final class Folder: NSObject {
        var group: SidebarProjectGroup
        // An outline item must be unique even when two projects list the same session.
        private var entries: [String: Entry] = [:]
        let empty = NSObject()
        init(_ group: SidebarProjectGroup) { self.group = group }

        func replace(_ next: SidebarProjectGroup) {
            group = next
            entries.removeAll(keepingCapacity: true)
        }

        func item(at index: Int) -> NSObject {
            guard !group.rows.isEmpty else { return empty }
            let session = group.rows[index]
            if let entry = entries[session.id] { return entry }
            let entry = Entry(session, in: group.project)
            entries[session.id] = entry
            return entry
        }

        func entry(with id: String) -> Entry? {
            if let existing = entries[id] { return existing }
            guard let index = group.rows.firstIndex(where: { $0.id == id }) else { return nil }
            return item(at: index) as? Entry
        }
    }

    private struct Outline: NSViewRepresentable {
        let model: MacSessionList
        func makeCoordinator() -> Coordinator { Coordinator(model: model) }

        func makeNSView(context: Context) -> NSScrollView {
            let coordinator = context.coordinator
            let scroll = NSScrollView()
            let table = coordinator.table
            let column = NSTableColumn(identifier: .init("sessions"))
            table.addTableColumn(column)
            table.outlineTableColumn = column
            table.headerView = nil
            table.style = .sourceList
            table.backgroundColor = .clear
            table.usesAutomaticRowHeights = false
            table.rowSizeStyle = .custom
            table.rowHeight = 30
            table.indentationPerLevel = 14
            table.allowsEmptySelection = true
            table.autosaveExpandedItems = false
            table.delegate = coordinator
            table.dataSource = coordinator
            table.owner = coordinator
            table.target = coordinator
            table.doubleAction = #selector(Coordinator.doubleClick)
            table.setAccessibilityLabel("项目与会话")
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.documentView = table
            NotificationCenter.default.addObserver(coordinator, selector: #selector(Coordinator.startScroll),
                name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            NotificationCenter.default.addObserver(coordinator, selector: #selector(Coordinator.endScroll),
                name: NSScrollView.didEndLiveScrollNotification, object: scroll)
            return scroll
        }

        func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.update(model) }
    }

    private final class Table: NSOutlineView {
        weak var owner: Coordinator?
        private var tracking: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseMoved(with event: NSEvent) {
            super.mouseMoved(with: event)
            owner?.preview(at: convert(event.locationInWindow, from: nil))
        }
        override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); owner?.clearHover() }
        override func scrollWheel(with event: NSEvent) { owner?.clearHover(); super.scrollWheel(with: event) }
        override func menu(for event: NSEvent) -> NSMenu? {
            let index = row(at: convert(event.locationInWindow, from: nil))
            return index >= 0 ? owner?.menu(for: item(atRow: index)) : nil
        }
    }

    private final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        let table = Table()
        var model: MacSessionList
        private let section = NSObject()
        private let placeholder = NSObject()
        private var folders: [Folder] = []
        private var applying = false
        private var initialized = false
        private var scrolling = false
        private var loads: [ACPProject: Task<Void, Never>] = [:]

        init(model: MacSessionList) { self.model = model }

        @objc func startScroll() { scrolling = true; clearHover() }
        @objc func endScroll() { scrolling = false; update(model) }

        func update(_ next: MacSessionList) {
            let connectionChanged = model.connected != next.connected
            model = next
            guard !scrolling else { return }
            applying = true
            defer { applying = false }
            let structureChanged = !folders.elementsEqual(next.groups) { $0.group.project == $1.project }
            let rowsChanged = structureChanged || !zip(folders, next.groups).allSatisfy {
                $0.group.revision == $1.revision && $0.group.expanded == $1.expanded
            }
            let top = table.visibleRect.minY
            var anchor: (Entry, CGFloat)?
            if rowsChanged, top > 0 {
                let row = table.row(at: CGPoint(x: table.bounds.midX, y: top))
                if row >= 0, let entry = table.item(atRow: row) as? Entry {
                    anchor = (entry, top - table.rect(ofRow: row).minY)
                }
            }
            if !initialized || structureChanged {
                let old = Dictionary(uniqueKeysWithValues: folders.map { ($0.group.project, $0) })
                folders = next.groups.map { group in
                    let folder = old[group.project] ?? Folder(group)
                    folder.replace(group)
                    return folder
                }
                clearHover()
                table.reloadData()
                initialized = true
            } else if connectionChanged && folders.isEmpty {
                table.reloadItem(placeholder)
            } else if rowsChanged {
                for (folder, group) in zip(folders, next.groups) {
                    if folder.group.revision != group.revision || folder.group.expanded != group.expanded {
                        folder.replace(group)
                        if table.isItemExpanded(folder) {
                            clearHover()
                            table.reloadItem(folder, reloadChildren: true)
                        }
                    }
                }
            }
            expand(section, next.sectionExpanded)
            if next.sectionExpanded {
                for folder in folders { expand(folder, folder.group.expanded) }
            }
            if let (entry, offset) = anchor,
               let folder = folders.first(where: { $0.group.project == entry.project && $0.group.expanded }),
               let newEntry = folder.entry(with: entry.session.id) {
                let row = table.row(forItem: newEntry)
                if row >= 0 {
                    table.scroll(CGPoint(x: 0, y: table.rect(ofRow: row).minY + offset))
                }
            }
            let current = table.item(atRow: table.selectedRow)
            if let id = next.selection {
                if (current as? Entry)?.session.id != id {
                    let entry = folders.lazy.filter { $0.group.expanded && next.client.directory.contains(id, in: $0.group.project) }
                        .compactMap { $0.entry(with: id) }.first
                    if let entry {
                        let row = table.row(forItem: entry)
                        if row >= 0 {
                            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                            table.scrollRowToVisible(row)
                        }
                    }
                }
            } else if current is Entry {
                table.deselectAll(nil)
            }
        }

        private func expand(_ item: NSObject, _ expanded: Bool) {
            guard expanded != table.isItemExpanded(item) else { return }
            if expanded { table.expandItem(item) } else { table.collapseItem(item) }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            if item == nil { return 1 }
            if let folder = item as? Folder { return max(1, folder.group.rows.count) }
            if item as? NSObject === section { return max(1, folders.count) }
            return 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if item == nil { return section }
            if let folder = item as? Folder { return folder.item(at: index) }
            return folders.isEmpty ? placeholder : folders[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            item is Folder || item as? NSObject === section
        }
        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item as? NSObject === section }
        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is Folder || item is Entry }
        func outlineViewItemDidExpand(_ notification: Notification) { disclosure(notification, expanded: true) }
        func outlineViewItemDidCollapse(_ notification: Notification) { disclosure(notification, expanded: false) }
        private func disclosure(_ notification: Notification, expanded: Bool) {
            guard !applying, let item = notification.userInfo?["NSObject"] as? NSObject else { return }
            if item === section { model.toggleSection(expanded) }
            if let folder = item as? Folder {
                model.toggleProject(folder.group.project, expanded)
                if expanded { loadIfNeeded(folder.group.project) }
            }
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !applying else { return }
            switch table.item(atRow: table.selectedRow) {
            case let entry as Entry: model.select(entry.session, entry.project)
            case let folder as Folder: model.activateProject(folder.group.project)
            default: break
            }
        }

        @objc func doubleClick() {
            if let folder = table.item(atRow: table.clickedRow) as? Folder {
                expand(folder, !table.isItemExpanded(folder))
            }
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("sidebarRow")
            let cell = (table.makeView(withIdentifier: identifier, owner: nil) as? Cell) ?? Cell()
            cell.identifier = identifier
            if let folder = item as? Folder {
                let project = folder.group.project
                cell.bind { [weak self] in
                    .init(project.name, icon: self?.model.activeProject() == project ? "folder.fill" : "folder")
                }
                if folder.group.expanded { loadIfNeeded(project) }
            } else if let entry = item as? Entry {
                let client = model.client, session = entry.session
                cell.bind {
                    let approval = client.permissions.contains { $0.sessionID == session.id }
                    return .init(session.title, icon: session.symbol(loaded: client.loaded.contains(session.id)), agent: session.agentName,
                                 approval: approval, responding: client.prompting.contains(session.id))
                }
            } else {
                let title = item as? NSObject === section ? "项目" : (item as? NSObject === placeholder ?
                        (model.connected ? "添加项目后在此显示" : "连接服务器后显示项目") : "暂无会话")
                cell.bind { .init(title, secondary: true) }
            }
            return cell
        }

        private func loadIfNeeded(_ project: ACPProject) {
            guard model.client.supportsSessionList, !model.client.directory.hasListed(project), loads[project] == nil else { return }
            loads[project] = Task { [weak self] in
                guard let self else { return }
                defer { loads.removeValue(forKey: project) }
                await model.loadProject(project)
            }
        }

        func outlineView(_ outlineView: NSOutlineView, objectValueFor tableColumn: NSTableColumn?, byItem item: Any?) -> Any? {
            if let entry = item as? Entry { return entry.session.title }
            if let folder = item as? Folder { return folder.group.project.name }
            return nil
        }

        func clearHover() { model.hover.show(nil) }
        func preview(at point: NSPoint) {
            let row = table.row(at: point)
            guard !scrolling, row >= 0, let entry = table.item(atRow: row) as? Entry,
                  let scroll = table.enclosingScrollView else { clearHover(); return }
            var rect = scroll.convert(table.rect(ofRow: row), from: table)
            if !scroll.isFlipped { rect.origin.y = scroll.bounds.maxY - rect.maxY }
            model.hover.show(entry, at: rect)
        }

        func menu(for item: Any?) -> NSMenu? {
            let items: [SidebarMenuItem]
            if let entry = item as? Entry { items = model.menuForSession(entry.session) }
            else if let folder = item as? Folder { items = model.menuForProject(folder.group.project) }
            else { return nil }
            clearHover()
            let menu = NSMenu()
            menu.autoenablesItems = false
            for action in items {
                let item = NSMenuItem(title: action.title, action: #selector(performMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = action
                item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
                item.isEnabled = !action.disabled
                if action.destructive, !action.disabled {
                    item.attributedTitle = NSAttributedString(string: action.title, attributes: [.foregroundColor: NSColor.systemRed])
                }
                menu.addItem(item)
            }
            return menu
        }
        @objc private func performMenu(_ sender: NSMenuItem) { (sender.representedObject as? SidebarMenuItem)?.perform() }
    }

    private final class Cell: NSTableCellView {
        private let label = NSTextField(labelWithString: "")
        private let symbol = NSImageView()
        private let badge = NSImageView()
        private var spinner: NSProgressIndicator?
        private var version: UInt = 0
        struct Appearance: Equatable {
            let title: String
            var icon: String?
            var agent: String?
            var secondary: Bool
            var approval: Bool
            var responding: Bool

            init(_ title: String, icon: String? = nil, agent: String? = nil, secondary: Bool = false,
                 approval: Bool = false, responding: Bool = false) {
                self.title = title
                self.icon = icon
                self.agent = agent
                self.secondary = secondary
                self.approval = approval
                self.responding = responding
            }
        }
        private var render: (() -> Appearance)?
        private var applied: Appearance?
        private static let icons = ["folder", "folder.fill", "bubble.left", "bubble.left.fill", "lock.shield", "c.circle", "c.circle.fill", "a.circle", "a.circle.fill", "p.circle", "p.circle.fill"]
            .reduce(into: [String: NSImage]()) { $0[$1] = NSImage(systemSymbolName: $1, accessibilityDescription: nil) }

        init() {
            super.init(frame: .zero)
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            addSubview(label)
            addSubview(symbol)
            addSubview(badge)
            textField = label
            imageView = symbol
        }
        required init?(coder: NSCoder) { nil }

        func bind(_ render: @escaping () -> Appearance) {
            version &+= 1
            self.render = render
            observe()
        }
        private func observe() {
            let generation = version
            let appearance = withObservationTracking { render?() } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, version == generation else { return }
                    observe()
                }
            }
            guard let appearance, appearance != applied else { return }
            applied = appearance
            toolTip = appearance.agent
            setAccessibilityValue(appearance.agent)
            display(appearance.title, icon: appearance.icon, secondary: appearance.secondary,
                    approval: appearance.approval, responding: appearance.responding)
        }
        override func prepareForReuse() { super.prepareForReuse(); version &+= 1; render = nil; applied = nil }
        private func display(_ title: String, icon: String? = nil, secondary: Bool = false, approval: Bool = false, responding: Bool = false) {
            label.stringValue = title
            label.font = secondary ? .preferredFont(forTextStyle: .subheadline) : .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            label.textColor = secondary ? .secondaryLabelColor : .labelColor
            symbol.image = icon.flatMap { Self.icons[$0] }
            symbol.contentTintColor = .controlAccentColor
            badge.image = approval ? Self.icons["lock.shield"] : nil
            badge.contentTintColor = .systemOrange
            if responding && !approval {
                if spinner == nil {
                    let indicator = NSProgressIndicator()
                    indicator.style = .spinning
                    indicator.controlSize = .small
                    indicator.isDisplayedWhenStopped = false
                    addSubview(indicator)
                    spinner = indicator
                }
                spinner?.startAnimation(nil)
            } else { spinner?.stopAnimation(nil) }
            setAccessibilityLabel(title)
            setAccessibilityHelp(approval ? "等待审批" : responding ? "正在回复" : nil)
            needsLayout = true
        }

        override func layout() {
            super.layout()
            let middle = bounds.midY
            symbol.frame = CGRect(x: 0, y: floor(middle - 9), width: 20, height: 18)
            let leading: CGFloat = symbol.image == nil ? 0 : 27
            let trailing: CGFloat = badge.image != nil || spinner?.isHidden == false ? 20 : 0
            let height = label.intrinsicContentSize.height
            label.frame = CGRect(x: leading, y: floor(middle - height / 2), width: max(0, bounds.width - leading - trailing), height: height)
            badge.frame = CGRect(x: bounds.width - 17, y: floor(middle - 8), width: 16, height: 16)
            spinner?.frame = badge.frame
        }
    }
}
#endif
