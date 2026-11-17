import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins

/// 就近分享：把选中的文件经局域网 HTTP 暴露为「链接 + 二维码」。
/// 浏览器免安装直接下载；关闭这个页面即停止分享。
@MainActor
struct ShareLinkSheet: View {
    @ObservedObject var store: VfsStore
    let entries: [Entry]
    @Environment(\.dismiss) private var dismiss

    @State private var qrImage: UIImage?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.s4) {
                    if let info = store.shareInfo {
                        qrCard(info)
                        actionCard(info)
                        Text("关闭此页后链接立即失效；仅限同一局域网内访问。")
                            .font(Sf.metaFont)
                            .foregroundStyle(Sf.onSurfaceVariant)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if let error = store.errorMessage {
                        Text(error)
                            .font(Sf.metaFont)
                            .foregroundStyle(Sf.error)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(spacing: Spacing.s3) {
                            ProgressView()
                                .tint(Sf.primary)
                            Text("正在生成分享链接…")
                                .font(Sf.metaFont)
                                .foregroundStyle(Sf.onSurfaceVariant)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.s8)
                    }
                }
                .padding(Spacing.s6)
            }
            .background(Sf.surface)
            .navigationTitle("就近分享")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task(id: store.shareInfo?.url) {
                guard let url = store.shareInfo?.url else { return }
                qrImage = Self.makeQRCode(url)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            if store.shareInfo == nil {
                store.startShare(entries: entries)
            }
        }
        .onDisappear {
            store.stopShare()
        }
    }

    private func qrCard(_ info: ShareInfo) -> some View {
        VStack(spacing: Spacing.s3) {
            if let qrImage {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 240)
                    .padding(Spacing.s3)
                    .background(
                        RoundedRectangle(cornerRadius: Spacing.radiusM)
                            .fill(.white)
                    )
            } else {
                ProgressView()
                    .tint(Sf.primary)
                    .frame(width: 240, height: 240)
            }

            Text("\(info.fileCount) 个文件 · 扫码或输入链接下载")
                .font(Sf.metaFont)
                .foregroundStyle(Sf.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.s4)
        .background(
            RoundedRectangle(cornerRadius: Spacing.radiusM)
                .fill(Sf.surfaceCard)
        )
    }

    private func actionCard(_ info: ShareInfo) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s3) {
            Text(info.url)
                .font(Sf.metaFont)
                .foregroundStyle(Sf.onSurface)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: Spacing.s2) {
                Button {
                    UIPasteboard.general.string = info.url
                    copied = true
                } label: {
                    Label(copied ? "已复制" : "复制链接", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Sf.primary)

                if let url = URL(string: info.url) {
                    ShareLink(item: url) {
                        Label("分享", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(Sf.primary)
                }
            }
        }
        .padding(Spacing.s4)
        .background(
            RoundedRectangle(cornerRadius: Spacing.radiusM)
                .fill(Sf.surfaceCard)
        )
    }

    private static func makeQRCode(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
