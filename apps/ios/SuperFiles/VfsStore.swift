import Foundation
import SwiftUI
import UIKit

/// Rust 内核的 SwiftUI 门面。
///
/// 内核 API 是同步阻塞的（ADR 0002），所有调用统一走后台线程；UI 状态只在
/// 主线程更新。iPad 版在此之上提供：多位置浏览（应用存储 / 网络挂载）、
/// 复制/移动 + 传输进度、收藏 / 最近 / 搜索、详情预览与系统分享。
@MainActor
final class VfsStore: ObservableObject {
    // 导航
    @Published var sidebar: SidebarSelection = .appStorage
    @Published private(set) var listMode: ListMode = .browser
    @Published private(set) var currentId: String = ""
    @Published private(set) var rootId: String = ""
    @Published private(set) var path: String = ""
    @Published private(set) var canGoUp = false
    @Published var selectedEntry: Entry?

    // 列表
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var recent: [RecentOpen] = []
    @Published private(set) var favorites: [FavoriteEntry] = []
    @Published private(set) var favoritePaths: [String: String] = [:]
    @Published private(set) var favoriteIds: Set<String> = []
    @Published private(set) var mounts: [MountedLocation] = []

    // 搜索 / 索引
    @Published var query = ""
    @Published private(set) var isSearching = false
    @Published private(set) var showHidden = false
    @Published private(set) var indexedCount: UInt64 = 0

    // 状态
    @Published private(set) var isLoading = false
    @Published private(set) var offlineCacheMs: Int64?
    @Published var notice: String?
    @Published var errorMessage: String?

    // 传输
    @Published private(set) var transfers: [TransferSnapshot] = []
    @Published private(set) var pendingTransfers: [PendingTransfer] = []

    let appRoot: String
    let core: SuperFiles

    private var history: [String] = []
    private var loadSeq = 0
    private var transferTask: Task<Void, Never>?
    private var savedMounts: [SavedMount] = []
    private let mountsKey = "saved_network_mounts_v1"

    init() {
        let fileManager = FileManager.default
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let meta = documents.appendingPathComponent(".superfiles", isDirectory: true)
        try? fileManager.createDirectory(at: meta, withIntermediateDirectories: true)

        do {
            core = try SuperFiles.open(
                localRoot: documents.path,
                indexPath: meta.appendingPathComponent("index.sqlite").path
            )
        } catch {
            fatalError("Super Files core failed to start: \(error)")
        }

        appRoot = core.rootId()
        rootId = appRoot
        currentId = appRoot
        path = documents.path
        canGoUp = false

        savedMounts = loadSavedMounts()

        // 后台下载完成/失败 → 主线程轻提示
        NotificationCenter.default.addObserver(
            forName: BackgroundDownloadManager.didFinishNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                if let error = notification.userInfo?[BackgroundDownloadManager.errorUserInfoKey] as? String {
                    self.errorMessage = error
                } else if let url = notification.userInfo?[BackgroundDownloadManager.destinationUserInfoKey] as? URL {
                    self.notice = "下载完成：\(url.lastPathComponent)"
                }
            }
        }

        load(appRoot)
        refreshFavorites()
        refreshRecent()
        refreshIndexCount()
        refreshTransfers()
        restoreMounts()
    }

    // MARK: - 派生状态

    var contentTitle: String {
        switch listMode {
        case .recent: return "最近打开"
        case .favorites: return "收藏"
        case .transfers: return "传输中心"
        case .browser:
            let name = (path as NSString).lastPathComponent
            return name.isEmpty ? "文件" : name
        }
    }

    var subtitle: String {
        if listMode == .browser {
            let indexed = indexedCount > 0 ? " · 已索引 \(indexedCount) 项" : ""
            return path + indexed
        }
        switch listMode {
        case .recent: return "\(recent.count) 项"
        case .favorites: return "\(favorites.count) 项"
        case .transfers: return "\(activeTransferCount) 个进行中"
        case .browser: return path
        }
    }

    var activeTransferCount: Int {
        transfers.filter { $0.state == .queued || $0.state == .running }.count
    }

    var version: String { core.version() }

    func isFavorite(_ entry: Entry) -> Bool { favoriteIds.contains(entry.id) }

    // MARK: - 位置 / 目录导航

    func activate(_ selection: SidebarSelection) {
        isSearching = false
        query = ""
        selectedEntry = nil
        switch selection {
        case .appStorage:
            listMode = .browser
            rootId = appRoot
            history = []
            load(appRoot)
        case .mount(let rid):
            listMode = .browser
            rootId = rid
            history = []
            load(rid)
        case .recent:
            listMode = .recent
            refreshRecent()
        case .favorites:
            listMode = .favorites
            refreshFavorites()
        case .transfers:
            listMode = .transfers
            refreshTransfers()
        }
    }

    func open(_ entry: Entry) {
        if entry.kind == .directory {
            isSearching = false
            query = ""
            selectedEntry = nil
            if let root = rootContaining(entry.id) { rootId = root }
            listMode = .browser
            if currentId != entry.id { history.append(currentId) }
            load(entry.id)
        } else {
            selectedEntry = entry
            recordOpen(entry)
        }
    }

    /// 打开/选中文件即记入「最近打开」（索引表，跨启动保留）。
    func recordOpen(_ entry: Entry) {
        guard entry.kind == .file else { return }
        let core = self.core
        Task {
            _ = await runOffMain { try core.recordOpen(id: entry.id) }
            self.refreshRecent()
        }
    }

    func goUp() {
        isSearching = false
        query = ""
        selectedEntry = nil
        listMode = .browser
        if let previous = history.popLast() {
            load(previous)
        } else if currentId != rootId {
            load(rootId)
        }
    }

    func refresh() {
        if listMode == .browser { load(currentId) }
    }

    func setShowHidden(_ value: Bool) {
        guard value != showHidden else { return }
        showHidden = value
        if listMode == .browser { load(currentId) }
    }

    /// 打开任意条目所在存储根（最近/收藏/搜索结果可能来自别的挂载）。
    private func rootContaining(_ id: String) -> String? {
        if id.hasPrefix("/") { return appRoot }
        return mounts
            .map(\.rootId)
            .filter { id == $0 || id.hasPrefix($0 + "/") }
            .max { $0.count < $1.count }
    }

    // MARK: - 列举

    func load(_ id: String) {
        loadSeq += 1
        let seq = loadSeq
        isSearching = false
        isLoading = true
        errorMessage = nil
        offlineCacheMs = nil
        let core = self.core
        let includeHidden = showHidden

        Task {
            let outcome: Result<([Entry], String), Error> = await runOffMain {
                let listed = try core.list(id: id)
                let visible = includeHidden
                    ? listed
                    : listed.filter { !$0.hidden && !$0.name.hasPrefix(".") }
                return (Self.sorted(visible), core.displayPath(id: id))
            }
            guard seq == self.loadSeq else { return }
            switch outcome {
            case .success(let (list, path)):
                self.entries = list
                self.path = path
                self.currentId = id
                self.canGoUp = id != self.rootId
                self.offlineCacheMs = nil
                self.isLoading = false
            case .failure(let failure):
                let cachedResult: Result<(CachedListing, String), Error> = await runOffMain {
                    (core.listCached(id: id), core.displayPath(id: id))
                }
                guard seq == self.loadSeq else { return }
                if case .success(let (cached, cachedPath)) = cachedResult, !cached.entries.isEmpty {
                    let visible = includeHidden
                        ? cached.entries
                        : cached.entries.filter { !$0.hidden && !$0.name.hasPrefix(".") }
                    self.entries = Self.sorted(visible)
                    self.path = cachedPath
                    self.currentId = id
                    self.canGoUp = id != self.rootId
                    self.offlineCacheMs = cached.listedAtMs
                    self.isLoading = false
                } else {
                    self.errorMessage = Self.describe(failure)
                    self.isLoading = false
                }
            }
        }
    }

    nonisolated private static func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted { lhs, rhs in
            let lhsDir = lhs.kind == .directory
            let rhsDir = rhs.kind == .directory
            if lhsDir != rhsDir { return lhsDir }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// 目标选择器用：只返回子文件夹（隐藏规则跟随全局开关）。
    func listDirectories(in id: String) async -> [Entry] {
        let core = self.core
        let includeHidden = showHidden
        let result: Result<[Entry], Error> = await runOffMain {
            let listed = try core.list(id: id)
            let visible = includeHidden
                ? listed
                : listed.filter { !$0.hidden && !$0.name.hasPrefix(".") }
            return Self.sorted(visible.filter { $0.kind == .directory })
        }
        return (try? result.get()) ?? []
    }

    func displayPath(of id: String) -> String {
        core.displayPath(id: id)
    }

    // MARK: - 搜索

    /// 输入防抖：`.task(id: query)` 在每次按键时取消上一个任务，350ms 后才真正搜索。
    func searchAfterDebounce() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard !Task.isCancelled else { return }
        applySearch()
    }

    func applySearch() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            cancelSearch()
            return
        }
        loadSeq += 1
        let seq = loadSeq
        isSearching = true
        listMode = .browser
        isLoading = true
        errorMessage = nil
        let core = self.core

        Task {
            let outcome = await runOffMain { try core.search(query: text, limit: 200) }
            guard seq == self.loadSeq else { return }
            switch outcome {
            case .success(let hits):
                self.entries = hits
                self.path = "搜索：\(text)"
                self.isLoading = false
            case .failure(let failure):
                self.errorMessage = Self.describe(failure)
                self.isLoading = false
            }
        }
    }

    func cancelSearch() {
        guard isSearching, query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSearching = false
        if listMode == .browser { load(currentId) }
    }

    // MARK: - 最近 / 收藏

    func refreshRecent() {
        let core = self.core
        Task {
            let outcome = await runOffMain { try core.recentFiles(limit: 40) }
            if case .success(let list) = outcome { self.recent = list }
        }
    }

    func refreshFavorites() {
        let core = self.core
        Task {
            let outcome: Result<([FavoriteEntry], [String: String]), Error> = await runOffMain {
                let list = try core.favorites(limit: 300)
                var paths: [String: String] = [:]
                for item in list {
                    paths[item.entry.id] = core.displayPath(id: item.entry.id)
                }
                return (list, paths)
            }
            if case .success(let (list, paths)) = outcome {
                self.favorites = list
                self.favoritePaths = paths
                self.favoriteIds = Set(list.map { $0.entry.id })
            }
        }
    }

    func toggleFavorite(_ entry: Entry) {
        let core = self.core
        let adding = !favoriteIds.contains(entry.id)
        Task {
            let outcome: Result<Void, Error> = await runOffMain {
                if adding {
                    try core.addFavorite(id: entry.id)
                } else {
                    try core.removeFavorite(id: entry.id)
                }
            }
            switch outcome {
            case .success:
                self.refreshFavorites()
                self.notice = adding ? "已收藏「\(entry.name)」" : "已取消收藏「\(entry.name)」"
            case .failure(let failure):
                self.errorMessage = Self.describe(failure)
            }
        }
    }

    // MARK: - 编辑

    func createFolder(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let core = self.core
        let parent = currentId
        Task {
            let outcome = await runOffMain { try core.createDir(parent: parent, name: trimmed) }
            switch outcome {
            case .success:
                self.load(parent)
            case .failure(let failure):
                self.errorMessage = Self.describe(failure)
            }
        }
    }

    func rename(_ entry: Entry, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != entry.name else { return }
        let core = self.core
        let parent = currentId
        Task {
            let outcome = await runOffMain { try core.rename(id: entry.id, newName: trimmed) }
            switch outcome {
            case .success:
                if self.selectedEntry?.id == entry.id { self.selectedEntry = nil }
                self.load(parent)
            case .failure(let failure):
                self.errorMessage = Self.describe(failure)
            }
        }
    }

    func delete(_ entry: Entry) {
        let core = self.core
        let parent = currentId
        Task {
            let outcome = await runOffMain {
                try core.remove(id: entry.id, recursive: entry.kind == .directory)
            }
            switch outcome {
            case .success:
                if self.selectedEntry?.id == entry.id { self.selectedEntry = nil }
                self.load(parent)
                self.refreshFavorites()
                self.refreshRecent()
            case .failure(let failure):
                self.errorMessage = Self.describe(failure)
            }
        }
    }

    /// 从「文件」App / 其他 App 导入：security-scoped URL → 内核 fd 直通流式写入。
    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let parent = currentId
        let core = self.core
        Task {
            var imported = 0
            var failures = 0
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let name = Self.uniqueName(core: core, parent: parent, desired: url.lastPathComponent)
                let result: Result<Entry, Error> = await runOffMain {
                    let entry = try core.createFile(parent: parent, name: name)
                    do {
                        let handle = try FileHandle(forReadingFrom: url)
                        defer { try? handle.close() }
                        _ = try core.importFromFd(
                            id: entry.id,
                            fd: handle.fileDescriptor,
                            offset: 0
                        )
                        return entry
                    } catch {
                        _ = try? core.remove(id: entry.id, recursive: false)
                        throw error
                    }
                }
                switch result {
                case .success:
                    imported += 1
                case .failure(let failure):
                    failures += 1
                    NSLog("superfiles import failed: \(url.lastPathComponent): \(failure)")
                }
            }
            self.notice = failures == 0
                ? "已导入 \(imported) 个文件"
                : "导入完成：\(imported) 成功 / \(failures) 失败"
            self.load(parent)
        }
    }

    nonisolated private static func uniqueName(
        core: SuperFiles,
        parent: String,
        desired: String
    ) -> String {
        let ns = desired as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        var name = desired
        var index = 1
        while index < 1000 {
            let id = core.join(parent: parent, name: name)
            if (try? core.stat(id: id)) == nil { return name }
            name = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
            index += 1
        }
        return "\(UUID().uuidString)-\(desired)"
    }

    // MARK: - 索引

    func indexCurrent() {
        let core = self.core
        let id = currentId
        notice = "正在建立索引…"
        Task {
            let outcome = await runOffMain { try core.indexDir(id: id) }
            switch outcome {
            case .success:
                self.indexedCount = core.indexCount()
                self.notice = "索引完成（共 \(self.indexedCount) 项）"
            case .failure(let failure):
                self.errorMessage = Self.describe(failure)
            }
        }
    }

    func refreshIndexCount() {
        let core = self.core
        Task {
            let result = await runOffMain { core.indexCount() }
            self.indexedCount = result.getOrElse(0)
        }
    }

    // MARK: - 传输

    func startTransfer(sources: [String], destDir: String, move: Bool) {
        guard !sources.isEmpty else { return }
        let core = self.core
        Task {
            let outcome: Result<String, Error> = await runOffMain {
                if move {
                    return try core.startMove(sources: sources, destDir: destDir, conflict: .rename)
                }
                return try core.startCopy(sources: sources, destDir: destDir, conflict: .rename)
            }
            switch outcome {
            case .success:
                self.notice = move ? "已开始移动 \(sources.count) 项" : "已开始复制 \(sources.count) 项"
                self.pollTransfers()
            case .failure(let failure):
                self.errorMessage = Self.describe(failure)
            }
        }
    }

    func cancelTransfer(_ id: String) {
        core.cancelTransfer(id: id)
        pollTransfers()
    }

    func resumeTransfer(_ pending: PendingTransfer) {
        let core = self.core
        Task {
            let outcome = await runOffMain { try core.resumeTransfer(id: pending.id) }
            switch outcome {
            case .success:
                self.notice = "继续传输…"
                self.pollTransfers()
            case .failure(let failure):
                self.errorMessage = Self.describe(failure)
            }
        }
    }

    func refreshTransfers() {
        let core = self.core
        Task {
            let snapshotResult = await runOffMain { core.transfers() }
            let pendingResult = await runOffMain { try core.pendingTransfers() }
            self.transfers = snapshotResult.getOrElse([])
            self.pendingTransfers = pendingResult.getOrElse([])
        }
    }

    private func pollTransfers() {
        transferTask?.cancel()
        transferTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let core = self.core
                let snapshotResult = await runOffMain { core.transfers() }
                let pendingResult = await runOffMain { try core.pendingTransfers() }
                let snapshots = snapshotResult.getOrElse([])
                self.transfers = snapshots
                self.pendingTransfers = pendingResult.getOrElse([])
                let active = snapshots.contains { $0.state == .queued || $0.state == .running }
                if !active {
                    if self.listMode == .browser { self.load(self.currentId) }
                    self.refreshIndexCount()
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    // MARK: - 网络存储

    func addMount(_ draft: MountDraft) async throws -> MountedLocation {
        let core = self.core
        let saved = SavedMount(
            id: UUID(),
            label: draft.displayLabel,
            kind: draft.kind,
            host: draft.host,
            share: draft.share,
            port: draft.port,
            username: draft.username,
            rootId: nil
        )
        let result = await runOffMain { try Self.performMount(core: core, mount: saved, password: draft.password) }
        let root = try result.get()

        KeychainStore.save(draft.password, account: saved.id.uuidString)
        var stored = saved
        stored.rootId = root
        savedMounts.append(stored)
        persistSavedMounts()

        let location = MountedLocation(label: stored.label, scheme: stored.kind, rootId: root)
        mounts.append(location)
        return location
    }

    func removeMount(_ location: MountedLocation) {
        _ = core.unmount(rootId: location.rootId)
        mounts.removeAll { $0.rootId == location.rootId }
        if let index = savedMounts.firstIndex(where: { $0.rootId == location.rootId }) {
            KeychainStore.delete(account: savedMounts[index].id.uuidString)
            savedMounts.remove(at: index)
            persistSavedMounts()
        }
        if sidebar == .mount(location.rootId) || rootId == location.rootId {
            sidebar = .appStorage
            activate(.appStorage)
        }
    }

    private func restoreMounts() {
        let saved = savedMounts
        guard !saved.isEmpty else { return }
        let core = self.core
        Task {
            var restored: [MountedLocation] = []
            for item in saved {
                let password = KeychainStore.load(account: item.id.uuidString) ?? ""
                let result = await runOffMain { try Self.performMount(core: core, mount: item, password: password) }
                if case .success(let root) = result {
                    restored.append(MountedLocation(label: item.label, scheme: item.kind, rootId: root))
                    if let index = self.savedMounts.firstIndex(where: { $0.id == item.id }) {
                        self.savedMounts[index].rootId = root
                    }
                }
            }
            self.mounts = restored
            self.persistSavedMounts()
        }
    }

    nonisolated private static func performMount(core: SuperFiles, mount: SavedMount, password: String) throws -> String {
        switch mount.kind {
        case "smb":
            return try core.mountSmb(
                label: mount.label,
                host: mount.host,
                share: mount.share,
                username: mount.username,
                password: password,
                port: UInt32(clamping: mount.port)
            )
        case "sftp":
            return try core.mountSftp(
                label: mount.label,
                host: mount.host,
                port: UInt32(clamping: mount.port),
                username: mount.username,
                password: password
            )
        default:
            return try core.mountWebdav(
                label: mount.label,
                baseUrl: mount.host,
                username: mount.username,
                password: password
            )
        }
    }

    private func loadSavedMounts() -> [SavedMount] {
        guard let data = UserDefaults.standard.data(forKey: mountsKey) else { return [] }
        return (try? JSONDecoder().decode([SavedMount].self, from: data)) ?? []
    }

    private func persistSavedMounts() {
        if let data = try? JSONEncoder().encode(savedMounts) {
            UserDefaults.standard.set(data, forKey: mountsKey)
        }
    }

    // MARK: - 下载 / 预览 / 分享

    /// 本地条目 id 就是绝对路径；远端条目需要经回环 stream 服务。
    func localFileURL(for entry: Entry) -> URL? {
        guard entry.kind == .file, entry.id.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: entry.id)
    }

    func streamURL(for entry: Entry) -> URL? {
        guard entry.kind == .file else { return nil }
        if let local = localFileURL(for: entry) { return local }
        guard let raw = try? core.streamUrl(id: entry.id) else { return nil }
        return URL(string: raw)
    }

    func downloadToLocal(_ entry: Entry) {
        guard entry.kind == .file else { return }
        if localFileURL(for: entry) != nil {
            notice = "已经是本地文件"
            return
        }
        guard let url = streamURL(for: entry) else {
            notice = "无法生成下载地址"
            return
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let inbox = documents.appendingPathComponent("下载", isDirectory: true)
        BackgroundDownloadManager.shared.download(from: url, suggestedName: entry.name, into: inbox)
        notice = "已开始后台下载「\(entry.name)」"
    }

    /// QuickLook / 分享需要一个真实文件 URL：本地直接给，远端先落到临时目录。
    func localCopy(for entry: Entry) async -> URL? {
        guard entry.kind == .file else { return nil }
        if let local = localFileURL(for: entry) { return local }
        guard let remote = streamURL(for: entry) else {
            errorMessage = "无法生成文件地址"
            return nil
        }
        do {
            let (temporary, _) = try await URLSession.shared.download(from: remote)
            let name = "\(UUID().uuidString)-\(entry.name)"
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            return destination
        } catch {
            errorMessage = "准备文件失败：\(error.localizedDescription)"
            return nil
        }
    }

    func quickLookPayload(for entry: Entry) async -> QuickLookPayload? {
        guard let url = await localCopy(for: entry) else { return nil }
        return QuickLookPayload(url: url)
    }

    func sharePayload(for entry: Entry) async -> SharePayload? {
        guard let url = await localCopy(for: entry) else { return nil }
        return SharePayload(url: url)
    }

    /// 详情页缩略图：本地图片直接解；远端图片读前 8 MiB（超过 12 MiB 不回退）。
    func thumbnail(for entry: Entry) async -> UIImage? {
        guard entry.kind == .file, entry.mime?.hasPrefix("image/") == true else { return nil }
        if let local = localFileURL(for: entry) {
            return UIImage(contentsOfFile: local.path)
        }
        guard entry.size <= 12 * 1024 * 1024 else { return nil }
        let core = self.core
        let cap: UInt64 = 12 * 1024 * 1024
        let length = UInt32(clamping: min(entry.size, cap))
        let result = await runOffMain { try core.readBytes(id: entry.id, offset: 0, len: length) }
        guard case .success(let data) = result else { return nil }
        return UIImage(data: data)
    }

    func dismissError() { errorMessage = nil }
    func dismissNotice() { notice = nil }

    static func describe(_ error: Error) -> String {
        if let sfError = error as? SfError {
            switch sfError {
            case .NotFound(let detail),
                 .PermissionDenied(let detail),
                 .AlreadyExists(let detail),
                 .Unsupported(let detail),
                 .Network(let detail),
                 .InvalidName(let detail),
                 .Io(let detail),
                 .Cancelled(let detail):
                return detail
            }
        }
        return error.localizedDescription
    }
}

private extension Result {
    func getOrElse(_ fallback: Success) -> Success {
        (try? get()) ?? fallback
    }
}
