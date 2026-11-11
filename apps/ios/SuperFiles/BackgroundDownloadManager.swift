import Foundation

/// M1：HTTP 后端的后台下载（回环 streamUrl / 直连 WebDAV 均适用）。
///
/// 使用 `URLSessionConfiguration.background`：下载由系统守护进程接管——
/// App 切后台/被挂起后下载继续，App 被杀则下载中止（源为 App 内回环
/// stream server 时随进程消失；与 Android 侧「进程杀即停止 + 断点可续」语义对齐）。
/// 完成后系统通过 AppDelegate 的
/// `handleEventsForBackgroundURLSession` 冷启动 App 交还事件。
///
/// 任务 → 目标位置的映射持久化在 UserDefaults，跨启动恢复（M2 传输中心复用）。
final class BackgroundDownloadManager: NSObject {
    static let shared = BackgroundDownloadManager()

    static let sessionIdentifier = "com.superfiles.background-downloads"
    static let didFinishNotification = Notification.Name("BackgroundDownloadDidFinish")

    /// 通知的 userInfo 键：目标文件 URL / 错误描述。
    static let destinationUserInfoKey = "destinationURL"
    static let errorUserInfoKey = "error"

    private let taskMapKey = "background_download_taskmap_v1"
    private let stateLock = NSLock()
    private var completionHandlers: [() -> Void] = []

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false // 插电/无线网省流策略交给用户控制（v1）
        config.sessionSendsLaunchEvents = true
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
        // 触发 lazy session 初始化：恢复系统侧仍存活的任务事件通道
        _ = session
    }

    /// 开始一个后台下载。
    /// - Parameters:
    ///   - url: 下载源（回环 `streamUrl` 或任意 http/https）。
    ///   - suggestedName: 落盘文件名（同名自动加 `-N` 后缀）。
    ///   - directory: 目标目录（默认 Documents/下载/）。
    func download(from url: URL, suggestedName: String, into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let task = session.downloadTask(with: url)
        task.taskDescription = suggestedName
        stateLock.lock()
        var map = taskMap()
        map[String(task.taskIdentifier)] = ["name": suggestedName, "dir": directory.path]
        saveTaskMap(map)
        stateLock.unlock()
        task.resume()
    }

    /// AppDelegate 回调入口：本 session 的后台事件全部就绪后调用它（必须存起稍后调）。
    func storeCompletionHandler(_ handler: @escaping () -> Void) {
        stateLock.lock()
        completionHandlers.append(handler)
        stateLock.unlock()
        // 触发 session 初始化（App 被系统为后台事件冷启动时 delegate 必须先就位）
        _ = session
    }

    // ---- 任务映射持久化（跨进程重启恢复） ----

    private func taskMap() -> [String: [String: String]] {
        UserDefaults.standard.dictionary(forKey: taskMapKey) as? [String: [String: String]] ?? [:]
    }

    private func saveTaskMap(_ map: [String: [String: String]]) {
        UserDefaults.standard.set(map, forKey: taskMapKey)
    }

    private func popTaskMeta(_ taskIdentifier: Int) -> [String: String]? {
        stateLock.lock()
        defer { stateLock.unlock() }
        var map = taskMap()
        let meta = map.removeValue(forKey: String(taskIdentifier))
        saveTaskMap(map)
        return meta
    }

    /// 目标位置：directory/suggestedName，同名自动 `-2` `-3`… 避让（不覆盖）。
    private func uniqueDestination(directory: URL, name: String) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(name)
        var counter = 2
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        while fm.fileExists(atPath: candidate.path) {
            let renamed = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
            candidate = directory.appendingPathComponent(renamed)
            counter += 1
        }
        return candidate
    }
}

extension BackgroundDownloadManager: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // location 在回调返回后即被删除：必须同步搬走（不要 dispatch 出去）。
        guard let meta = popTaskMeta(downloadTask.taskIdentifier),
              let name = meta["name"],
              let dirPath = meta["dir"] else { return }
        let destination = uniqueDestination(directory: URL(fileURLWithPath: dirPath), name: name)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            NotificationCenter.default.post(
                name: Self.didFinishNotification,
                object: nil,
                userInfo: [Self.destinationUserInfoKey: destination]
            )
        } catch {
            NotificationCenter.default.post(
                name: Self.didFinishNotification,
                object: nil,
                userInfo: [Self.errorUserInfoKey: error.localizedDescription]
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let error else { return } // 成功路径已由 didFinishDownloadingTo 处理
        let meta = popTaskMeta(task.taskIdentifier)
        NotificationCenter.default.post(
            name: Self.didFinishNotification,
            object: nil,
            userInfo: [
                Self.errorUserInfoKey: "下载「\(meta?["name"] ?? task.taskDescription ?? "")」失败：\(error.localizedDescription)",
            ]
        )
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        stateLock.lock()
        let handlers = completionHandlers
        completionHandlers.removeAll()
        stateLock.unlock()
        DispatchQueue.main.async { handlers.forEach { $0() } }
    }
}
