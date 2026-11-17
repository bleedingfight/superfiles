import Foundation
import SwiftUI
import UIKit
import AudioToolbox

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
    @Published private(set) var indexedBytes: Int64 = 0
    @Published private(set) var lastIndexedAt: Date?
    @Published private(set) var isIndexing = false

    // 近邻传输（LocalSend）
    @Published private(set) var localSendRunning = false
    @Published private(set) var localSendBusy = false
    @Published private(set) var localSendInfo: LocalSendInfo?
    @Published private(set) var localSendPeers: [LocalSendPeer] = []
    @Published private(set) var localSendErrors: [String] = []
    @Published private(set) var localSendStartError: String?
    @Published private(set) var localSendSendError: String?

    // 就近分享（链接 + 二维码）
    @Published private(set) var shareInfo: ShareInfo?
    @Published private(set) var shareBusy = false

    // 状态
    @Published private(set) var isLoading = false
    @Published private(set) var offlineCacheMs: Int64?
    @Published var notice: String?
    @Published var errorMessage: String?

    // 传输
    @Published private(set) var transfers: [TransferSnapshot] = []
    @Published private(set) var pendingTransfers: [PendingTransfer] = []
    @Published private(set) var transferRates: [String: Int64] = [:]
    /// 传输开始时的友好名称（文件名/文件夹名），结束后原始快照不再带 current。
    @Published private(set) var transferLabels: [String: String] = [:]
    /// 前台传输：复制/移动刚开始只在 App 内显示进度浮层（带「终止 / 后台传输」），
    /// 用户点「后台传输」（或 App 退到后台）后才进传输中心。
    @Published private(set) var foregroundTransferIds: Set<String> = []
    @Published private(set) var foregroundMoveIds: Set<String> = []

    /// 浮层展示用：当前仍在前台集合里的任务快照。
    var foregroundTransfers: [TransferSnapshot] {
        transfers.filter { foregroundTransferIds.contains($0.id) }
    }

    let appRoot: String
    let core: SuperFiles

    private var history: [String] = []
    private var loadSeq = 0
    private var transferTask: Task<Void, Never>?
    private var localSendHandle: LocalSendHandle?
    private var localSendPollTask: Task<Void, Never>?
    private var savedMounts: [SavedMount] = []
    private let mountsKey = "saved_network_mounts_v1"
    private var indexURL: URL?
    private static let lastIndexKey = "sf.index.lastIndexedAt"
    private static let localSendDestKey = "sf.localsend.destId"
    private static let localSendDestNameKey = "sf.localsend.destName"

    private struct RateSample {
        var time: TimeInterval = 0
        var bytes: [String: UInt64] = [:]
        var rates: [String: Int64] = [:]
    }
    private var rateSample = RateSample()
    private var activeTransferIds: Set<String> = []

    init() {
        let fileManager = FileManager.default
        // 清理上次播放/复制失败留下的临时文件（20GB 电影复制失败会留下几个 GB）。
        Self.cleanupStaleTemporaryFiles()
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let meta = documents.appendingPathComponent(".superfiles", isDirectory: true)
        try? fileManager.createDirectory(at: meta, withIntermediateDirectories: true)
        let indexURL = meta.appendingPathComponent("index.sqlite")
        self.indexURL = indexURL

        do {
            core = try SuperFiles.open(
                localRoot: documents.path,
                indexPath: indexURL.path
            )
        } catch {
            fatalError("Super Files core failed to start: \(error)")
        }

        if let ms = UserDefaults.standard.object(forKey: Self.lastIndexKey) as? Double {
            lastIndexedAt = Date(timeIntervalSince1970: ms / 1000)
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
            if currentId == appRoot { return "应用存储" }
            if let mount = mounts.first(where: { currentId == $0.rootId }) {
                return mount.label
            }
            let name = (path as NSString).lastPathComponent
            return name.isEmpty ? "文件" : name
        }
    }

    var subtitle: String {
        switch listMode {
        case .recent: return "\(recent.count) 项"
        case .favorites: return "\(favorites.count) 项"
        case .transfers: return "\(activeTransferCount) 个进行中"
        case .browser: return friendlyPath(path)
        }
    }

    /// 状态栏不展示沙盒绝对路径或网络存储地址；只显示「位置 / 相对路径」。
    private func friendlyPath(_ value: String) -> String {
        if value.contains("://") {
            guard let mount = mounts
                .filter({ value == $0.rootId || value.hasPrefix($0.rootId + "/") })
                .max(by: { $0.rootId.count < $1.rootId.count })
            else { return "" }
            let relative = value
                .dropFirst(mount.rootId.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return relative.isEmpty ? mount.label : "\(mount.label) / \(relative)"
        }
        guard value.hasPrefix("/") else { return value }
        let root = URL(fileURLWithPath: appRoot).standardizedFileURL.path
        let current = URL(fileURLWithPath: value).standardizedFileURL.path
        if current == root { return "应用存储" }
        if current.hasPrefix(root + "/") {
            let relative = String(current.dropFirst(root.count + 1))
            return "应用存储 / \(relative)"
        }
        return value
    }

    var activeTransferCount: Int {
        transfers.filter {
            $0.state == .queued || $0.state == .running || $0.state == .paused
        }.count
    }

    var version: String { core.version() }

    func isFavorite(_ entry: Entry) -> Bool { favoriteIds.contains(entry.id) }

    // MARK: - 位置 / 目录导航

    /// 选中一个位置并加载。重复点击同一位置也会重新加载（用于手动刷新网络挂载）。
    func activate(_ selection: SidebarSelection) {
        sidebar = selection
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
        path = core.displayPath(id: id)
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
            // 列表按 opened_ms 倒序；同名文件只保留最近打开的那一条。
            let outcome = await runOffMain { try core.recentFiles(limit: 80) }
            if case .success(let list) = outcome {
                var seen = Set<String>()
                let unique = list.filter {
                    seen.insert($0.entry.name.lowercased()).inserted
                }
                self.recent = Array(unique.prefix(40))
            }
        }
    }

    /// 从「最近打开」移除一条记录；原文件保持不变。
    func removeRecent(_ entry: Entry) {
        let core = self.core
        Task {
            let outcome = await runOffMain { try core.removeRecent(id: entry.id) }
            switch outcome {
            case .success:
                self.refreshRecent()
            case .failure(let failure):
                self.errorMessage = Self.describe(failure)
            }
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
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
        index(id: currentId)
    }

    /// 重建整个根（应用存储）的索引；「存储管理」里的手动入口。
    func indexRoot() {
        index(id: rootId)
    }

    private func index(id: String) {
        guard !isIndexing else { return }
        let core = self.core
        isIndexing = true
        notice = "正在建立索引…"
        Task {
            let outcome = await runOffMain { try core.indexDir(id: id) }
            self.isIndexing = false
            switch outcome {
            case .success:
                self.markIndexed()
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
            self.indexedBytes = self.currentIndexBytes()
        }
    }

    func clearIndex() {
        let core = self.core
        Task {
            let result: Result<Void, Error> = await runOffMain { try core.clearIndex() }
            switch result {
            case .success:
                self.indexedCount = 0
                self.indexedBytes = 0
                self.lastIndexedAt = nil
                UserDefaults.standard.removeObject(forKey: Self.lastIndexKey)
                self.notice = "索引已清理"
            case .failure(let failure):
                self.errorMessage = Self.describe(failure)
            }
        }
    }

    private func markIndexed() {
        indexedCount = core.indexCount()
        indexedBytes = currentIndexBytes()
        lastIndexedAt = Date()
        if let lastIndexedAt {
            UserDefaults.standard.set(
                lastIndexedAt.timeIntervalSince1970 * 1000,
                forKey: Self.lastIndexKey
            )
        }
    }

    private func currentIndexBytes() -> Int64 {
        guard let indexURL else { return 0 }
        let attrs = try? FileManager.default.attributesOfItem(atPath: indexURL.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// 生成可分享的诊断文本（版本 / 设备 / 索引 / 挂载 / 传输）。
    func createDiagnosticsFile() -> URL? {
        let bundle = Bundle.main
        let appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        let device = UIDevice.current

        var lines: [String] = []
        lines.append("Super Files 诊断")
        lines.append("生成时间: \(Fmt.date.string(from: Date()))")
        lines.append("App: \(appVersion) (\(build)) · core v\(version) · \(bundle.bundleIdentifier ?? "-")")
        lines.append("设备: \(device.model) · \(device.systemName) \(device.systemVersion)")
        let bytes = Fmt.bytes.string(fromByteCount: indexedBytes)
        lines.append("索引: \(indexedCount) 项 · \(bytes)")
        lines.append("上次扫描: \(lastIndexedAt.map { Fmt.date.string(from: $0) } ?? "无")")
        let mountText = mounts.isEmpty
            ? "无"
            : mounts.map { "\($0.label)(\($0.scheme))" }.joined(separator: ", ")
        lines.append("网络存储: \(mountText)")
        let transferText = transfers.isEmpty
            ? "无"
            : transfers.map { "\($0.id)=\($0.state) \($0.bytesDone)/\($0.bytesTotal)" }
                .joined(separator: ", ")
        lines.append("传输: \(transferText)")
        let pendingText = pendingTransfers.isEmpty
            ? "无"
            : pendingTransfers.map(\.id).joined(separator: ", ")
        lines.append("可恢复传输: \(pendingText)")
        lines.append("LocalSend: \(localSendRunning ? "已开启" : "未开启") · \(localSendPeers.count) 台附近设备")
        if let info = localSendInfo {
            lines.append("LocalSend 本机: \(info.alias) · 端口 \(info.port) · 指纹 \(info.fingerprint)")
        }
        if let start = localSendStartError {
            lines.append("LocalSend 启动错误: \(start)")
        }
        if let send = localSendSendError {
            lines.append("LocalSend 发送错误: \(send)")
        }
        if !localSendErrors.isEmpty {
            lines.append("LocalSend 诊断: \(localSendErrors.suffix(5).joined(separator: " | "))")
        }
        lines.append("就近分享: \(shareInfo?.url ?? "未开启")")

        let directory = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("diagnostics", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = "diagnostics-\(Int(Date().timeIntervalSince1970 * 1000)).txt"
            let url = directory.appendingPathComponent(name)
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            errorMessage = "导出诊断失败：\(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - 近邻传输（LocalSend）

    /// 近邻传输接收位置：用户设置优先，默认应用根目录。
    var localSendDestDir: String {
        if let saved = UserDefaults.standard.string(forKey: Self.localSendDestKey),
           !saved.isEmpty {
            return saved
        }
        return appRoot
    }

    var localSendDestName: String {
        if let saved = UserDefaults.standard.string(forKey: Self.localSendDestNameKey),
           !saved.isEmpty {
            return saved
        }
        return "应用存储"
    }

    /// 用户选择接收位置（本地目录 / 网络挂载）；运行中会自动重启监听以生效。
    func setLocalSendDestination(_ id: String, name: String) {
        guard !id.isEmpty else { return }
        UserDefaults.standard.set(id, forKey: Self.localSendDestKey)
        UserDefaults.standard.set(name, forKey: Self.localSendDestNameKey)
        if localSendRunning {
            stopLocalSend()
            startLocalSend()
        }
    }

    private var localSendStoreDir: String {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents
            .appendingPathComponent(".superfiles/localsend", isDirectory: true)
            .path
    }

    func ensureLocalSendStarted() {
        guard !localSendRunning, !localSendBusy else { return }
        startLocalSend()
    }

    func startLocalSend() {
        guard !localSendRunning, !localSendBusy else { return }
        localSendBusy = true
        localSendStartError = nil
        localSendSendError = nil
        let core = self.core
        let alias = UIDevice.current.name.isEmpty ? "Super Files" : UIDevice.current.name
        let deviceModel = UIDevice.current.model
        let dest = localSendDestDir
        let storeDir = localSendStoreDir

        Task {
            let outcome: Result<(LocalSendHandle, LocalSendInfo), Error> = await runOffMain {
                // 本地目录才需要创建；网络挂载 id（webdav://…）不能当本地路径创建
                if dest.hasPrefix("/") {
                    try FileManager.default.createDirectory(
                        atPath: dest,
                        withIntermediateDirectories: true
                    )
                }
                try FileManager.default.createDirectory(
                    atPath: storeDir,
                    withIntermediateDirectories: true
                )
                let options = LocalSendOptions(
                    alias: alias,
                    deviceModel: deviceModel,
                    port: 53317,
                    storeDir: storeDir,
                    destDir: dest,
                    pin: nil,
                    enableDiscovery: true,
                    idleTimeoutSecs: 300
                )
                let handle = try core.startLocalSend(options: options)
                return (handle, handle.info())
            }
            self.localSendBusy = false
            switch outcome {
            case .success(let (handle, info)):
                self.localSendHandle = handle
                self.localSendInfo = info
                self.localSendRunning = true
                self.startLocalSendPolling()
                self.refreshLocalSendPeers()
            case .failure(let failure):
                let detail = Self.describe(failure)
                let message = Self.localSendFriendlyError(detail)
                self.localSendStartError = message
                self.recordLocalSendError("start: \(detail)")
            }
        }
    }

    func stopLocalSend() {
        localSendPollTask?.cancel()
        localSendPollTask = nil
        let handle = localSendHandle
        localSendHandle = nil
        resetLocalSendState()
        if let handle {
            Task.detached { handle.stop() }
        }
    }

    private func resetLocalSendState() {
        localSendRunning = false
        localSendBusy = false
        localSendInfo = nil
        localSendPeers = []
        localSendErrors = []
        localSendStartError = nil
        localSendSendError = nil
    }

    /// 广播一次并拉取设备列表。没有服务时自动开启。
    func refreshLocalSendPeers() {
        guard let handle = localSendHandle else {
            ensureLocalSendStarted()
            return
        }
        Task {
            _ = await runOffMain { handle.announce() }
            try? await Task.sleep(nanoseconds: 500_000_000)
            let outcome: Result<([LocalSendPeer], [String]), Error> = await runOffMain {
                (handle.peers(), handle.errors())
            }
            if case .success(let (peers, errors)) = outcome {
                self.localSendPeers = self.pruneStalePeers(peers)
                self.localSendErrors = errors
            }
        }
    }

    /// 手动 IP 兜底：组播被 AP 隔离时直接连对方。成功返回 nil，失败返回错误文案。
    func registerLocalSendPeer(ip: String, port: UInt16, fingerprint: String?) async -> String? {
        guard let handle = localSendHandle else {
            return "请先开启近邻传输"
        }
        let trimmedIP = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIP.isEmpty else { return "请填写对方 IP" }
        let expected = fingerprint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result: Result<LocalSendPeer, Error> = await runOffMain {
            try handle.registerAt(
                ip: trimmedIP,
                port: port > 0 ? port : 53317,
                fingerprint: (expected?.isEmpty ?? true) ? nil : expected
            )
        }
        switch result {
        case .success(let peer):
            localSendPeers.removeAll { $0.ip == peer.ip && $0.port == peer.port }
            localSendPeers.append(peer)
            return nil
        case .failure(let failure):
            let detail = Self.describe(failure)
            recordLocalSendError("register: \(detail)")
            return Self.localSendFriendlyError(detail)
        }
    }

    /// LocalSend 只传文件；文件夹请在调用方先压缩。
    func sendViaLocalSend(
        peer: LocalSendPeer,
        entries: [Entry],
        onSuccess: (() -> Void)? = nil
    ) {
        guard let handle = localSendHandle else {
            localSendSendError = "请先开启近邻传输"
            return
        }
        let files = entries.filter { $0.kind == .file }
        guard !files.isEmpty else {
            localSendSendError = "仅支持发送文件，文件夹请先压缩"
            return
        }
        localSendSendError = nil
        localSendBusy = true
        Task {
            let result: Result<Void, Error> = await runOffMain {
                try handle.send(peer: peer, ids: files.map(\.id))
            }
            self.localSendBusy = false
            switch result {
            case .success:
                self.playTransferDoneSound()
                onSuccess?()
            case .failure(let failure):
                let detail = Self.describe(failure)
                let message = Self.localSendFriendlyError(detail)
                self.localSendSendError = message
                self.recordLocalSendError("send: \(detail)")
                if Self.isPeerUnreachable(detail) {
                    self.localSendPeers.removeAll {
                        $0.ip == peer.ip && $0.port == peer.port
                    }
                }
            }
        }
    }

    private func recordLocalSendError(_ text: String) {
        localSendErrors.append(text)
        if localSendErrors.count > 20 {
            localSendErrors.removeFirst(localSendErrors.count - 20)
        }
    }

    /// 只保留最近 20 秒内有广播的设备，避免点了已关闭 App 的过期条目。
    private func pruneStalePeers(_ peers: [LocalSendPeer]) -> [LocalSendPeer] {
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        return peers.filter { peer in
            guard peer.lastSeenMs > 0, now > peer.lastSeenMs else { return true }
            return now - peer.lastSeenMs < 20_000
        }
    }

    private static func isPeerUnreachable(_ detail: String) -> Bool {
        let text = detail.lowercased()
        return text.contains("connection refused")
            || text.contains("no route to host")
            || text.contains("network is unreachable")
    }

    /// 把底层 io/tls 文案翻成可操作提示，原始详情保留在「协议诊断」里。
    static func localSendFriendlyError(_ detail: String) -> String {
        let text = detail.lowercased()
        if text.contains("connection refused") {
            return "对方没有在接收文件。请让对方打开「近邻传输」并保持前台，然后刷新设备再试。"
        }
        if text.contains("no route to host") || text.contains("network is unreachable") {
            return "网络不可达。请确认两台设备连在同一个 Wi-Fi，并检查 iPad 的「本地网络」权限。"
        }
        if text.contains("operation not permitted") || text.contains("permission denied") {
            return "本地网络权限被拒绝。请到 设置 → 隐私与安全性 → 本地网络，打开 Super Files。"
        }
        if text.contains("address already in use") {
            return "端口 53317 被占用。请关闭其他 LocalSend 应用后重试。"
        }
        if text.contains("certificate fingerprint mismatch") {
            return "对方证书指纹已变化（可能重装过 App）。请刷新设备列表后重试。"
        }
        if text.contains("timed out") || text.contains("timeout") {
            return "连接超时。请确认对方仍开着近邻传输且在同一 Wi-Fi。"
        }
        return detail
    }

    private func startLocalSendPolling() {
        localSendPollTask?.cancel()
        localSendPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let handle = self.localSendHandle else { return }
                let outcome: Result<(Bool, [LocalSendPeer], [String]), Error> = await runOffMain {
                    (handle.isRunning(), handle.peers(), handle.errors())
                }
                if case .success(let (running, peers, errors)) = outcome {
                    self.localSendPeers = self.pruneStalePeers(peers)
                    self.localSendErrors = errors
                    if !running {
                        self.stopLocalSend()
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    // MARK: - 就近分享（链接 + 二维码）

    func startShare(entries: [Entry]) {
        let files = entries.filter { $0.kind == .file }
        guard !files.isEmpty else {
            errorMessage = "仅支持分享文件，文件夹请先压缩"
            return
        }
        shareBusy = true
        let core = self.core
        Task {
            let result: Result<ShareInfo, Error> = await runOffMain {
                try core.startShare(ids: files.map(\.id))
            }
            self.shareBusy = false
            switch result {
            case .success(let info):
                self.shareInfo = info
            case .failure(let failure):
                self.errorMessage = Self.describe(failure)
            }
        }
    }

    func stopShare() {
        guard shareInfo != nil else { return }
        _ = core.stopShare()
        shareInfo = nil
        shareBusy = false
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
            case .success(let id):
                self.transferLabels[id] = Self.transferLabel(
                    sources: sources,
                    count: UInt64(sources.count)
                )
                activeTransferIds.insert(id)
                foregroundTransferIds.insert(id)
                if move { foregroundMoveIds.insert(id) }
                self.pollTransfers()
            case .failure(let failure):
                self.errorMessage = Self.describe(failure)
            }
        }
    }

    private static func transferLabel(sources: [String], count: UInt64) -> String {
        let first = sources.first.map {
            ($0 as NSString).lastPathComponent
        } ?? "传输"
        return count > 1 ? "\(first) 等 \(count) 项" : first
    }

    func cancelTransfer(_ id: String) {
        core.cancelTransfer(id: id)
        pollTransfers()
    }

    /// 前台进度浮层 →「后台传输」：只是把任务交给传输中心展示，引擎任务本身不中断。
    func sendForegroundTransfersToBackground() {
        foregroundTransferIds.removeAll()
        foregroundMoveIds.removeAll()
    }

    /// 前台进度浮层 →「终止」：取消这批任务并收起浮层。
    func cancelForegroundTransfers() {
        let ids = foregroundTransferIds
        foregroundTransferIds.removeAll()
        foregroundMoveIds.removeAll()
        guard !ids.isEmpty else { return }
        for id in ids { core.cancelTransfer(id: id) }
        notice = "已终止传输"
        pollTransfers()
    }

    /// App 退到后台时调用：浮层已不可见，自动等价于按下「后台传输」。
    func promoteForegroundTransfers() {
        sendForegroundTransfersToBackground()
    }

    func resumeTransfer(_ pending: PendingTransfer) {
        let core = self.core
        Task {
            let outcome = await runOffMain { try core.resumeTransfer(id: pending.id) }
            switch outcome {
            case .success:
                self.transferLabels[pending.id] = Self.transferLabel(
                    sources: pending.sources,
                    count: pending.filesTotal
                )
                self.activeTransferIds.insert(pending.id)
                // 直接继续，不再弹「继续传输…」提示打断操作。
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
            let snapshots = snapshotResult.getOrElse([])
            self.transfers = snapshots
            self.pendingTransfers = pendingResult.getOrElse([])
            self.updateTransferRates(snapshots)
            self.pruneFinishedForeground(snapshots)
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
                self.updateTransferRates(snapshots)
                self.pruneFinishedForeground(snapshots)
                self.notifyTransferCompletion(snapshots)
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

    /// 一批传输全部完成时「叮」一声（取消/失败不响）。
    private func notifyTransferCompletion(_ snapshots: [TransferSnapshot]) {
        let activeNow = Set(
            snapshots
                .filter { $0.state == .queued || $0.state == .running }
                .map(\.id)
        )
        let completed = snapshots.contains { snapshot in
            activeTransferIds.contains(snapshot.id)
                && !activeNow.contains(snapshot.id)
                && snapshot.state == .completed
        }
        activeTransferIds = activeNow
        if completed {
            playTransferDoneSound()
        }
    }

    private func playTransferDoneSound() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        AudioServicesPlaySystemSound(1103) // Tink
    }

    /// 轮询差值 + EMA 平滑，给浮层/传输中心显示实时速度。
    private func updateTransferRates(_ snapshots: [TransferSnapshot]) {
        let now = Date().timeIntervalSince1970
        let previous = rateSample
        let elapsed = now - previous.time
        var bytes: [String: UInt64] = [:]
        var rates: [String: Int64] = [:]
        for snapshot in snapshots where snapshot.state == .running {
            bytes[snapshot.id] = snapshot.bytesDone
            if previous.time > 0, elapsed > 0.1, let last = previous.bytes[snapshot.id] {
                let delta = snapshot.bytesDone > last ? snapshot.bytesDone - last : 0
                let instant = Int64(Double(delta) / elapsed)
                let ema = previous.rates[snapshot.id]
                    .map { Int64(Double($0) * 0.6 + Double(instant) * 0.4) }
                    ?? instant
                rates[snapshot.id] = ema
            } else {
                rates[snapshot.id] = previous.rates[snapshot.id] ?? 0
            }
        }
        rateSample = RateSample(time: now, bytes: bytes, rates: rates)
        transferRates = rates
    }

    /// 前台浮层里的任务结束（完成/失败/取消）→ 自动收起浮层。
    private func pruneFinishedForeground(_ snapshots: [TransferSnapshot]) {
        guard !foregroundTransferIds.isEmpty else { return }
        let ended = snapshots
            .filter {
                foregroundTransferIds.contains($0.id)
                    && $0.state != .queued
                    && $0.state != .running
                    // 防御：浮层没有暂停入口，但若未来接入，别把暂停误判成结束
                    && $0.state != .paused
            }
            .map(\.id)
        guard !ended.isEmpty else { return }
        foregroundTransferIds.subtract(ended)
        foregroundMoveIds.subtract(ended)
    }

    // MARK: - 网络存储

    /// 临时挂载并 PROPFIND 根目录，验证地址与凭据；不写入钥匙串/已保存列表。
    func testWebdavConnection(host: String, username: String, password: String) async throws {
        let core = self.core
        let result: Result<Void, Error> = await runOffMain {
            let existing = Set(core.mounts().map(\.rootId))
            let root = try core.mountWebdav(
                label: "连接测试",
                baseUrl: host,
                username: username,
                password: password
            )
            defer {
                if !existing.contains(root) {
                    _ = core.unmount(rootId: root)
                }
            }
            _ = try core.list(id: root)
        }
        try result.get()
    }

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

    /// 侧栏「编辑连接」用：按当前挂载找到持久化配置（密码在 Keychain，不随配置返回）。
    func savedMount(for location: MountedLocation) -> SavedMount? {
        savedMounts.first { $0.rootId == location.rootId }
    }

    /// 编辑网络存储：卸载旧挂载 → 用新配置重挂载 → 更新 Keychain / 已保存列表。
    /// 新配置连接失败时尽量恢复原连接，避免编辑失败导致位置凭空消失。
    func updateMount(_ old: SavedMount, draft: MountDraft) async throws -> MountedLocation {
        let core = self.core
        let fallbackPassword = KeychainStore.load(account: old.id.uuidString) ?? ""
        let oldRoot = old.rootId
        if let oldRoot { _ = core.unmount(rootId: oldRoot) }

        var updated = old
        updated.label = draft.displayLabel
        updated.kind = draft.kind
        updated.host = draft.host
        updated.share = draft.share
        updated.port = draft.port
        updated.username = draft.username
        updated.rootId = nil
        let candidate = updated

        let result = await runOffMain {
            try Self.performMount(core: core, mount: candidate, password: draft.password)
        }
        switch result {
        case .success(let newRoot):
            updated.rootId = newRoot
            KeychainStore.save(draft.password, account: old.id.uuidString)
            if let index = savedMounts.firstIndex(where: { $0.id == old.id }) {
                savedMounts[index] = updated
            } else {
                savedMounts.append(updated)
            }
            persistSavedMounts()

            let location = MountedLocation(label: updated.label, scheme: updated.kind, rootId: newRoot)
            if let index = mounts.firstIndex(where: { $0.rootId == oldRoot }) {
                mounts[index] = location
            } else {
                mounts.append(location)
            }
            if rootId == oldRoot || sidebar == .mount(oldRoot ?? "") {
                activate(.mount(newRoot))
            }
            return location

        case .failure(let error):
            // 编辑失败：恢复旧连接，保留原来的位置与索引引用。
            if let oldRoot {
                let restore = await runOffMain {
                    try Self.performMount(core: core, mount: old, password: fallbackPassword)
                }
                if case .success(let restoredRoot) = restore {
                    if let index = savedMounts.firstIndex(where: { $0.id == old.id }) {
                        savedMounts[index].rootId = restoredRoot
                        persistSavedMounts()
                    }
                    let restored = MountedLocation(label: old.label, scheme: old.kind, rootId: restoredRoot)
                    if let index = mounts.firstIndex(where: { $0.rootId == oldRoot }) {
                        mounts[index] = restored
                    } else {
                        mounts.append(restored)
                    }
                    if rootId == oldRoot || sidebar == .mount(oldRoot) {
                        activate(.mount(restoredRoot))
                    }
                }
            }
            throw error
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

    /// 启动时清理我们自己的临时残留：播放缓存、URLSession 下载临时文件和
    /// 交给 QuickLook/外部 App 的 UUID 副本。超过 1 小时未再写入的才删，
    /// 避免误删正在后台续传/仍在使用的文件。
    private static func cleanupStaleTemporaryFiles() {
        let fileManager = FileManager.default
        let tmp = fileManager.temporaryDirectory
        let cutoff = Date().addingTimeInterval(-60 * 60)
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .creationDateKey]
        guard let items = try? fileManager.contentsOfDirectory(
            at: tmp,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }

        let uuidPrefix = try! NSRegularExpression(
            pattern: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}-"#
        )
        for url in items {
            let name = url.lastPathComponent
            // 播放缓存是本次会话独有的，启动时一律可删。
            if name.hasPrefix("superfiles-play-") {
                try? fileManager.removeItem(at: url)
                continue
            }
            let isOurs = name.hasPrefix("CFNetworkDownload_")
                || uuidPrefix.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
            guard isOurs else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let modified = values.contentModificationDate ?? values.creationDate ?? .distantPast
            if modified < cutoff {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    /// 临时目录可用空间（优先用 iOS 的 important-usage 口径）。
    private func availableTemporarySpace() -> Int64? {
        let tmp = FileManager.default.temporaryDirectory
        if let values = try? tmp.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: tmp.path),
              let free = attrs[.systemFreeSize] as? NSNumber else { return nil }
        return free.int64Value
    }

    /// 完整复制远端文件需要「文件大小 + 256 MiB 余量」；不足时给出明确原因，
    /// 而不是让 URLSession 报成「无法连接服务器」。
    private func spaceShortage(for entry: Entry) -> String? {
        guard let available = availableTemporarySpace() else { return nil }
        let needed = Int64(clamping: entry.size) + 256 * 1024 * 1024
        guard available < needed else { return nil }
        return "存储空间不足：复制「\(entry.name)」需要约 \(Fmt.bytes.string(fromByteCount: needed))，当前可用 \(Fmt.bytes.string(fromByteCount: available))"
    }

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

    /// 播放结束：删除「边播边缓存」的临时文件（WebDAV 不支持 Range 时使用）。
    /// 本地文件本来就没有缓存，直接忽略。
    func releaseStream(_ entry: Entry) {
        guard entry.kind == .file, !entry.id.hasPrefix("/") else { return }
        core.releaseStream(id: entry.id)
    }

    /// 该条目所属 WebDAV 挂载的服务器直链（含 Basic 凭据），用于交给
    /// Infuse / VLC 直接边读边播，避免先整份下载。
    func directWebdavURL(for entry: Entry) -> URL? {
        guard entry.kind == .file else { return nil }
        guard let mount = savedMounts.first(where: { candidate in
            guard candidate.kind == "webdav", let rootId = candidate.rootId else { return false }
            return entry.id.hasPrefix(rootId)
        }) else { return nil }
        guard var url = URL(string: mount.host) else { return nil }

        let rootId: String
        if let saved = mount.rootId {
            rootId = saved
        } else {
            let host = url.host ?? ""
            let port = url.port.map { ":\($0)" } ?? ""
            rootId = "webdav://\(host)\(port)/"
        }
        guard entry.id.hasPrefix(rootId) else { return nil }
        let relative = entry.id.dropFirst(rootId.count)
        for segment in relative.split(separator: "/", omittingEmptySubsequences: true) {
            url.appendPathComponent(String(segment))
        }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if !mount.username.isEmpty { components.user = mount.username }
        if let password = KeychainStore.load(account: mount.id.uuidString), !password.isEmpty {
            components.password = password
        }
        return components.url
    }

    /// 生成外部播放器的 x-callback-url。参数值按 x-callback-url 规范编码。
    func externalPlayerURL(for entry: Entry, player: ExternalPlayer) -> URL? {
        guard let direct = directWebdavURL(for: entry) else { return nil }
        let encoded = direct.absoluteString
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        guard !encoded.isEmpty else { return nil }
        switch player {
        case .infuse:
            let filename = entry.name
                .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            return URL(string: "infuse://x-callback-url/play?url=\(encoded)&filename=\(filename)")
        case .vlc:
            return URL(string: "vlc-x-callback://x-callback-url/stream?url=\(encoded)")
        }
    }

    /// 能直连该 WebDAV 文件且本机已安装的播放器。
    func installedExternalPlayers(for entry: Entry) -> [ExternalPlayer] {
        guard directWebdavURL(for: entry) != nil else { return [] }
        return ExternalPlayer.allCases.filter(\.isInstalled)
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
    func localCopy(for entry: Entry, silent: Bool = false) async -> URL? {
        guard entry.kind == .file else { return nil }
        if let local = localFileURL(for: entry) { return local }
        if let shortage = spaceShortage(for: entry) {
            if !silent { errorMessage = shortage }
            return nil
        }
        guard let remote = streamURL(for: entry) else {
            if !silent { errorMessage = "无法生成文件地址" }
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
            if !silent {
                errorMessage = "准备文件失败：\(error.localizedDescription)"
            }
            return nil
        }
    }

    /// 完整复制一份到临时目录，带字节进度；用于交给 VLC 等不支持流式读取的外部 App。
    func prepareExternalPlaybackCopy(
        for entry: Entry,
        onProgress: @escaping (Int64, Int64?) -> Void
    ) async throws -> URL {
        if let local = localFileURL(for: entry) { return local }
        if let shortage = spaceShortage(for: entry) {
            throw ExternalCopyError.notEnoughSpace(shortage)
        }
        guard let remote = streamURL(for: entry) else {
            throw ExternalCopyError.noStreamURL
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(entry.name)")
        try? FileManager.default.removeItem(at: destination)
        let downloader = ProgressDownloader(
            destination: destination,
            onProgress: onProgress
        )
        return try await downloader.start(from: remote)
    }

    /// 远端文件交给别的 App 后，删掉我们临时下载的副本；用户自己的本地文件不动。
    func cleanupTemporaryCopy(_ url: URL) {
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(temporary + "/") else { return }
        try? FileManager.default.removeItem(at: url)
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
