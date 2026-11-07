import Foundation

/// Observable wrapper around the Rust core for SwiftUI.
///
/// The core API is synchronous on purpose (see `crates/sfiles-ffi`), so every
/// call is pushed to a detached task and the result is applied on the main
/// actor. That keeps the existing synchronous core contract while giving the UI
/// structured concurrency.
@MainActor
final class VfsStore: ObservableObject {
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var currentId: String = ""
    @Published private(set) var path: String = ""
    @Published private(set) var isLoading = false
    @Published private(set) var canGoUp = false
    @Published private(set) var indexedCount: UInt64 = 0
    @Published var errorMessage: String?

    private let core: SuperFiles
    private var history: [String] = []

    init() {
        let fileManager = FileManager.default
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let meta = documents.appendingPathComponent(".superfiles", isDirectory: true)
        try? fileManager.createDirectory(at: meta, withIntermediateDirectories: true)
        do {
            let opened = try SuperFiles.open(
                localRoot: documents.path,
                indexPath: meta.appendingPathComponent("index.sqlite").path
            )
            core = opened
            currentId = opened.rootId()
        } catch {
            fatalError("Super Files core failed to start: \(error)")
        }
    }

    var title: String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? "Super Files" : name
    }

    var subtitle: String {
        guard indexedCount > 0 else { return path }
        return "\(path) · 已索引 \(indexedCount) 项"
    }

    func start() {
        guard entries.isEmpty else { return }
        load(currentId)
    }

    func open(_ entry: Entry) {
        guard entry.kind == .directory else { return }
        history.append(currentId)
        load(entry.id)
    }

    func goUp() {
        if let previous = history.popLast() {
            load(previous)
        } else if currentId != core.rootId() {
            load(core.rootId())
        }
    }

    func load(_ id: String) {
        isLoading = true
        errorMessage = nil
        let core = self.core
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<[Entry], Error> in
                Result { try core.list(id: id) }
            }.value
            switch outcome {
            case .success(let list):
                entries = list
                path = core.displayPath(id: id)
                currentId = id
                canGoUp = id != core.rootId()
            case .failure(let failure):
                errorMessage = Self.describe(failure)
            }
            isLoading = false
        }
    }

    func createFolder(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let core = self.core
        let parent = currentId
        Task {
            let failure = await Task.detached(priority: .userInitiated) { () -> Error? in
                do {
                    _ = try core.createDir(parent: parent, name: trimmed)
                    return nil
                } catch {
                    return error
                }
            }.value
            if let failure {
                errorMessage = Self.describe(failure)
            } else {
                load(parent)
            }
        }
    }

    func delete(_ entry: Entry) {
        let core = self.core
        let parent = currentId
        Task {
            let failure = await Task.detached(priority: .userInitiated) { () -> Error? in
                do {
                    try core.remove(id: entry.id, recursive: entry.kind == .directory)
                    return nil
                } catch {
                    return error
                }
            }.value
            if let failure {
                errorMessage = Self.describe(failure)
            } else {
                load(parent)
            }
        }
    }

    func indexAll() {
        let core = self.core
        Task {
            let outcome = await Task.detached(priority: .utility) { () -> Result<UInt64, Error> in
                Result {
                    _ = try core.indexDir(id: core.rootId())
                    return core.indexCount()
                }
            }.value
            switch outcome {
            case .success(let count):
                indexedCount = count
            case .failure(let failure):
                errorMessage = Self.describe(failure)
            }
        }
    }

    func search(_ rawQuery: String) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            load(currentId)
            return
        }
        let core = self.core
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<[Entry], Error> in
                Result { try core.search(query: query, limit: 200) }
            }.value
            switch outcome {
            case .success(let hits):
                entries = hits
                path = "搜索：\(query)"
            case .failure(let failure):
                errorMessage = Self.describe(failure)
            }
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    private static func describe(_ error: Error) -> String {
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
