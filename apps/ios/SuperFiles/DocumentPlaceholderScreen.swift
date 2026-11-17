import SwiftUI
import UIKit

struct DocPlaceholderRequest: Identifiable {
    let id = UUID()
    let entry: Entry
}

/// 无系统渲染器的文档（doc/docx/xls/xlsx/ppt/pptx/txt/csv/md/epub）的预览占位页。
/// 与鸿蒙端 PreviewView 的 KIND_OTHER 占位一致：图标 + 文件信息 +「用其他 App 打开」。
/// 打开链路：内核字节落地缓存 → 系统 open-in 菜单（OpenInSheet，按 UTType 路由；
/// 没有可处理应用时系统退化为分享菜单）。
@MainActor
struct DocumentPlaceholderScreen: View {
    @ObservedObject var store: VfsStore
    let entry: Entry
    @Environment(\.dismiss) private var dismiss
    @State private var openInPayload: OpenInPayload?
    @State private var preparing = false
    @State private var errorText: String?

    var body: some View {
        ZStack {
            Sf.surface.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Spacer()
                VStack(spacing: Spacing.s3) {
                    Image(systemName: FileIcon.symbolName(for: entry))
                        .font(.system(size: 56))
                        .foregroundStyle(Sf.outline)
                    Text(entry.name)
                        .font(Sf.fileNameFont)
                        .foregroundStyle(Sf.onSurface)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text("此格式无法在应用内预览\n\(Fmt.detail(entry))")
                        .font(Sf.metaFont)
                        .foregroundStyle(Sf.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                    Button {
                        openExternal()
                    } label: {
                        if preparing {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Label("用其他 App 打开", systemImage: "arrow.up.forward.app")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Sf.primary)
                    .disabled(preparing)
                    .padding(.top, Spacing.s2)
                    if let errorText {
                        Text(errorText)
                            .font(Sf.metaFont)
                            .foregroundStyle(Sf.error)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, Spacing.s8)
                Spacer()
                Spacer()
            }
        }
        .sheet(item: $openInPayload) { payload in
            OpenInSheet(url: payload.url, uti: payload.uti) {
                store.cleanupTemporaryCopy(payload.url)
                openInPayload = nil
            }
        }
    }

    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Sf.onSurface)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Sf.searchFieldBg))
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.s4)
        .padding(.top, Spacing.s2)
    }

    /// 落地缓存后弹系统 open-in 菜单；失败在页内提示（全屏 cover 会盖住根视图的 alert）。
    private func openExternal() {
        guard !preparing else { return }
        preparing = true
        errorText = nil
        Task { @MainActor in
            defer { preparing = false }
            guard let url = await store.localCopy(for: entry, silent: true) else {
                errorText = "准备文件失败（可能存储空间不足或网络中断）"
                return
            }
            openInPayload = OpenInPayload(url: url, uti: DocTypes.utType(for: entry).identifier)
        }
    }
}
