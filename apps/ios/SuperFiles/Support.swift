import Foundation
import Security
import SwiftUI
import QuickLook
import UIKit
import UniformTypeIdentifiers

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

    /// HH:mm:ss：传输记录的开始/结束时刻（与鸿蒙 Format.ets formatClock 同口径）。
    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
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

    /// 耗时：45秒 / 3分32秒 / 1小时2分（与鸿蒙 Format.ets formatDuration 同口径）。
    static func duration(_ ms: Int64) -> String {
        var s = Int((Double(ms) / 1000).rounded())
        if s < 0 { s = 0 }
        if s < 60 { return "\(s)秒" }
        let m = s / 60
        let rs = s % 60
        if m < 60 { return rs > 0 ? "\(m)分\(rs)秒" : "\(m)分钟" }
        let h = m / 60
        let rm = m % 60
        return rm > 0 ? "\(h)小时\(rm)分" : "\(h)小时"
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

    /// iOS AVFoundation / QuickLook 能直接播放的容器；MKV/AVI/WebM 需要第三方播放器。
    static let systemVideoExts: Set<String> = [
        "mp4", "m4v", "mov", "3gp", "3g2",
        // MPEG-TS 单文件 AVPlayer 可直接按 Range 流式播放。
        "ts", "m2ts", "mts",
    ]

    static func systemCanPlayVideo(_ entry: Entry) -> Bool {
        systemVideoExts.contains(ext(entry.name))
    }
}

// MARK: - 文档类型 / MIME → UTType

/// 与鸿蒙端 PreviewView.kindOf + OpenExternal.mimeOfName 对齐的文档分类：
/// PDF 走应用内 PDFKit 预览；办公文档等没有系统渲染器的类型走「用其他 App 打开」。
enum DocTypes {
    /// PDF：application/pdf 或 .pdf 后缀。
    static func isPDF(_ entry: Entry) -> Bool {
        if entry.mime == "application/pdf" { return true }
        return Fmt.ext(entry.name) == "pdf"
    }

    /// iOS 没有系统渲染器的已知文档（办公套件 / 文本类），与鸿蒙端 MIME 表对齐。
    static func isExternalDocument(_ entry: Entry) -> Bool {
        !isPDF(entry) && utTypes[Fmt.ext(entry.name)] != nil
    }

    /// MIME/扩展名 → UTType：交给系统 open-in 菜单时按此路由到可处理的应用；未知用 .data。
    static func utType(for entry: Entry) -> UTType {
        if isPDF(entry) { return .pdf }
        return utTypes[Fmt.ext(entry.name)] ?? .data
    }

    // 与鸿蒙端 OpenExternal.mimeOfName 同表
    private static let utTypes: [String: UTType] = [
        "pdf": .pdf,
        "doc": UTType("com.microsoft.word.doc"),
        "docx": UTType("org.openxmlformats.wordprocessingml.document"),
        "xls": UTType("com.microsoft.excel.xls"),
        "xlsx": UTType("org.openxmlformats.spreadsheetml.sheet"),
        "ppt": UTType("com.microsoft.powerpoint.ppt"),
        "pptx": UTType("org.openxmlformats.presentationml.presentation"),
        "txt": .plainText,
        "csv": .commaSeparatedText,
        "md": UTType("net.daringfireball.markdown"),
        "epub": UTType("org.idpf.epub-container"),
    ]
}

/// 能直接接收 WebDAV 直链、边读边播的外部播放器（不会先整份下载）。
enum ExternalPlayer: String, CaseIterable, Identifiable {
    case infuse
    case vlc

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .infuse: return "Infuse"
        case .vlc: return "VLC"
        }
    }

    var urlScheme: String {
        switch self {
        case .infuse: return "infuse"
        case .vlc: return "vlc-x-callback"
        }
    }

    var isInstalled: Bool {
        guard let probe = URL(string: "\(urlScheme)://") else { return false }
        return UIApplication.shared.canOpenURL(probe)
    }
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

struct OpenInPayload: Identifiable {
    let id = UUID()
    let url: URL
    /// open-in 菜单按该 UTType 路由到可处理的应用（DocTypes.utType）；nil 时由系统按扩展名推断。
    var uti: String? = nil
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

/// 系统的「用其他 App 打开」选择器。iOS 不允许静默启动任意 App，
/// 所以这里直接弹 Open In 菜单；没有可打开的应用时退化为分享菜单。
struct OpenInSheet: UIViewControllerRepresentable {
    let url: URL
    /// 见 OpenInPayload.uti；nil 时按扩展名推断。
    var uti: String? = nil
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> OpenInHostController {
        let controller = OpenInHostController()
        controller.url = url
        controller.uti = uti
        controller.onFinish = onFinish
        return controller
    }

    func updateUIViewController(_ controller: OpenInHostController, context: Context) {}
}

final class OpenInHostController: UIViewController, UIDocumentInteractionControllerDelegate {
    var url: URL?
    var uti: String?
    var onFinish: (() -> Void)?
    private var interaction: UIDocumentInteractionController?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard interaction == nil, let url else { return }
        let controller = UIDocumentInteractionController(url: url)
        controller.delegate = self
        // 显式指定 UTI：远端临时副本虽有扩展名，显式声明更可靠地路由到可处理的应用。
        if let uti { controller.uti = uti }
        interaction = controller
        let opened = controller.presentOpenInMenu(from: view.bounds, in: view, animated: true)
        if !opened {
            _ = controller.presentOptionsMenu(from: view.bounds, in: view, animated: true)
        }
    }

    func documentInteractionControllerDidDismissOpenInMenu(
        _ controller: UIDocumentInteractionController
    ) {
        finish()
    }

    func documentInteractionControllerDidDismissOptionsMenu(
        _ controller: UIDocumentInteractionController
    ) {
        finish()
    }

    func documentInteractionController(
        _ controller: UIDocumentInteractionController,
        didEndSendingToApplication application: String?
    ) {
        finish()
    }

    private func finish() {
        guard interaction != nil else { return }
        interaction = nil
        onFinish?()
    }
}

/// 未知类型的兜底预览交给 QuickLook；图片与视频在详情页内联展示，
/// PDF 走 PdfViewerScreen、办公文档走 DocumentPlaceholderScreen。
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
            badge
            VStack(alignment: .leading, spacing: Spacing.s1) {
                Text(entry.name)
                    .font(Sf.fileNameFont)
                    .foregroundStyle(Sf.onSurface)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(meta ?? Fmt.detail(entry))
                    .font(Sf.metaFont)
                    .foregroundStyle(Sf.onSurfaceVariant)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Spacing.s2)
        .frame(minHeight: Sf.rowHeight)
        .contentShape(Rectangle())
        .listRowBackground(selected ? Sf.surfaceTint : Sf.surfaceCard)
    }

    /// Figma FileRow 合同：46×50 r10 类型徽章（图标 + 扩展名），目录用暖米 + 暖棕。
    private var badge: some View {
        let ext = Self.ext(entry.name)
        let style = Self.badgeStyle(for: entry, ext: ext)
        return VStack(spacing: 1) {
            Image(systemName: FileIcon.symbolName(for: entry))
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(style.fg)
            if entry.kind != .directory, !ext.isEmpty {
                Text(String(ext.uppercased().prefix(4)))
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(style.fg)
            }
        }
        .frame(width: Sf.badgeWidth, height: Sf.badgeHeight)
        .background(
            RoundedRectangle(cornerRadius: Sf.badgeCorner)
                .fill(style.bg)
        )
    }

    private static func badgeStyle(for entry: Entry, ext: String) -> (bg: Color, fg: Color) {
        if entry.kind == .directory { return (Sf.avatarBg, Sf.primaryWarm) }
        switch ext {
        case "pdf": return (Sf.pdfBadgeBg, Sf.pdfBadgeFg)
        case "xls", "xlsx", "csv": return (Sf.sheetBadgeBg, Sf.success)
        case "doc", "docx", "txt", "md": return (Sf.docBadgeBg, Sf.primary)
        default: return (Sf.surfaceTint, Sf.onSurfaceVariant)
        }
    }

    private static func ext(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }
}

struct EmptyFolderView: View {
    let title: String
    let hint: String

    var body: some View {
        VStack(spacing: Spacing.s2) {
            Image(systemName: "folder")
                .font(.system(size: Spacing.emptyIconSize))
                .foregroundStyle(Sf.outline)
            Text(title)
                .font(Sf.emptyTitleFont)
                .foregroundStyle(Sf.onSurface)
            Text(hint)
                .font(Sf.emptyBodyFont)
                .foregroundStyle(Sf.onSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.s8)
        .listRowSeparator(.hidden)
    }
}

// MARK: - 存储统计

/// 设备卷用量（iOS 沙盒没有 StatFs，读取 URL 卷容量；无需权限）。
enum SfStorage {
    struct Stats: Equatable {
        let used: Int64
        let total: Int64

        var fraction: Double {
            total > 0 ? min(max(Double(used) / Double(total), 0), 1) : 0
        }

        var summary: String {
            "已用 \(Self.gb(used, decimals: 1)) / \(Self.gb(total, decimals: 0))"
        }

        var percentText: String {
            String(format: "已用 %.1f%%", fraction * 100)
        }

        var availableText: String {
            "可用 \(Self.gb(max(total - used, 0), decimals: 1))"
        }

        static func gb(_ bytes: Int64, decimals: Int) -> String {
            String(format: "%.\(decimals)f GB", Double(bytes) / 1_073_741_824)
        }
    }

    static func current() -> Stats? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]),
        let total = values.volumeTotalCapacity,
        let available = values.volumeAvailableCapacityForImportantUsage else {
            return nil
        }
        let totalBytes = Int64(total)
        let used = max(totalBytes - Int64(available), 0)
        return Stats(used: used, total: totalBytes)
    }
}

/// 细用量条：轨道 + 主色进度（docs/06 品牌进度条，不用系统 ProgressView 的默认样式）。
struct StorageBar: View {
    let fraction: Double
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Sf.usageTrack)
                Capsule()
                    .fill(Sf.primary)
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// 存储管理面板：设备用量 + 索引状态/重建/清理。入口在侧栏「应用存储」行。
struct StorageSheet: View {
    @ObservedObject var store: VfsStore
    let stats: SfStorage.Stats?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.s4) {
                    deviceCard
                    IndexStatusCard(store: store)
                }
                .padding(Spacing.s6)
            }
            .background(Sf.surface)
            .navigationTitle("存储管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { store.refreshIndexCount() }
    }

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: Spacing.s3) {
            Text("设备存储")
                .font(Sf.appBarFont)
                .foregroundStyle(Sf.onSurface)

            if let stats {
                Text(stats.summary)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Sf.usageDeep)
                StorageBar(fraction: stats.fraction, height: 6)
                HStack {
                    Text(stats.percentText)
                        .font(Sf.metaFont)
                        .foregroundStyle(Sf.primary)
                    Spacer()
                    Text(stats.availableText)
                        .font(Sf.metaFont)
                        .foregroundStyle(Sf.onSurfaceVariant)
                }
            } else {
                Text("无法读取存储信息")
                    .font(Sf.metaFont)
                    .foregroundStyle(Sf.onSurfaceVariant)
            }

            Button {
                store.activate(.appStorage)
                dismiss()
            } label: {
                Label("浏览应用存储", systemImage: "internaldrive")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(Sf.primary)
        }
        .padding(Spacing.s4)
        .background(
            RoundedRectangle(cornerRadius: Spacing.radiusM)
                .fill(Sf.surfaceCard)
        )
    }

}

/// 索引状态卡：统计 + 重建 / 清理。存储管理面板与「我的」共用。
struct IndexStatusCard: View {
    @ObservedObject var store: VfsStore
    @State private var showClearConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s3) {
            HStack(spacing: Spacing.s2) {
                Text("文件名索引")
                    .font(Sf.appBarFont)
                    .foregroundStyle(Sf.onSurface)
                Spacer()
                if store.isIndexing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Sf.primary)
                }
            }

            Text(indexSummary)
                .font(Sf.metaFont)
                .foregroundStyle(Sf.onSurfaceVariant)
            Text(indexDateText)
                .font(Sf.metaFont)
                .foregroundStyle(Sf.onSurfaceVariant)

            HStack(spacing: Spacing.s2) {
                Button("重建索引") { store.indexRoot() }
                    .buttonStyle(.borderedProminent)
                    .tint(Sf.primary)
                    .disabled(store.isIndexing)
                Button("清理索引", role: .destructive) {
                    showClearConfirm = true
                }
                .buttonStyle(.bordered)
                .disabled(store.isIndexing || (store.indexedCount == 0 && store.indexedBytes == 0))
                Spacer()
            }
        }
        .padding(Spacing.s4)
        .background(
            RoundedRectangle(cornerRadius: Spacing.radiusM)
                .fill(Sf.surfaceCard)
        )
        .confirmationDialog(
            "确定清理索引？",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("清理", role: .destructive) { store.clearIndex() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清理后搜索需要重新建立索引。")
        }
    }

    private var indexSummary: String {
        let count = "已索引 \(store.indexedCount) 项"
        guard store.indexedBytes > 0 else { return count }
        return "\(count) · \(Fmt.bytes.string(fromByteCount: store.indexedBytes))"
    }

    private var indexDateText: String {
        guard let lastIndexedAt = store.lastIndexedAt else {
            return "尚未完整扫描；搜索前建议先重建索引"
        }
        return "上次扫描 \(Fmt.date.string(from: lastIndexedAt))"
    }
}
