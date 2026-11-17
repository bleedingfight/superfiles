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
    @State private var showStorage = false
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                store: store,
                showAddMount: $showAddMount,
                showStorage: $showStorage,
                showSettings: $showSettings
            )
                .overlay(alignment: .trailing) {
                    if horizontalSizeClass == .regular {
                        Rectangle()
                            .fill(Sf.outline.opacity(0.3))
                            .frame(width: 0.5)
                            .ignoresSafeArea(edges: .vertical)
                    }
                }
        } detail: {
            BrowserColumn(store: store)
        }
        .navigationSplitViewStyle(.balanced)
        .tint(Sf.primary)
        .background(Sf.surface)
        .overlay { ForegroundTransferOverlay(store: store) }
        .onChange(of: scenePhase) { phase in
            // 退到后台时浮层已不可见，自动转为后台传输，避免任务只在前台展示。
            if phase == .background { store.promoteForegroundTransfers() }
        }
        .sheet(isPresented: $showAddMount) {
            AddMountSheet(store: store)
        }
        .sheet(isPresented: $showStorage) {
            StorageSheet(store: store, stats: SfStorage.current())
        }
        .sheet(isPresented: $showSettings) {
            SettingsScreen(store: store)
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
    @Binding var showStorage: Bool
    @Binding var showSettings: Bool

    @AppStorage("sidebar.network.expanded") private var networkExpanded = true
    /// 长按「编辑连接」时承载的表单；左滑/长按删除都会先走风险确认。
    @State private var editingMount: SavedMount?
    @State private var deleteTarget: MountedLocation?

    var body: some View {
        List {
            Section("设备") {
                storageRow
            }

            Section("智能") {
                row(.recent, title: "最近打开", icon: "clock")
                row(.favorites, title: "收藏", icon: "star")
            }

            Section {
                if networkExpanded {
                    ForEach(store.mounts) { mount in
                        row(
                            .mount(mount.rootId),
                            title: mount.label,
                            icon: Self.icon(for: mount.scheme)
                        )
                        .contextMenu {
                            Button {
                                editingMount = store.savedMount(for: mount)
                            } label: {
                                Label("编辑连接", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                deleteTarget = mount
                            } label: {
                                Label("断开连接", systemImage: "eject")
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                deleteTarget = mount
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            .tint(Sf.error)
                        }
                    }
                }
                Button {
                    showAddMount = true
                } label: {
                    Label("添加网络存储…", systemImage: "plus.circle")
                }
            } header: {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        networkExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: Spacing.s2) {
                        Text("网络存储")
                        if !store.mounts.isEmpty {
                            Text("\(store.mounts.count)")
                                .font(Sf.metaFont)
                                .foregroundStyle(Sf.onSurfaceVariant)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Sf.onSurfaceVariant)
                            .rotationEffect(.degrees(networkExpanded ? 90 : 0))
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Section("传输") {
                row(.transfers, title: "传输中心", icon: "arrow.up.arrow.down")
                    .badge(
                        store.activeTransferCount > 0
                            ? Text("\(store.activeTransferCount)")
                            : nil
                    )
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Sf.surface)
        .navigationTitle("Super Files")
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: Spacing.s2) {
                Button {
                    showSettings = true
                } label: {
                    Label("我的", systemImage: "person.crop.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Sf.primary)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("v\(store.version)")
                    .font(Sf.footerFont)
                    .foregroundStyle(Sf.onSurfaceVariant)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Sf.surface)
        }
        .sheet(item: $editingMount) { mount in
            AddMountSheet(store: store, editing: mount)
        }
        .confirmationDialog(
            "断开网络存储",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("断开「\(deleteTarget?.label ?? "")」", role: .destructive) {
                if let target = deleteTarget { store.removeMount(target) }
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("仅删除本机保存的连接配置，不会影响服务器上的文件。")
        }
    }

    /// 应用存储行：副标题显示设备用量，点击「管理」打开存储管理面板。
    private var storageRow: some View {
        let stats = SfStorage.current()
        return HStack(spacing: Spacing.s3) {
            Button {
                store.activate(.appStorage)
            } label: {
                HStack(spacing: Spacing.s3) {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 15))
                        .foregroundStyle(Sf.onSurface)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: Spacing.s1) {
                        Text("应用存储")
                            .font(.system(size: 15))
                            .foregroundStyle(Sf.onSurface)
                        if let stats {
                            Text(stats.summary)
                                .font(Sf.metaFont)
                                .foregroundStyle(Sf.onSurfaceVariant)
                            StorageBar(fraction: stats.fraction)
                                .padding(.trailing, Spacing.s4)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button("管理") { showStorage = true }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Sf.primary)
                .buttonStyle(.plain)
        }
        .listRowBackground(store.sidebar == .appStorage ? Sf.surfaceTint : Color.clear)
    }

    /// 位置行：每次点击都走 activate，因此重复点击当前项也会重新加载（手动刷新）。
    private func row(_ tag: SidebarSelection, title: String, icon: String) -> some View {
        Button {
            store.activate(tag)
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 15))
                .foregroundStyle(Sf.onSurface)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            store.sidebar == tag ? Sf.surfaceTint : Color.clear
        )
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

private struct DetailSheet: Identifiable {
    var id: String { entry.id }
    let entry: Entry
}

private struct ActionTarget: Identifiable {
    let id = UUID()
    let entry: Entry
    let isRecent: Bool
}

private struct LocalSendRequest: Identifiable {
    let id = UUID()
    let entries: [Entry]
}

private struct ShareLinkRequest: Identifiable {
    let id = UUID()
    let entries: [Entry]
}

@MainActor
private struct BrowserColumn: View {
    @ObservedObject var store: VfsStore

    @State private var detailSheet: DetailSheet?
    @State private var showImporter = false
    @State private var showNewFolder = false
    @State private var newFolderName = ""

    @State private var renameTarget: Entry?
    @State private var renameName = ""

    @State private var deleteTarget: Entry?
    @State private var actionTarget: ActionTarget?

    @State private var transferRequest: TransferRequest?
    @State private var shareItem: SharePayload?
    @State private var quickLook: QuickLookPayload?
    @State private var imageGallery: ImageGalleryRequest?
    @State private var videoRequest: VideoPlaybackRequest?
    @State private var pdfRequest: PdfOpenRequest?
    @State private var docRequest: DocPlaceholderRequest?
    @State private var openInPayload: OpenInPayload?
    @State private var localSendRequest: LocalSendRequest?
    @State private var shareLinkRequest: ShareLinkRequest?

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
        .fullScreenCover(item: $imageGallery) { request in
            ImageGalleryView(
                store: store,
                entries: request.entries,
                startID: request.startID
            )
        }
        .fullScreenCover(item: $videoRequest) { request in
            VideoPlayerScreen(store: store, entry: request.entry)
        }
        .fullScreenCover(item: $pdfRequest) { request in
            PdfViewerScreen(store: store, entry: request.entry)
        }
        .fullScreenCover(item: $docRequest) { request in
            DocumentPlaceholderScreen(store: store, entry: request.entry)
        }
        .sheet(item: $openInPayload) { payload in
            OpenInSheet(url: payload.url, uti: payload.uti) {
                store.cleanupTemporaryCopy(payload.url)
                openInPayload = nil
            }
        }
        .sheet(item: $localSendRequest) { request in
            LocalSendPeerPicker(store: store, entries: request.entries)
        }
        .sheet(item: $shareLinkRequest) { request in
            ShareLinkSheet(store: store, entries: request.entries)
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
        .sheet(item: $detailSheet) { selection in
            NavigationStack {
                EntryDetailView(store: store, entry: selection.entry)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { detailSheet = nil }
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
        .alert(
            "删除文件",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            presenting: deleteTarget
        ) { target in
            Button("删除", role: .destructive) {
                store.delete(target)
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: { target in
            Text("确定删除「\(target.name)」？此操作不可撤销。")
        }
        .confirmationDialog(
            actionTarget?.entry.name ?? "操作",
            isPresented: Binding(
                get: { actionTarget != nil },
                set: { if !$0 { actionTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: actionTarget
        ) { target in
            actionDialog(for: target.entry, inRecent: target.isRecent)
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
                    .font(Sf.metaFont)
                    .foregroundStyle(Sf.onSurfaceVariant)
                    .listRowBackground(Sf.surfaceCard)
                }
            }

            if store.entries.isEmpty && !store.isLoading {
                Section {
                    EmptyFolderView(
                        title: "这里还没有文件",
                        hint: "点右上角「⋯ → 导入文件 / 新建文件夹」，或从「文件」App 拖入内容"
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(store.entries, id: \.id) { entry in
                        EntryRow(entry: entry, selected: store.selectedEntry?.id == entry.id)
                            .onTapGesture { open(entry) }
                            .contextMenu { rowMenu(entry) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                rowSwipeActions(for: entry)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                rowLeadingSwipeAction(for: entry)
                            }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Sf.surface)
        .refreshable { await store.refresh() }
        .overlay {
            if store.isLoading { ProgressView().tint(Sf.primary) }
        }
        .safeAreaInset(edge: .bottom) { statusBar }
    }

    private var recentList: some View {
        List {
            if store.recent.isEmpty {
                Section {
                    EmptyFolderView(title: "还没有打开过文件", hint: "双击/预览任意文件后会出现在这里")
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(store.recent, id: \.entry.id) { item in
                        EntryRow(entry: item.entry, selected: store.selectedEntry?.id == item.entry.id)
                            .onTapGesture { open(item.entry) }
                            .contextMenu { rowMenu(item.entry, inRecent: true) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                rowSwipeActions(for: item.entry, inRecent: true)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                rowLeadingSwipeAction(for: item.entry, inRecent: true)
                            }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Sf.surface)
        .refreshable { await store.refreshRecent() }
        .safeAreaInset(edge: .bottom) { statusBar }
    }

    private var favoritesList: some View {
        List {
            if store.favorites.isEmpty {
                Section {
                    EmptyFolderView(
                        title: "还没有收藏",
                        hint: "在文件右键菜单或侧滑里点「收藏」"
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(store.favorites, id: \.entry.id) { item in
                        EntryRow(
                            entry: item.entry,
                            selected: store.selectedEntry?.id == item.entry.id,
                            meta: store.favoritePaths[item.entry.id]
                        )
                        .onTapGesture { open(item.entry) }
                        .contextMenu { rowMenu(item.entry) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            rowSwipeActions(for: item.entry)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            rowLeadingSwipeAction(for: item.entry)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Sf.surface)
        .refreshable { await store.refreshFavorites() }
        .safeAreaInset(edge: .bottom) { statusBar }
    }

    private var activeTransfers: [TransferSnapshot] {
        store.transfers.filter {
            // PAUSED 不是终态：与 Android/OHOS 同口径算「进行中」
            !store.foregroundTransferIds.contains($0.id)
                && ($0.state == .queued || $0.state == .running || $0.state == .paused)
        }
    }

    private var finishedTransfers: [TransferSnapshot] {
        store.transfers.filter {
            !store.foregroundTransferIds.contains($0.id)
                && $0.state != .queued && $0.state != .running && $0.state != .paused
        }
    }

    /// 传输中心：分组标题（17 w700）+ 每条记录一张独立白色圆角卡，与 Android/OHOS
    /// 传输中心、iOS 详情页 infoCard 同一套卡片语言。此前是 insetGrouped 的整组
    /// 连体单元格（组内一条条记录夹着眉线），不像其他页面的分组卡版式。
    private var transfersList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.s2) {
                if activeTransfers.isEmpty && finishedTransfers.isEmpty && store.pendingTransfers.isEmpty {
                    EmptyFolderView(title: "没有传输任务", hint: "复制/移动到任意位置后会在这里显示进度")
                        .frame(maxWidth: .infinity)
                        .padding(.top, Spacing.s6)
                }

                if !activeTransfers.isEmpty {
                    transferSectionTitle("进行中", activeTransfers.count)
                    ForEach(activeTransfers, id: \.id) { snapshot in
                        TransferRow(
                            snapshot: snapshot,
                            title: store.transferLabels[snapshot.id]
                                ?? snapshot.current
                                ?? "\(snapshot.filesTotal) 项文件",
                            rate: store.transferRates[snapshot.id] ?? 0
                        ) {
                            store.cancelTransfer(snapshot.id)
                        }
                    }
                }

                if !finishedTransfers.isEmpty {
                    transferSectionTitle("已结束", finishedTransfers.count)
                    ForEach(finishedTransfers, id: \.id) { snapshot in
                        TransferRow(
                            snapshot: snapshot,
                            title: store.transferLabels[snapshot.id]
                                ?? snapshot.current
                                ?? "\(snapshot.filesTotal) 项文件",
                            rate: 0,
                            onCancel: nil
                        )
                    }
                }

                if !store.pendingTransfers.isEmpty {
                    transferSectionTitle("可恢复")
                    ForEach(store.pendingTransfers, id: \.id) { pending in
                        pendingTransferRow(pending)
                    }
                }
            }
            .padding(Spacing.s6)
        }
        .background(Sf.surface)
        .refreshable { await store.refreshTransfers() }
    }

    /// 17 w700 分组标题 + 11 号灰计数（与 Android SectionTitle 同版式）。
    private func transferSectionTitle(_ title: String, _ count: Int? = nil) -> some View {
        HStack(spacing: Spacing.s1) {
            Text(title)
                .font(Sf.appBarFont)
                .foregroundStyle(Sf.onSurface)
            if let count {
                Text("\(count)")
                    .font(Sf.metaFont)
                    .foregroundStyle(Sf.onSurfaceVariant)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, Spacing.s1)
    }

    /// 可恢复任务：与其他记录同一套圆角卡。
    private func pendingTransferRow(_ pending: PendingTransfer) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    pending.sources.first.map {
                        ($0 as NSString).lastPathComponent
                    } ?? pending.id
                )
                .font(Sf.fileNameFont)
                .foregroundStyle(Sf.onSurface)
                .lineLimit(1)
                Text("\(pending.filesDone)/\(pending.filesTotal) 个文件")
                    .font(Sf.metaFont)
                    .foregroundStyle(Sf.onSurfaceVariant)
            }
            Spacer()
            Button("继续") { store.resumeTransfer(pending) }
                .buttonStyle(.bordered)
        }
        .padding(Spacing.s4)
        .background(
            RoundedRectangle(cornerRadius: Spacing.radiusM)
                .fill(Sf.surfaceCard)
        )
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
    private func rowLeadingSwipeAction(
        for entry: Entry,
        inRecent: Bool = false
    ) -> some View {
        Button {
            actionTarget = ActionTarget(entry: entry, isRecent: inRecent)
        } label: {
            Label("更多", systemImage: "ellipsis.circle")
        }
        .tint(Sf.primary)
    }

    /// 右滑「更多」：复用与长按菜单一致的主要操作。
    @ViewBuilder
    private func actionDialog(for entry: Entry, inRecent: Bool = false) -> some View {
        if entry.kind == .file {
            Button {
                detailSheet = DetailSheet(entry: entry)
            } label: {
                Label("详情", systemImage: "info.circle")
            }
            Button {
                openIn(entry)
            } label: {
                Label("用其他 App 打开", systemImage: "arrow.up.forward.app")
            }
            Button {
                preview(entry)
            } label: {
                if entry.mime?.hasPrefix("video/") == true {
                    Label("播放", systemImage: "play.rectangle")
                } else {
                    Label("预览", systemImage: "eye")
                }
            }
            Button {
                share(entry)
            } label: {
                Label("分享…", systemImage: "square.and.arrow.up")
            }
            Button {
                localSendRequest = LocalSendRequest(entries: [entry])
            } label: {
                Label("发送到附近设备", systemImage: "dot.radiowaves.left.and.right")
            }
            Button {
                shareLinkRequest = ShareLinkRequest(entries: [entry])
            } label: {
                Label("就近分享（二维码）", systemImage: "qrcode")
            }
            if store.localFileURL(for: entry) == nil {
                Button {
                    store.downloadToLocal(entry)
                } label: {
                    Label("后台下载到「下载」", systemImage: "arrow.down.circle")
                }
            }
        } else {
            Button {
                store.open(entry)
            } label: {
                Label("打开", systemImage: "folder")
            }
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
        if inRecent {
            Button {
                store.removeRecent(entry)
            } label: {
                Label("从最近移除", systemImage: "clock.badge.xmark")
            }
        } else {
            Button(role: .destructive) {
                deleteTarget = entry
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        Button("取消", role: .cancel) {}
    }

    @ViewBuilder
    private func rowSwipeActions(
        for entry: Entry,
        inRecent: Bool = false
    ) -> some View {
        if inRecent {
            Button {
                store.removeRecent(entry)
            } label: {
                Label("从最近移除", systemImage: "clock.badge.xmark")
            }
            .tint(Sf.primary)
        } else {
            Button(role: .destructive) {
                deleteTarget = entry
            } label: {
                Label("删除", systemImage: "trash")
            }
            .tint(.red)
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

    @ViewBuilder
    private func rowMenu(_ entry: Entry, inRecent: Bool = false) -> some View {
        if entry.kind == .file {
            Button {
                detailSheet = DetailSheet(entry: entry)
            } label: {
                Label("详情", systemImage: "info.circle")
            }
            Button {
                openIn(entry)
            } label: {
                Label("用其他 App 打开", systemImage: "arrow.up.forward.app")
            }
            Button {
                preview(entry)
            } label: {
                if entry.mime?.hasPrefix("video/") == true {
                    Label("播放", systemImage: "play.rectangle")
                } else {
                    Label("预览", systemImage: "eye")
                }
            }
            Button {
                share(entry)
            } label: {
                Label("分享…", systemImage: "square.and.arrow.up")
            }
            Button {
                localSendRequest = LocalSendRequest(entries: [entry])
            } label: {
                Label("发送到附近设备", systemImage: "dot.radiowaves.left.and.right")
            }
            Button {
                shareLinkRequest = ShareLinkRequest(entries: [entry])
            } label: {
                Label("就近分享（二维码）", systemImage: "qrcode")
            }
            if store.localFileURL(for: entry) == nil {
                Button {
                    store.downloadToLocal(entry)
                } label: {
                    Label("后台下载到「下载」", systemImage: "arrow.down.circle")
                }
            }
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
        if inRecent {
            Button {
                store.removeRecent(entry)
            } label: {
                Label("从最近移除", systemImage: "clock.badge.xmark")
            }
        } else {
            Button(role: .destructive) {
                deleteTarget = entry
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func open(_ entry: Entry) {
        store.open(entry)
        guard entry.kind == .file else { return }
        // iOS 不允许静默启动别的 App：图片走应用内画廊，视频走系统播放器，
        // PDF 走应用内 PDFKit 预览；办公文档等无系统渲染器的格式给占位页，
        // 其余直接交给「用其他 App 打开」（VLC/Infuse 等）。
        if entry.mime?.hasPrefix("image/") == true {
            openImageGallery(entry)
        } else if entry.mime?.hasPrefix("video/") == true {
            // 系统播放器直接流式播放；不支持的容器在播放页里提示并给外部播放入口。
            videoRequest = VideoPlaybackRequest(entry: entry)
        } else if DocTypes.isPDF(entry) {
            pdfRequest = PdfOpenRequest(entry: entry)
        } else if DocTypes.isExternalDocument(entry) {
            docRequest = DocPlaceholderRequest(entry: entry)
        } else {
            openIn(entry)
        }
    }

    private func openImageGallery(_ entry: Entry) {
        let source: [Entry]
        switch store.listMode {
        case .browser: source = store.entries
        case .recent: source = store.recent.map(\.entry)
        case .favorites: source = store.favorites.map(\.entry)
        case .transfers: source = []
        }
        var images = source.filter {
            $0.kind == .file && $0.mime?.hasPrefix("image/") == true
        }
        if !images.contains(where: { $0.id == entry.id }) {
            images.insert(entry, at: 0)
        }
        imageGallery = ImageGalleryRequest(entries: images, startID: entry.id)
    }

    private func openIn(_ entry: Entry) {
        Task { @MainActor in
            guard let url = await store.localCopy(for: entry) else { return }
            openInPayload = OpenInPayload(url: url, uti: DocTypes.utType(for: entry).identifier)
        }
    }

    private func preview(_ entry: Entry) {
        if entry.mime?.hasPrefix("video/") == true {
            videoRequest = VideoPlaybackRequest(entry: entry)
            return
        }
        if DocTypes.isPDF(entry) {
            pdfRequest = PdfOpenRequest(entry: entry)
            return
        }
        if DocTypes.isExternalDocument(entry) {
            docRequest = DocPlaceholderRequest(entry: entry)
            return
        }
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
                .font(Sf.footerFont)
                .foregroundStyle(Sf.onSurfaceVariant)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if store.isSearching {
                Text("搜索结果")
                    .font(Sf.footerFont)
                    .foregroundStyle(Sf.onSurfaceVariant)
            }
        }
        .padding(.horizontal, Sf.safeMargin)
        .padding(.vertical, 6)
        .background(Sf.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Sf.outline.opacity(0.25))
                .frame(height: 0.5)
        }
    }
}

// MARK: - 传输行

private struct TransferRow: View {
    let snapshot: TransferSnapshot
    let title: String
    let rate: Int64
    let onCancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(Sf.fileNameFont)
                    .foregroundStyle(Sf.onSurface)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(stateLabel)
                    .font(Sf.metaFont)
                    .foregroundStyle(Sf.onSurfaceVariant)
            }
            ProgressView(
                value: Double(snapshot.bytesDone),
                total: Double(max(snapshot.bytesTotal, 1))
            )
            .tint(Sf.primary)
            HStack {
                Text("\(Fmt.bytes.string(fromByteCount: Int64(clamping: snapshot.bytesDone))) / \(Fmt.bytes.string(fromByteCount: Int64(clamping: snapshot.bytesTotal)))")
                    .font(Sf.metaFont)
                    .foregroundStyle(Sf.onSurfaceVariant)
                Spacer()
                if snapshot.state == .running {
                    Text(rate > 0 ? "\(Fmt.bytes.string(fromByteCount: rate))/s" : "…")
                        .font(Sf.metaFont.weight(.semibold))
                        .foregroundStyle(Sf.primary)
                }
                if snapshot.state == .running || snapshot.state == .queued, let onCancel {
                    Button("取消", role: .destructive, action: onCancel)
                        .buttonStyle(.borderless)
                }
            }
            // 开始/结束/耗时独立一行（对齐鸿蒙 TransfersView.timesLine 与 Android 传输中心）
            Text(timesLine)
                .font(Sf.metaFont)
                .foregroundStyle(Sf.onSurfaceVariant)
                .lineLimit(1)
            if let error = snapshot.error {
                Text(error)
                    .font(Sf.metaFont)
                    .foregroundStyle(Sf.error)
            }
        }
        .padding(Spacing.s4)
        .background(
            RoundedRectangle(cornerRadius: Spacing.radiusM)
                .fill(Sf.surfaceCard)
        )
    }

    private var stateLabel: String {
        switch snapshot.state {
        case .queued: return "排队中"
        case .running: return "传输中"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }

    /// 开始 HH:mm:ss · 结束 HH:mm:ss（未结束为 —）· 耗时（两端都有效才显示）；
    /// 任务落定后追加事实速度（bytesDone ÷ 实际耗时，失败/取消记录同样成立）。
    private var timesLine: String {
        let start = snapshot.startedAtMs
        let end = snapshot.finishedAtMs ?? 0
        var text = "开始 \(clock(start))"
        text += " · 结束 \(clock(end))"
        if start > 0 && end > 0 && end >= start {
            let elapsedMs = end - start
            text += " · 耗时 \(Fmt.duration(elapsedMs))"
            if elapsedMs >= 1000 {
                let bytesPerSec = Double(snapshot.bytesDone) * 1000 / Double(elapsedMs)
                text += " · 平均 \(Fmt.bytes.string(fromByteCount: Int64(bytesPerSec)))/s"
            }
        }
        return text
    }

    private func clock(_ ms: Int64) -> String {
        guard ms > 0 else { return "—" }
        return Fmt.clock.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}

// MARK: - 前台传输浮层

/// 复制/移动刚开始时的 App 内进度浮层。任务先不进传输中心，用户可选「终止」或
/// 「后台传输」；App 退到后台会自动等价于按下「后台传输」。
@MainActor
private struct ForegroundTransferOverlay: View {
    @ObservedObject var store: VfsStore

    var body: some View {
        if !store.foregroundTransferIds.isEmpty {
            let active = store.foregroundTransfers
            let bytesDone = active.reduce(Int64(0)) { $0 + Int64(clamping: $1.bytesDone) }
            let bytesTotal = active.reduce(Int64(0)) { $0 + Int64(clamping: $1.bytesTotal) }
            let filesDone = active.reduce(UInt64(0)) { $0 + $1.filesDone }
            let filesTotal = active.reduce(UInt64(0)) { $0 + $1.filesTotal }
            let rate = store.foregroundTransferIds.reduce(Int64(0)) {
                $0 + (store.transferRates[$1] ?? 0)
            }
            let moving = !store.foregroundMoveIds.isEmpty
            let copying = active.contains { !store.foregroundMoveIds.contains($0.id) }
            let title = moving && copying ? "正在复制与移动" : (moving ? "正在移动" : "正在复制")
            let current = active.compactMap({ $0.current }).first(where: { !$0.isEmpty }) ?? "准备中…"
            let fraction = bytesTotal > 0 ? Double(bytesDone) / Double(bytesTotal) : 0

            ZStack {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture {}

                VStack(alignment: .leading, spacing: Spacing.s4) {
                    HStack(spacing: Spacing.s3) {
                        Image(systemName: moving ? "folder.badge.gearshape" : "doc.on.doc")
                            .font(.system(size: 20, weight: .regular))
                            .foregroundStyle(Sf.primaryWarm)
                            .frame(width: 40, height: 40)
                            .background(
                                RoundedRectangle(cornerRadius: Spacing.radiusS)
                                    .fill(Sf.avatarBg)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                                .font(Sf.appBarFont)
                                .foregroundStyle(Sf.onSurface)
                            Text(filesTotal > 1 ? "共 \(filesTotal) 个文件" : "1 个文件")
                                .font(Sf.cardTitleFont)
                                .foregroundStyle(Sf.onSurfaceVariant)
                        }
                    }

                    VStack(alignment: .leading, spacing: Spacing.s2) {
                        Text(current)
                            .font(Sf.fileNameFont)
                            .foregroundStyle(Sf.onSurface)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        ProgressView(value: min(max(fraction, 0), 1))
                            .tint(Sf.primary)
                        HStack {
                            Text(progressLine(
                                filesDone: filesDone,
                                filesTotal: filesTotal,
                                bytesDone: bytesDone,
                                bytesTotal: bytesTotal
                            ))
                            .font(Sf.metaFont)
                            .foregroundStyle(Sf.onSurfaceVariant)
                            Spacer()
                            Text(rate > 0 ? "\(Fmt.bytes.string(fromByteCount: rate))/s" : "…")
                                .font(Sf.metaFont.weight(.semibold))
                                .foregroundStyle(Sf.primary)
                        }
                    }

                    HStack(spacing: Spacing.s2) {
                        Spacer()
                        Button("终止", role: .destructive) {
                            store.cancelForegroundTransfers()
                        }
                        Button("后台传输") {
                            store.sendForegroundTransfersToBackground()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Sf.primary)
                    }
                }
                .padding(Spacing.s6)
                .frame(maxWidth: 380)
                .background(
                    RoundedRectangle(cornerRadius: Spacing.radiusL)
                        .fill(Sf.surfaceCard)
                )
                .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
                .padding(Spacing.s8)
            }
            .transition(.opacity)
        }
    }

    private func progressLine(
        filesDone: UInt64,
        filesTotal: UInt64,
        bytesDone: Int64,
        bytesTotal: Int64
    ) -> String {
        let size = "\(Fmt.bytes.string(fromByteCount: bytesDone)) / \(Fmt.bytes.string(fromByteCount: bytesTotal))"
        if filesTotal > 1 {
            return "\(min(filesDone, filesTotal))/\(filesTotal) 个文件 · \(size)"
        }
        return size
    }
}

// MARK: - 详情

@MainActor
private struct EntryDetailView: View {
    @ObservedObject var store: VfsStore
    let entry: Entry

    @State private var thumbnail: UIImage?
    @State private var player: AVPlayer?
    @State private var quickLook: QuickLookPayload?
    @State private var videoRequest: VideoPlaybackRequest?
    @State private var pdfRequest: PdfOpenRequest?
    @State private var openInPayload: OpenInPayload?
    @State private var shareItem: SharePayload?
    @State private var localSendRequest: LocalSendRequest?
    @State private var shareLinkRequest: ShareLinkRequest?

    @State private var showRename = false
    @State private var renameName = ""
    @State private var showDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.s4) {
                preview
                VStack(alignment: .leading, spacing: Spacing.s1) {
                    Text(entry.name)
                        .font(Sf.appBarFont)
                        .foregroundStyle(Sf.onSurface)
                        .lineLimit(2)
                    Text(Fmt.detail(entry))
                        .font(Sf.metaFont)
                        .foregroundStyle(Sf.onSurfaceVariant)
                }
                infoCard
                actions
                Spacer(minLength: Spacing.s4)
            }
            .padding(Spacing.s6)
        }
        .background(Sf.surface)
        .navigationTitle("详情")
        .task(id: entry.id) { await loadPreview() }
        .sheet(item: $quickLook) { payload in
            QuickLookSheet(url: payload.url)
        }
        .fullScreenCover(item: $videoRequest) { request in
            VideoPlayerScreen(store: store, entry: request.entry)
        }
        .fullScreenCover(item: $pdfRequest) { request in
            PdfViewerScreen(store: store, entry: request.entry)
        }
        .sheet(item: $openInPayload) { payload in
            OpenInSheet(url: payload.url, uti: payload.uti) {
                store.cleanupTemporaryCopy(payload.url)
                openInPayload = nil
            }
        }
        .sheet(item: $shareItem) { payload in
            ShareSheet(items: [payload.url])
        }
        .sheet(item: $localSendRequest) { request in
            LocalSendPeerPicker(store: store, entries: request.entries)
        }
        .sheet(item: $shareLinkRequest) { request in
            ShareLinkSheet(store: store, entries: request.entries)
        }
        .alert("重命名", isPresented: $showRename) {
            TextField("名称", text: $renameName)
            Button("确定") {
                store.rename(entry, to: renameName)
            }
            Button("取消", role: .cancel) {}
        }
        .alert("删除文件", isPresented: $showDelete) {
            Button("删除", role: .destructive) { store.delete(entry) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确定删除「\(entry.name)」？此操作不可撤销。")
        }
    }

    @ViewBuilder
    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Spacing.radiusL)
                .fill(Sf.surfaceCard)
            if isVideo, !Fmt.systemCanPlayVideo(entry) {
                VStack(spacing: Spacing.s2) {
                    Image(systemName: "play.slash")
                        .font(.system(size: 48))
                        .foregroundStyle(Sf.outline)
                    Text("系统播放器不支持 \(Fmt.ext(entry.name).uppercased())")
                        .font(Sf.metaFont)
                        .foregroundStyle(Sf.onSurfaceVariant)
                    Text("请用 VLC / Infuse 等 App 打开")
                        .font(Sf.metaFont)
                        .foregroundStyle(Sf.onSurfaceVariant)
                }
            } else if isVideo, let player {
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
                        .foregroundStyle(Sf.outline)
                    Text(entry.kind == .directory ? "文件夹" : (entry.mime ?? "文件"))
                        .font(Sf.metaFont)
                        .foregroundStyle(Sf.onSurfaceVariant)
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
                .fill(Sf.surfaceCard)
        )
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s3) {
            Text(label)
                .font(Sf.metaFont)
                .foregroundStyle(Sf.onSurfaceVariant)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(Sf.metaFont)
                .foregroundStyle(Sf.onSurface)
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
                    if isVideo, !Fmt.systemCanPlayVideo(entry) {
                        Button {
                            openExternal()
                        } label: {
                            Label("用其他 App 打开", systemImage: "arrow.up.forward.app")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } else if !isVideo, DocTypes.isExternalDocument(entry) {
                        // 无系统渲染器的文档：详情页已展示文件信息，主按钮直接给外部打开。
                        Button {
                            openExternal()
                        } label: {
                            Label("用其他 App 打开", systemImage: "arrow.up.forward.app")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            if isVideo {
                                videoRequest = VideoPlaybackRequest(entry: entry)
                            } else if DocTypes.isPDF(entry) {
                                pdfRequest = PdfOpenRequest(entry: entry)
                            } else {
                                Task { @MainActor in
                                    quickLook = await store.quickLookPayload(for: entry)
                                }
                            }
                        } label: {
                            Label(
                                isVideo ? "播放" : "预览",
                                systemImage: isVideo ? "play.rectangle" : "eye"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }

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
                if store.localFileURL(for: entry) == nil {
                    Button {
                        store.downloadToLocal(entry)
                    } label: {
                        Label("后台下载到「下载」", systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: Spacing.s2) {
                    Button {
                        shareLinkRequest = ShareLinkRequest(entries: [entry])
                    } label: {
                        Label("二维码分享", systemImage: "qrcode")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        localSendRequest = LocalSendRequest(entries: [entry])
                    } label: {
                        Label("附近设备", systemImage: "dot.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
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

    private func openExternal() {
        Task { @MainActor in
            guard let url = await store.localCopy(for: entry) else { return }
            openInPayload = OpenInPayload(url: url, uti: DocTypes.utType(for: entry).identifier)
        }
    }

    private func loadPreview() async {
        thumbnail = nil
        player = nil
        thumbnail = await store.thumbnail(for: entry)
        if isVideo, Fmt.systemCanPlayVideo(entry), let url = store.streamURL(for: entry) {
            player = AVPlayer(url: url)
        }
    }
}
