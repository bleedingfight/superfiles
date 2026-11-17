import Foundation

enum ExternalCopyError: LocalizedError {
    case noStreamURL
    case notEnoughSpace(String)

    var errorDescription: String? {
        switch self {
        case .noStreamURL: return "无法生成文件流地址"
        case .notEnoughSpace(let message): return message
        }
    }
}

/// 带字节进度的单文件下载；用于把网络视频完整复制到临时目录后交给 VLC 等 App。
final class ProgressDownloader: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let onProgress: (Int64, Int64?) -> Void
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URL, Error>?
    private var completedURL: URL?
    private var failure: Error?
    private let lock = NSLock()

    init(destination: URL, onProgress: @escaping (Int64, Int64?) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
        super.init()
    }

    func start(from url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                lock.unlock()

                let configuration = URLSessionConfiguration.default
                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: nil
                )
                self.session = session
                let task = session.downloadTask(with: url)
                self.task = task
                task.resume()
            }
        } onCancel: {
            self.task?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        onProgress(totalBytesWritten, total)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: location, to: destination)
            lock.lock()
            completedURL = destination
            lock.unlock()
        } catch {
            lock.lock()
            failure = error
            lock.unlock()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let result: Result<URL, Error>
        if let error {
            result = .failure(error)
        } else if let failure {
            result = .failure(failure)
        } else if let completedURL {
            result = .success(completedURL)
        } else {
            result = .failure(ExternalCopyError.noStreamURL)
        }
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        session.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }
}
