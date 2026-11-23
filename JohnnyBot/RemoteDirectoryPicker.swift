import SwiftUI
#if os(macOS)
import AppKit
#endif

struct RemoteDirectoryPicker: View {
    private enum Navigation: Equatable {
        case home
        case visit(String?)
        case back(String)
        case forward(String)

        var path: String? {
            switch self {
            case .home: nil
            case let .visit(path): path
            case let .back(path), let .forward(path): path
            }
        }
    }

    private struct Request: Equatable {
        let navigation: Navigation
        let id = UUID()
    }

    let client: ACPClient
    let projects: [ACPProject]
    let defaultPath: String?
    let select: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var request = Request(navigation: .home)
    @State private var listing: ACPDirectoryListing?
    @State private var backHistory: [String] = []
    @State private var forwardHistory: [String] = []
    @State private var selection: String?
    @State private var search = ""
    @State private var loading = true
    @State private var failure: String?
#if os(macOS)
    @State private var sortOrder = [KeyPathComparator(\ACPDirectoryListing.Directory.name, comparator: .localizedStandard)]
#endif

    private var visibleDirectories: [ACPDirectoryListing.Directory] {
        let directories = listing?.directories ?? []
        guard !search.isEmpty else { return directories }
        return directories.filter { $0.name.localizedStandardContains(search) }
    }

    private var chosenPath: String? { selection ?? listing?.path }
    private var homePath: String? { client.projectHomeDirectory(defaultPath: defaultPath) }

    var body: some View {
#if os(macOS)
        HStack(spacing: 0) {
            locations
                .frame(width: 178)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 820, height: 460)
        .task(id: request) { await readDirectory() }
#else
        content.task(id: request) { await readDirectory() }
#endif
    }

    private var content: some View {
        VStack(spacing: 0) {
            navigationBar
            Divider()
            directoryList
            if let failure {
                Divider()
                HStack {
                    Text(failure).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("重试") { navigate(request.navigation) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            Divider()
            footer
        }
    }

#if os(macOS)
    private var locations: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("远程位置")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                    .padding(.bottom, 4)
                if let homePath {
                    location("用户目录", icon: "house", path: homePath)
                }
                if let defaultPath, defaultPath != homePath {
                    location("默认目录", icon: "server.rack", path: defaultPath)
                }
                location("根目录", icon: "externaldrive", path: "/")
                let otherProjects = projects.filter {
                    $0.path != nil && $0.path != homePath && $0.path != defaultPath && $0.path != "/"
                }
                if !otherProjects.isEmpty {
                    Text("项目")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                    ForEach(otherProjects) { project in
                        location(project.name, icon: "folder", path: project.path)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 18)
        }
    }

    private func location(_ title: String, icon: String, path: String?) -> some View {
        let current = listing != nil && listing?.path == path
        return Button {
            navigate(.visit(path))
        } label: {
            Label(title, systemImage: icon)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(current ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(loading)
        .help(path ?? title)
    }
#endif

    private var navigationBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("添加远程项目").font(.headline)
            HStack(spacing: 9) {
                Button {
                    if let path = backHistory.last { navigate(.back(path)) }
                } label: {
                    Label("后退", systemImage: "chevron.left").labelStyle(.iconOnly)
                }
                .help("后退")
                .disabled(loading || backHistory.isEmpty)
                Button {
                    if let path = forwardHistory.last { navigate(.forward(path)) }
                } label: {
                    Label("前进", systemImage: "chevron.right").labelStyle(.iconOnly)
                }
                .help("前进")
                .disabled(loading || forwardHistory.isEmpty)
                Button {
                    if let path = listing?.parent { navigate(.visit(path)) }
                } label: {
                    Label("上一级目录", systemImage: "arrow.up").labelStyle(.iconOnly)
                }
                .help("上一级目录")
                .disabled(loading || listing?.parent == nil)
#if os(macOS)
                locationMenu
#endif
                Spacer(minLength: 4)
                if loading { ProgressView().controlSize(.small) }
                TextField("搜索当前目录", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 178)
                    .onChange(of: search) { _, _ in selection = nil }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.bar)
    }

#if os(macOS)
    private var locationMenu: some View {
        Menu {
            if let listing {
                let components = listing.path.split(separator: "/")
                ForEach((0...components.count).reversed(), id: \.self) { count in
                    let path = "/" + components.prefix(count).joined(separator: "/")
                    Button(ACPProject(path: path).name) { navigate(.visit(path)) }
                }
            }
        } label: {
            Label(ACPProject(path: listing?.path).name, systemImage: "folder.fill")
                .lineLimit(1)
        }
        .frame(minWidth: 125, maxWidth: 230)
        .disabled(loading || listing == nil)
        .help(listing?.path ?? "当前目录")
    }
#endif

    @ViewBuilder
    private var directoryList: some View {
#if os(macOS)
        Table(visibleDirectories.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
            TableColumn("名称", value: \.name) { directory in
                HStack(spacing: 7) {
                    Image(nsImage: NSImage(named: NSImage.folderName) ?? NSImage())
                        .resizable()
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                    Text(directory.name).lineLimit(1)
                }
            }
            .width(min: 130, ideal: 210)
            TableColumn("远程路径", value: \.path) { directory in
                Text(directory.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .width(min: 160, ideal: 360)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { ids in
            if let path = ids.first {
                Button("打开文件夹") { navigate(.visit(path)) }
            }
        } primaryAction: { ids in
            if let path = ids.first { navigate(.visit(path)) }
        }
#else
        List(visibleDirectories) { directory in
            Button {
                navigate(.visit(directory.path))
            } label: {
                Label(directory.name, systemImage: "folder")
            }
            .disabled(loading)
        }
        .listStyle(.plain)
#endif
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(chosenPath ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Button("取消", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("选取项目") {
                guard let chosenPath else { return }
                dismiss()
                select(chosenPath)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(loading || chosenPath == nil || failure != nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func navigate(_ navigation: Navigation) {
        loading = true
        selection = nil
        search = ""
        failure = nil
        request = Request(navigation: navigation)
    }

    private func readDirectory() async {
        let navigation = request.navigation
        let path = navigation == .home ? homePath ?? defaultPath : navigation.path
        do {
            let result: ACPDirectoryListing
            do {
                result = try await client.listDirectories(path: path)
            } catch let error as ACPFailure where navigation == .home && path != defaultPath && error.code == -32602 {
                try Task.checkCancellation()
                result = try await client.listDirectories(path: defaultPath)
            }
            try Task.checkCancellation()
            if let previous = listing?.path, previous != result.path {
                switch navigation {
                case .home, .visit:
                    backHistory.append(previous)
                    forwardHistory.removeAll()
                case .back:
                    _ = backHistory.popLast()
                    forwardHistory.append(previous)
                case .forward:
                    _ = forwardHistory.popLast()
                    backHistory.append(previous)
                }
            }
            selection = nil
            listing = result
        } catch {
            guard !Task.isCancelled else { return }
            failure = error.localizedDescription
        }
        loading = false
    }
}
