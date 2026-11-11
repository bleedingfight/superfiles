import Foundation
import Security
import SwiftUI
import QuickLook
import UIKit

// MARK: - 通用

/// 所有 Rust 内核调用都是同步阻塞的（见 docs/adr/0002），统一丢到后台线程执行。
func runOffMain<T>(_ body: @escaping () throws -> T) async -> Result<T, Error> {
    await Task.detached(priority: .userInitiated) { () -> Result<T, Error> in
        Result { try body() }
    }.value
}

enum Fmt {
    static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func size(_ entry: Entry) -> String {
        guard entry.kind != .directory else { return "—" }
        return bytes.string(fromByteCount: Int64(clamping: entry.size))
    }

    static func modified(_ ms: Int64?) -> String {
        guard let ms, ms > 0 else { return "未知" }
        return date.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    static func detail(_ entry: Entry) -> String {
        guard entry.kind != .directory else { return "文件夹" }
        var parts = [size(entry)]
        if let mime = entry.mime, let sub = mime.split(separator: "/").last {
            parts.append(String(sub))
        }
        if let ms = entry.modifiedMs {
            parts.append(date.string(from: Date(timeIntervalSince1970: Double(ms) / 1000)))
        }
        return parts.joined(separator: " · ")
    }

    static func ext(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    static let videoExts: Set<String> = ["mp4", "mov", "m4v", "mkv", "webm", "avi"]
}

// MARK: - 侧栏模型

enum SidebarSelection: Hashable {
    case appStorage
    case recent
    case favorites
    case transfers
    case mount(String) // rootId
}

enum ListMode: Equatable {
    case browser
    case recent
    case favorites
    case transfers
}

struct MountedLocation: Identifiable, Hashable {
    var id: String { rootId }
    let label: String
    let scheme: String
    let rootId: String
}

struct SavedMount: Codable, Identifiable {
    var id: UUID
    var label: String
    var kind: String // webdav / smb / sftp
    var host: String
    var share: String
    var port: Int
    var username: String
    var rootId: String?
}

struct MountDraft {
    var label: String
    var kind: String
    var host: String
    var share: String
    var port: Int
    var username: String
    var password: String

    var displayLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return host
    }
}

struct SharePayload: Identifiable {
    let id = UUID()
    let url: URL
}

struct QuickLookPayload: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - 凭据

/// 网络存储密码只进 Keychain（account = SavedMount.id）。
enum KeychainStore {
    private static let service = "com.superfiles.mounts"

    static func save(_ value: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        _ = SecItemAdd(add as CFDictionary, nil)
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - 系统分享 / QuickLook

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// PDF / Office / 文本等交给 QuickLook；图片与视频在详情页内联展示。
struct QuickLookSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> QLPreviewItem {
            url as NSURL
        }
    }
}

// MARK: - 通用视图

struct EntryRow: View {
    let entry: Entry
    var selected: Bool = false
    var meta: String? = nil

    var body: some View {
        HStack(spacing: Spacing.s3) {
            Image(systemName: FileIcon.symbolName(for: entry))
                .font(.title3)
                .foregroundStyle(entry.kind == .directory ? Color.accentColor : Color.secondary)
                .frame(width: Spacing.rowIconSlot)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(meta ?? Fmt.detail(entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if entry.kind == .directory {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .listRowBackground(selected ? Color.accentColor.opacity(0.12) : Color.clear)
    }
}

struct EmptyFolderView: View {
    let title: String
    let hint: String

    var body: some View {
        VStack(spacing: Spacing.s2) {
            Image(systemName: "folder")
                .font(.system(size: Spacing.emptyIconSize))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(hint)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.s8)
        .listRowSeparator(.hidden)
    }
}
