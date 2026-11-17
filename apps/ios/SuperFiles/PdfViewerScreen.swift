import SwiftUI
import PDFKit
import UIKit

struct PdfOpenRequest: Identifiable {
    let id = UUID()
    let entry: Entry
}

/// PDF 应用内预览（PDFKit，纯离线）。
///
/// 远端文件先经内核回环流落地缓存（store.localCopy，自带空间检查），再用
/// PDFDocument(url:) 加载；本地文件直接打开。PDFView 自带竖向滚动翻页、
/// 捏合缩放与双击复位，系统按页分块渲染——不需要鸿蒙端那样的窗口化防 OOM。
/// 与鸿蒙端 PdfViewer 对齐：超过 200MB 不解析，改用其他 App 打开。
@MainActor
struct PdfViewerScreen: View {
    @ObservedObject var store: VfsStore
    let entry: Entry
    @Environment(\.dismiss) private var dismiss

    /// 与鸿蒙端 PdfViewer.MAX_BYTES 对齐。
    private static let maxBytes: UInt64 = 200 * 1024 * 1024

    @State private var document: PDFDocument?
    @State private var sourceURL: URL?
    @State private var failedMessage: String?
    @State private var currentPage = 1
    @State private var pageCount = 0
    @State private var openInPayload: OpenInPayload?
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Sf.surface.ignoresSafeArea()

            if let document {
                PdfViewRepresentable(
                    document: document,
                    currentPage: $currentPage,
                    pageCount: $pageCount
                )
                .ignoresSafeArea()
            } else if let failedMessage {
                failure(message: failedMessage)
            } else {
                ProgressView()
                    .tint(Sf.primary)
            }

            VStack {
                header
                Spacer()
            }
        }
        .statusBarHidden()
        .onAppear { load() }
        .onDisappear {
            // 页面销毁时取消解析任务并清理远端文件的临时副本；本地文件不动。
            loadTask?.cancel()
            loadTask = nil
            if let sourceURL { store.cleanupTemporaryCopy(sourceURL) }
            sourceURL = nil
        }
        .sheet(item: $openInPayload) { payload in
            OpenInSheet(url: payload.url, uti: payload.uti) {
                store.cleanupTemporaryCopy(payload.url)
                openInPayload = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.s3) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.black.opacity(0.45)))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                // 页数徽标（PDFView 不自带），跟随滚动实时更新。
                Text(pageCount > 0 ? "\(min(currentPage, pageCount)) / \(pageCount)" : "PDF")
                    .font(Sf.metaFont)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.s4)
        .padding(.top, Spacing.s2)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.55), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        )
    }

    @ViewBuilder
    private func failure(message: String) -> some View {
        VStack(spacing: Spacing.s3) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 52))
                .foregroundStyle(Sf.outline)
            Text(message)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Sf.onSurface)
                .multilineTextAlignment(.center)
            if tooLarge {
                Button {
                    openExternal()
                } label: {
                    Label("用其他 App 打开", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Sf.primary)
                .frame(maxWidth: 280)
            }
        }
        .padding(Spacing.s6)
    }

    private var tooLarge: Bool {
        entry.size > Self.maxBytes
    }

    private func load() {
        guard document == nil, failedMessage == nil, loadTask == nil else { return }
        if tooLarge {
            failedMessage = "PDF 超过 200MB，应用内无法解析"
            return
        }
        loadTask = Task { @MainActor in
            // silent：本页是全屏 cover，根视图的 alert 会被盖住，失败在页内展示。
            guard let url = await store.localCopy(for: entry, silent: true) else {
                failedMessage = "准备文件失败（可能存储空间不足或网络中断）"
                loadTask = nil
                return
            }
            guard !Task.isCancelled else {
                store.cleanupTemporaryCopy(url)
                loadTask = nil
                return
            }
            let document = await Task.detached(priority: .userInitiated) {
                PDFDocument(url: url)
            }.value
            guard !Task.isCancelled else {
                store.cleanupTemporaryCopy(url)
                loadTask = nil
                return
            }
            guard let document, document.pageCount > 0 else {
                store.cleanupTemporaryCopy(url)
                failedMessage = "PDF 解析失败，可能已损坏"
                loadTask = nil
                return
            }
            guard !document.isLocked else {
                store.cleanupTemporaryCopy(url)
                failedMessage = "PDF 已加密，无法预览"
                loadTask = nil
                return
            }
            sourceURL = url
            pageCount = document.pageCount
            self.document = document
            loadTask = nil
        }
    }

    /// 超大同走外部打开：本地文件不经下载直接可用；远端仍走 localCopy。
    private func openExternal() {
        Task { @MainActor in
            guard let url = await store.localCopy(for: entry, silent: true) else {
                failedMessage = "准备文件失败（可能存储空间不足）"
                return
            }
            openInPayload = OpenInPayload(url: url, uti: DocTypes.utType(for: entry).identifier)
        }
    }
}

/// PDFKit.PDFView 的 SwiftUI 包装：系统组件自带竖向滚动、捏合缩放与双击复位。
private struct PdfViewRepresentable: UIViewRepresentable {
    let document: PDFDocument
    @Binding var currentPage: Int
    @Binding var pageCount: Int

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        // 深色背景适配：页边距跟随 Sf.surface 动态色，页面本身仍是白纸。
        view.backgroundColor = UIColor(Sf.surface)
        view.tintColor = UIColor(Sf.primary)
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: view
        )
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
        }
    }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(currentPage: $currentPage, pageCount: $pageCount)
    }

    final class Coordinator: NSObject {
        private let currentPage: Binding<Int>
        private let pageCount: Binding<Int>

        init(currentPage: Binding<Int>, pageCount: Binding<Int>) {
            self.currentPage = currentPage
            self.pageCount = pageCount
        }

        @objc func pageChanged(_ notification: Notification) {
            guard let view = notification.object as? PDFView else { return }
            // PDFPage.pageNumber 从 0 开始，徽标展示从 1 开始。
            currentPage.wrappedValue = (view.currentPage?.pageNumber ?? 0) + 1
            pageCount.wrappedValue = view.document?.pageCount ?? 0
        }
    }
}
