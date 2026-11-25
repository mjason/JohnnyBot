#if os(iOS)
import SwiftUI
import UIKit

// One system cell per visible row. SidebarProjectGroup ranges index the existing session arrays
// without flattening thousands of IDs or asking SwiftUI to measure offscreen rows.
struct PhoneSessionList: UIViewControllerRepresentable {
    let groups: [SidebarProjectGroup]
    let sectionExpanded: Bool
    let client: ACPClient
    let activeProject: () -> ACPProject?
    let toggleSection: () -> Void
    let toggleProject: (ACPProject, Bool) -> Void
    let loadProject: (ACPProject) async -> Void
    let select: (ACPSession, ACPProject) -> Void
    let menuForProject: (ACPProject) -> [SidebarMenuItem]
    let menuForSession: (ACPSession) -> [SidebarMenuItem]
    let refresh: () async -> Void

    func makeUIViewController(context: Context) -> Controller { Controller(model: self) }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.update(self)
    }

    final class Controller: UITableViewController {
        private var model: PhoneSessionList
        private var displayed: [SidebarProjectGroup] = []
        private var ends: [Int] = []
        private var sectionOpen = false
        private let heading = UIButton(type: .system)
        private var pendingReload = false
        private var loads: [ACPProject: Task<Void, Never>] = [:]

        init(model: PhoneSessionList) {
            self.model = model
            super.init(style: .insetGrouped)
        }
        required init?(coder: NSCoder) { nil }

        override func viewDidLoad() {
            super.viewDidLoad()
            tableView.register(Cell.self, forCellReuseIdentifier: "row")
            tableView.estimatedRowHeight = 0
            updateRowHeight()
            tableView.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { [weak self] (_: UITableView, _) in
                self?.updateRowHeight()
            }
            var config = UIButton.Configuration.plain()
            config.title = "项目"
            config.imagePlacement = .trailing
            config.baseForegroundColor = .secondaryLabel
            config.titleTextAttributesTransformer = .init { attrs in
                var attrs = attrs
                attrs.font = UIFont.preferredFont(forTextStyle: .subheadline)
                return attrs
            }
            heading.configuration = config
            heading.contentHorizontalAlignment = .fill
            heading.accessibilityTraits.insert(.header)
            heading.addAction(UIAction { [weak self] _ in self?.model.toggleSection() }, for: .touchUpInside)
            refreshControl = UIRefreshControl()
            refreshControl?.addAction(UIAction { [weak self] _ in
                Task { [weak self] in
                    guard let self else { return }
                    await model.refresh()
                    refreshControl?.endRefreshing()
                }
            }, for: .valueChanged)
            applyModel()
        }

        private func updateRowHeight() {
            let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: tableView.traitCollection)
            tableView.rowHeight = max(44, ceil(font.lineHeight) + 20)
        }

        func update(_ next: PhoneSessionList) {
            model = next
            guard isViewLoaded else { return }
            let sameGroups = displayed.count == next.groups.count && zip(displayed, next.groups).allSatisfy {
                $0.project == $1.project && $0.expanded == $1.expanded && $0.revision == $1.revision
            }
            guard !sameGroups || sectionOpen != next.sectionExpanded else { pendingReload = false; return }
            if tableView.isDragging || tableView.isDecelerating {
                pendingReload = true
            } else {
                applyModel()
            }
        }

        private func applyModel() {
            pendingReload = false
            // Pagination in an earlier project can move every visible row.
            // Keep the same session and the same partially scrolled line in view.
            let top = tableView.contentOffset.y + tableView.adjustedContentInset.top
            var anchor: (project: ACPProject, session: String?, offset: CGFloat)?
            if top > 0, let index = tableView.indexPathsForVisibleRows?.first,
               let (group, offset) = row(index.row) {
                let session = offset > 0 && !group.rows.isEmpty ? group.rows[offset - 1].id : nil
                anchor = (group.project, session, top - tableView.rectForRow(at: index).minY)
            }
            displayed = model.groups
            sectionOpen = model.sectionExpanded
            var end = 0
            ends = displayed.map { group in end += group.visibleRowCount; return end }
            heading.configuration?.image = UIImage(systemName: sectionOpen ? "chevron.down" : "chevron.right")
            heading.accessibilityValue = sectionOpen ? "已展开" : "已折叠"
            tableView.reloadData()
            if sectionOpen, let anchor, let index = displayed.firstIndex(where: { $0.project == anchor.project }) {
                tableView.layoutIfNeeded()
                let group = displayed[index]
                let first = index == 0 ? 0 : ends[index - 1]
                var target = first
                if group.expanded, let id = anchor.session,
                   let offset = group.rows.firstIndex(where: { $0.id == id }) {
                    target += offset + 1
                }
                let y = tableView.rectForRow(at: IndexPath(row: target, section: 0)).minY + anchor.offset
                let inset = tableView.adjustedContentInset
                let limit = max(-inset.top, tableView.contentSize.height - tableView.bounds.height + inset.bottom)
                tableView.contentOffset.y = min(limit, max(-inset.top, y - inset.top))
            }
        }

        override func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            if pendingReload { applyModel() }
        }

        override func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate && pendingReload { applyModel() }
        }

        override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            sectionOpen ? ends.last ?? 1 : 0
        }

        private func row(_ index: Int) -> (SidebarProjectGroup, Int)? {
            var lo = 0, hi = ends.count
            while lo < hi {
                let mid = lo + (hi - lo) / 2
                if index < ends[mid] { hi = mid } else { lo = mid + 1 }
            }
            guard lo < displayed.count else { return nil }
            return (displayed[lo], index - (lo == 0 ? 0 : ends[lo - 1]))
        }

        override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? { heading }
        override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
            max(44, tableView.rowHeight)
        }

        override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath) as! Cell
            if let (group, offset) = row(indexPath.row) {
                if offset == 0 {
                    cell.render = { [weak self] cell in
                        let active = self?.model.activeProject() == group.project
                        cell.configure(title: group.project.name, symbol: active ? "folder.fill" : "folder",
                                       accessory: group.expanded ? .expanded : .collapsed)
                    }
                } else if group.rows.isEmpty {
                    cell.render = { cell in cell.configure(title: "暂无会话", accessory: .empty) }
                } else {
                    let session = group.rows[offset - 1]
                    let client = model.client
                    cell.render = { cell in
                        let approval = client.permissions.contains { $0.sessionID == session.id }
                        cell.configure(title: session.title, symbol: client.loaded.contains(session.id) ? "bubble.left.fill" : "bubble.left",
                                       accessory: approval ? .permission : client.prompting.contains(session.id) ? .responding : .session)
                    }
                }
            } else {
                cell.render = { cell in cell.configure(title: "添加项目后在此显示", accessory: .empty) }
            }
            return cell
        }

        override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
            guard let (group, offset) = row(indexPath.row), offset == 0, group.expanded,
                  model.client.supportsSessionList, !model.client.directory.hasListed(group.project),
                  loads[group.project] == nil else { return }
            loads[group.project] = Task { [weak self] in
                guard let self else { return }
                defer { loads.removeValue(forKey: group.project) }
                await model.loadProject(group.project)
            }
        }

        override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
            tableView.deselectRow(at: indexPath, animated: true)
            guard let (group, offset) = row(indexPath.row) else { return }
            if offset == 0 { model.toggleProject(group.project, !group.expanded) }
            else if !group.rows.isEmpty { model.select(group.rows[offset - 1], group.project) }
        }

        override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
                                point: CGPoint) -> UIContextMenuConfiguration? {
            guard let (group, offset) = row(indexPath.row), offset == 0 || !group.rows.isEmpty else { return nil }
            let items = offset == 0 ? model.menuForProject(group.project) : model.menuForSession(group.rows[offset - 1])
            return UIContextMenuConfiguration(actionProvider: { _ in
                UIMenu(children: items.map { item in
                    var attributes: UIMenuElement.Attributes = item.destructive ? [.destructive] : []
                    if item.disabled { attributes.insert(.disabled) }
                    return UIAction(title: item.title, image: UIImage(systemName: item.symbol), attributes: attributes) { _ in item.perform() }
                })
            })
        }
    }

    private final class Cell: UITableViewCell {
        enum Accessory { case expanded, collapsed, session, responding, permission, empty }
        private struct Appearance: Equatable {
            let title: String
            let symbol: String?
            let accessory: Accessory
            let textSize: UIContentSizeCategory
        }
        private var applied: Appearance?
        var render: ((Cell) -> Void)? { didSet { setNeedsUpdateProperties() } }
        private let indicator = UIActivityIndicatorView(style: .medium)
        private let glyph = UIImageView()

        // UIKit tracks observable reads here, including a single session's title.
        override func updateProperties() {
            super.updateProperties()
            render?(self)
        }

        func configure(title: String, symbol: String? = nil, accessory: Accessory) {
            let appearance = Appearance(title: title, symbol: symbol, accessory: accessory,
                                        textSize: traitCollection.preferredContentSizeCategory)
            // UIKit can schedule updateProperties again after assigning a custom accessory.
            guard applied != appearance else { return }
            applied = appearance
            let folder = accessory == .expanded || accessory == .collapsed
            var content = defaultContentConfiguration()
            content.text = title
            content.textProperties.numberOfLines = 1
            content.textProperties.font = .preferredFont(forTextStyle: accessory == .empty ? .callout : .body, compatibleWith: traitCollection)
            content.textProperties.color = accessory == .empty ? .secondaryLabel : .label
            content.image = symbol.flatMap { UIImage(systemName: $0) }
            content.imageProperties.tintColor = .tintColor
            content.directionalLayoutMargins.leading = folder ? 16 : 38
            content.directionalLayoutMargins.top = 6
            content.directionalLayoutMargins.bottom = 6
            contentConfiguration = content
            if accessory != .responding, indicator.isAnimating { indicator.stopAnimating() }
            let type: UITableViewCell.AccessoryType = accessory == .session ? .disclosureIndicator : .none
            if accessoryType != type { accessoryType = type }
            switch accessory {
            case .session, .empty:
                if accessoryView != nil { accessoryView = nil }
            case .responding:
                if !indicator.isAnimating { indicator.startAnimating() }
                if accessoryView !== indicator { accessoryView = indicator }
            case .expanded, .collapsed, .permission:
                let name = accessory == .permission ? "lock.shield" : accessory == .expanded ? "chevron.down" : "chevron.right"
                glyph.image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption1))
                glyph.tintColor = accessory == .permission ? .systemOrange : .secondaryLabel
                glyph.sizeToFit()
                if accessoryView !== glyph { accessoryView = glyph }
            }
            accessibilityLabel = title
            accessibilityTraits = accessory == .empty ? .staticText : .button
            switch accessory {
            case .expanded: accessibilityValue = "已展开"
            case .collapsed: accessibilityValue = "已折叠"
            case .permission: accessibilityValue = "等待审批"
            case .responding: accessibilityValue = "正在回复"
            default: accessibilityValue = nil
            }
            selectionStyle = accessory == .empty ? .none : .default
        }
    }
}
#endif
