import SwiftUI
import UIKit
import AVKit
import UniformTypeIdentifiers

// MARK: - 根

@MainActor
struct ContentView: View {
    @StateObject private var store = VfsStore()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showAddMount = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(store: store, showAddMount: $showAddMount)
        } content: {
            BrowserColumn(store: store)
        } detail: {
            DetailColumn(store: store)
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showAddMount) {
            AddMountSheet(store: store)
        }
        .alert(
            "出错了",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.dismissError() } }
            )
        ) {
            Button("好", role: .cancel) { store.dismissError() }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .alert(
            "提示",
            isPresented: Binding(
                get: { store.notice != nil },
                set: { if !$0 { store.dismissNotice() } }
            )
        ) {
            Button("好", role: .cancel) { store.dismissNotice() }
        } message: {
            Text(store.notice ?? "")
        }
    }
}

// MARK: - 侧栏：位置

@MainActor
private struct SidebarView: View {
    @ObservedObject var store: VfsStore
    @Binding var showAddMount: Bool

    private var selection: Binding<SidebarSelection?> {
        Binding(
            get: { store.sidebar },
            set: { value in
                if let value { store.sidebar = value }
            }
        )
    }

    var body: some View {
        List(selection: selection) {
            Section("设备") {
                Label("应用存储", systemImage: "internaldrive")
                    .tag(SidebarSelection.appStorage)
            }

            Section("智能") {
                Label("最近打开", systemImage: "clock")
                    .tag(SidebarSelection.recent)
                Label("收藏", systemImage: "star")
                    .tag(SidebarSelection.favorites)
            }

            Section("网络存储") {
                ForEach(store.mounts) { mount in
                    Label(mount.label, systemImage: Self.icon(for: mount.scheme))
                        .tag(SidebarSelection.mount(mount.rootId))
                        .contextMenu {
                            Button(role: .destructive) {
                                store.removeMount(mount)
                            } label: {
                                Label("断开连接", systemImage: "eject")
                            }
                        }
                }
                Button {
                    showAddMount = true
                } label: {
                    Label("添加网络存储…", systemImage: "plus.circle")
                }
            }

            Section("传输") {
                Label("传输中心", systemImage: "arrow.up.arrow.down")
                    .tag(SidebarSelection.transfers)
                    .badge(
                        store.activeTransferCount > 0
                            ? Text("\(store.activeTransferCount)")
                            : nil
                    )
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Super Files")
        .onChange(of: store.sidebar) { selection in
            store.activate(selection)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("v\(store.version)")
                Spacer()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.thinMaterial)
        }
    }

    private static func icon(for scheme: String) -> String {
        switch scheme {
        case "smb": return "externaldrive"
        case "sftp": return "terminal"
        default: return "cloud"
        }
    }
}

// MARK: - 中栏：文件列表 / 最近 / 收藏 / 传输

private struct TransferRequest: Identifiable {
    let id = UUID()
    let sources: [String]
    let move: Bool
}

private struct CompactDetail: Identifiable {
    var id: String { entry.id }
    let entry: Entry
}

@MainActor
private struct BrowserColumn: View {
    @ObservedObject var store: VfsStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var compactDetail: CompactDetail?
    @State private var showImporter = false
    @State private var showNewFolder = false
    @State private var newFolderName = ""

    @State private var renameTarget: Entry?
    @State private var renameName = ""

    @State private var deleteTarget: Entry?

    @State private var transferRequest: TransferRequest?
    @State private var shareItem: SharePayload?
    @State private var quickLook: QuickLookPayload?

    var body: some View {
        Group {
            switch store.listMode {
            case .browser:
                browserList
            case .recent:
                recentList
            case .favorites:
                favoritesList
            case .transfers:
                transfersList
            }
        }
        .navigationTitle(store.contentTitle)
        .toolbar { toolbar }
        .searchable(
            text: $store.query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "搜索文件名"
        )
        .onSubmit(of: .search) { store.applySearch() }
        .onChange(of: store.query) { value in
            if value.isEmpty { store.cancelSearch() }
        }
        .task(id: store.query) {
            await store.searchAfterDebounce()
        }
        .sheet(item: $transferRequest) { request in
            DestinationPicker(store: store) { destination in
                store.startTransfer(
                    sources: request.sources,
                    destDir: destination,
                    move: request.move
                )
                transferRequest = nil
            }
        }
        .sheet(item: $shareItem) { payload in
            ShareSheet(items: [payload.url])
        }
        .sheet(item: $quickLook) { payload in
            QuickLookSheet(url: payload.url)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                store.importFiles(urls)
            }
        }
        .sheet(item: $compactDetail) { selection in
            NavigationStack {
                EntryDetailView(store: store, entry: selection.entry)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { compactDetail = nil }
                        }
                    }
            }
        }
        .alert("新建文件夹", isPresented: $showNewFolder) {
            TextField("名称", text: $newFolderName)
            Button("创建") {
                store.createFolder(named: newFolderName)
                newFolderName = ""
            }
            Button("取消", role: .cancel) { newFolderName = "" }
        }
        .alert(
            "重命名",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )
        ) {
            TextField("名称", text: $renameName)
            Button("确定") {
                if let target = renameTarget {
                    store.rename(target, to: renameName)
                }
                renameTarget = nil
            }
            Button("取消", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog(
            "删除「\(deleteTarget?.name ?? "")」？",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let target = deleteTarget { store.delete(target) }
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        }
    }

    // MARK: 列表

    private var browserList: some View {
        List {
            if let cachedAt = store.offlineCacheMs {
                Section {
                    Label(
                        "网络不可用 · 展示离线缓存（更新于 \(Fmt.date.string(from: Date(timeIntervalSince1970: TimeInterval(cachedAt) / 1000)))）",
                        systemImage: "icloud.slash"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if store.entries.isEmpty && !store.isLoading {
                EmptyFolderView(
                    title: "这里还没有文件",
                    hint: "点右上角「⋯ → 导入文件 / 新建文件夹」，或从「文件」App 拖入内容"
                )
            } else {
                ForEach(store.entries, id: \.id) { entry in
                    EntryRow(entry: entry, selected: store.selectedEntry?.id == entry.id)
                        .onTapGesture { open(entry) }
                        .contextMenu { rowMenu(entry) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                deleteTarget = entry
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button {
                                store.toggleFavorite(entry)
                            } label: {
                                Label(
                                    store.isFavorite(entry) ? "取消收藏" : "收藏",
                                    systemImage: store.isFavorite(entry) ? "star.slash" : "star"
                                )
                            }
                        }
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await store.refresh() }
        .overlay {
            if store.isLoading { ProgressView() }
        }
        .safeAreaInset(edge: .bottom) { statusBar }
    }

    private var recentList: some View {
        List {
            if store.recent.isEmpty {
                EmptyFolderView(title: "还没有打开过文件", hint: "双击/预览任意文件后会出现在这里")
            } else {
                ForEach(store.recent, id: \.entry.id) { item in
                    EntryRow(entry: item.entry, selected: store.selectedEntry?.id == item.entry.id)
                        .onTapGesture { open(item.entry) }
                        .contextMenu { rowMenu(item.entry) }
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await store.refreshRecent() }
        .safeAreaInset(edge: .bottom) { statusBar }
    }

    private var favoritesList: some View {
        List {
            if store.favorites.isEmpty {
                EmptyFolderView(
                    title: "还没有收藏",
                    hint: "在文件右键菜单或侧滑里点「收藏」"
                )
            } else {
                ForEach(store.favorites, id: \.entry.id) { item in
                    EntryRow(
                        entry: item.entry,
                        selected: store.selectedEntry?.id == item.entry.id,
                        meta: store.favoritePaths[item.entry.id]
                    )
                    .onTapGesture { open(item.entry) }
                    .contextMenu { rowMenu(item.entry) }
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await store.refreshFavorites() }
        .safeAreaInset(edge: .bottom) { statusBar }
    }

    private var activeTransfers: [TransferSnapshot] {
        store.transfers.filter { $0.state == .queued || $0.state == .running }
    }

    private var finishedTransfers: [TransferSnapshot] {
        store.transfers.filter { $0.state != .queued && $0.state != .running }
    }

    private var transfersList: some View {
        List {
            if activeTransfers.isEmpty && finishedTransfers.isEmpty && store.pendingTransfers.isEmpty {
                EmptyFolderView(title: "没有传输任务", hint: "复制/移动到任意位置后会在这里显示进度")
            }

            if !activeTransfers.isEmpty {
                Section("进行中") {
                    ForEach(activeTransfers, id: \.id) { snapshot in
                        TransferRow(snapshot: snapshot) {
                            store.cancelTransfer(snapshot.id)
                        }
                    }
                }
            }

            if !finishedTransfers.isEmpty {
                Section("已结束") {
                    ForEach(finishedTransfers, id: \.id) { snapshot in
                        TransferRow(snapshot: snapshot, onCancel: nil)
                    }
                }
            }

            if !store.pendingTransfers.isEmpty {
                Section("可恢复") {
                    ForEach(store.pendingTransfers, id: \.id) { pending in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pending.sources.first ?? pending.id)
                                    .lineLimit(1)
                                Text("\(pending.filesDone)/\(pending.filesTotal) 个文件")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("继续") { store.resumeTransfer(pending) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refreshTransfers() }
    }

    // MARK: 工具栏

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if store.listMode == .browser && store.canGoUp {
                Button {
                    store.goUp()
                } label: {
                    Image(systemName: "chevron.backward")
                }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    newFolderName = ""
                    showNewFolder = true
                } label: {
                    Label("新建文件夹", systemImage: "folder.badge.plus")
                }
                Button {
                    showImporter = true
                } label: {
                    Label("导入文件…", systemImage: "square.and.arrow.down")
                }
                Button {
                    store.indexCurrent()
                } label: {
                    Label("建立索引", systemImage: "arrow.triangle.2.circlepath")
                }
                Button {
                    store.setShowHidden(!store.showHidden)
                } label: {
                    Label(
                        store.showHidden ? "隐藏隐藏文件" : "显示隐藏文件",
                        systemImage: store.showHidden ? "eye.slash" : "eye"
                    )
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: 行菜单

    @ViewBuilder
    private func rowMenu(_ entry: Entry) -> some View {
        if entry.kind == .file {
            Button {
                preview(entry)
            } label: {
                Label("预览", systemImage: "eye")
            }
            Button {
                store.downloadToLocal(entry)
            } label: {
                Label("下载到本地", systemImage: "arrow.down.circle")
            }
            Button {
                share(entry)
            } label: {
                Label("分享…", systemImage: "square.and.arrow.up")
            }
            Divider()
        } else {
            Button {
                store.open(entry)
            } label: {
                Label("打开", systemImage: "folder")
            }
            Divider()
        }

        Button {
            transferRequest = TransferRequest(sources: [entry.id], move: false)
        } label: {
            Label("复制到…", systemImage: "doc.on.doc")
        }
        Button {
            transferRequest = TransferRequest(sources: [entry.id], move: true)
        } label: {
            Label("移动到…", systemImage: "folder")
        }
        Button {
            renameName = entry.name
            renameTarget = entry
        } label: {
            Label("重命名", systemImage: "pencil")
        }
        Button {
            store.toggleFavorite(entry)
        } label: {
            Label(
                store.isFavorite(entry) ? "取消收藏" : "收藏",
                systemImage: store.isFavorite(entry) ? "star.slash" : "star"
            )
        }
        Divider()
        Button(role: .destructive) {
            deleteTarget = entry
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    private func open(_ entry: Entry) {
        store.open(entry)
        // iPhone / Slide Over 单栏：详情用 sheet，避免右栏不可见。
        if horizontalSizeClass == .compact, entry.kind == .file {
            compactDetail = CompactDetail(entry: entry)
        }
    }

    private func preview(_ entry: Entry) {
        Task { @MainActor in
            quickLook = await store.quickLookPayload(for: entry)
        }
    }

    private func share(_ entry: Entry) {
        Task { @MainActor in
            shareItem = await store.sharePayload(for: entry)
        }
    }

    // MARK: 底部状态

    private var statusBar: some View {
        HStack(spacing: Spacing.s2) {
            Text(store.subtitle)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if store.isSearching {
                Text("搜索结果")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.thinMaterial)
    }
}

// MARK: - 传输行

private struct TransferRow: View {
    let snapshot: TransferSnapshot
    let onCancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(snapshot.current ?? snapshot.id)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(stateLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(
                value: Double(snapshot.bytesDone),
                total: Double(max(snapshot.bytesTotal, 1))
            )
            HStack {
                Text("\(Fmt.bytes.string(fromByteCount: Int64(clamping: snapshot.bytesDone))) / \(Fmt.bytes.string(fromByteCount: Int64(clamping: snapshot.bytesTotal)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if snapshot.state == .running || snapshot.state == .queued, let onCancel {
                    Button("取消", role: .destructive, action: onCancel)
                        .buttonStyle(.borderless)
                }
            }
            if let error = snapshot.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    private var stateLabel: String {
        switch snapshot.state {
        case .queued: return "排队中"
        case .running: return "传输中"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
}

// MARK: - 右栏：详情

@MainActor
private struct DetailColumn: View {
    @ObservedObject var store: VfsStore

    var body: some View {
        if let entry = store.selectedEntry {
            EntryDetailView(store: store, entry: entry)
        } else {
            VStack(spacing: Spacing.s3) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 44))
                    .foregroundStyle(.tertiary)
                Text("选择一个文件查看详情")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("详情")
        }
    }
}

@MainActor
private struct EntryDetailView: View {
    @ObservedObject var store: VfsStore
    let entry: Entry

    @State private var thumbnail: UIImage?
    @State private var player: AVPlayer?
    @State private var quickLook: QuickLookPayload?
    @State private var shareItem: SharePayload?

    @State private var showRename = false
    @State private var renameName = ""
    @State private var showDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.s4) {
                preview
                VStack(alignment: .leading, spacing: Spacing.s1) {
                    Text(entry.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Text(Fmt.detail(entry))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                infoCard
                actions
                Spacer(minLength: Spacing.s4)
            }
            .padding(Spacing.s6)
        }
        .navigationTitle("详情")
        .task(id: entry.id) { await loadPreview() }
        .sheet(item: $quickLook) { payload in
            QuickLookSheet(url: payload.url)
        }
        .sheet(item: $shareItem) { payload in
            ShareSheet(items: [payload.url])
        }
        .alert("重命名", isPresented: $showRename) {
            TextField("名称", text: $renameName)
            Button("确定") {
                store.rename(entry, to: renameName)
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(
            "删除「\(entry.name)」？",
            isPresented: $showDelete,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { store.delete(entry) }
            Button("取消", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Spacing.radiusL)
                .fill(Color.secondary.opacity(0.08))
            if isVideo, let player {
                VideoPlayer(player: player)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: Spacing.radiusM))
                    .padding(Spacing.s2)
            } else if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 340)
                    .clipShape(RoundedRectangle(cornerRadius: Spacing.radiusM))
                    .padding(Spacing.s2)
            } else {
                VStack(spacing: Spacing.s2) {
                    Image(systemName: FileIcon.symbolName(for: entry))
                        .font(.system(size: 56))
                        .foregroundStyle(.secondary)
                    Text(entry.kind == .directory ? "文件夹" : (entry.mime ?? "文件"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 180)
    }

    private var infoCard: some View {
        VStack(spacing: 0) {
            infoRow("位置", entry.id)
            Divider()
            infoRow("大小", Fmt.size(entry))
            Divider()
            infoRow("修改时间", Fmt.modified(entry.modifiedMs))
            if let mime = entry.mime {
                Divider()
                infoRow("类型", mime)
            }
        }
        .padding(.horizontal, Spacing.s4)
        .padding(.vertical, Spacing.s2)
        .background(
            RoundedRectangle(cornerRadius: Spacing.radiusM)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private var actions: some View {
        VStack(spacing: Spacing.s2) {
            if entry.kind == .directory {
                Button {
                    store.open(entry)
                } label: {
                    Label("打开文件夹", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                HStack(spacing: Spacing.s2) {
                    Button {
                        Task { @MainActor in
                            quickLook = await store.quickLookPayload(for: entry)
                        }
                    } label: {
                        Label("预览", systemImage: "eye")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        Task { @MainActor in
                            shareItem = await store.sharePayload(for: entry)
                        }
                    } label: {
                        Label("分享", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    store.downloadToLocal(entry)
                } label: {
                    Label("下载到「文件」App", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: Spacing.s2) {
                Button {
                    renameName = entry.name
                    showRename = true
                } label: {
                    Label("重命名", systemImage: "pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    store.toggleFavorite(entry)
                } label: {
                    Label(
                        store.isFavorite(entry) ? "取消收藏" : "收藏",
                        systemImage: store.isFavorite(entry) ? "star.slash" : "star"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    showDelete = true
                } label: {
                    Label("删除", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var isVideo: Bool {
        guard entry.kind == .file else { return false }
        if entry.mime?.hasPrefix("video/") == true { return true }
        return Fmt.videoExts.contains(Fmt.ext(entry.name))
    }

    private func loadPreview() async {
        thumbnail = nil
        player = nil
        thumbnail = await store.thumbnail(for: entry)
        if isVideo, let url = store.streamURL(for: entry) {
            player = AVPlayer(url: url)
        }
    }
}
