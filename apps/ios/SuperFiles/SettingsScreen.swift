import SwiftUI

/// 「我的」：索引 / 通用 / 关于。入口在侧栏底部。
///
/// 与 Android `MineScreen` 对齐的是共享能力（索引统计与重建/清理、诊断导出、
/// 开源许可、版本）；平台专属项（全盘存储权限、账号昵称导入）不搬。
@MainActor
struct SettingsScreen: View {
    @ObservedObject var store: VfsStore
    @Environment(\.dismiss) private var dismiss

    @State private var shareItem: SharePayload?
    @State private var showLicenses = false
    @State private var showLocalSend = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.s4) {
                    appCard
                    IndexStatusCard(store: store)
                    generalCard
                    localSendCard
                    aboutCard
                }
                .padding(Spacing.s6)
            }
            .background(Sf.surface)
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $shareItem) { payload in
                ShareSheet(items: [payload.url])
            }
            .sheet(isPresented: $showLicenses) {
                LicenseSheet()
            }
            .sheet(isPresented: $showLocalSend) {
                LocalSendScreen(store: store)
            }
            .task { store.refreshIndexCount() }
        }
    }

    private var appCard: some View {
        HStack(spacing: Spacing.s3) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Sf.primaryWarm)
                .frame(width: 48, height: 48)
                .background(
                    RoundedRectangle(cornerRadius: Spacing.radiusM)
                        .fill(Sf.avatarBg)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text("Super Files")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Sf.onSurface)
                Text("跨平台文件管理 · v\(appVersion)")
                    .font(Sf.metaFont)
                    .foregroundStyle(Sf.onSurfaceVariant)
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.s4)
        .background(
            RoundedRectangle(cornerRadius: Spacing.radiusM)
                .fill(Sf.surfaceCard)
        )
    }

    private var generalCard: some View {
        HStack(spacing: Spacing.s3) {
            iconBadge("eye")
            Text("显示隐藏文件")
                .font(.system(size: 14))
                .foregroundStyle(Sf.onSurface)
            Spacer(minLength: Spacing.s2)
            Toggle(
                "",
                isOn: Binding(
                    get: { store.showHidden },
                    set: { store.setShowHidden($0) }
                )
            )
            .labelsHidden()
            .tint(Sf.primary)
        }
        .padding(Spacing.s4)
        .background(
            RoundedRectangle(cornerRadius: Spacing.radiusM)
                .fill(Sf.surfaceCard)
        )
    }

    private var localSendCard: some View {
        Button {
            showLocalSend = true
        } label: {
            SettingsRow(
                icon: "dot.radiowaves.left.and.right",
                title: "近邻传输",
                subtitle: store.localSendRunning
                    ? "已开启 · \(store.localSendPeers.count) 台附近设备"
                    : "未开启 · LocalSend 兼容",
                showsChevron: true
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Spacing.s4)
        .padding(.vertical, Spacing.s1)
        .background(
            RoundedRectangle(cornerRadius: Spacing.radiusM)
                .fill(Sf.surfaceCard)
        )
    }

    private var aboutCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.s3) {
                iconBadge("info.circle")
                Text("版本")
                    .font(.system(size: 14))
                    .foregroundStyle(Sf.onSurface)
                Spacer(minLength: Spacing.s2)
                Text("v\(store.version)")
                    .font(Sf.cardTitleFont)
                    .foregroundStyle(Sf.onSurfaceVariant)
            }
            .padding(.vertical, Spacing.s2)

            Divider()
                .overlay(Sf.outline.opacity(0.2))
                .padding(.leading, Spacing.s8)

            Button {
                showLicenses = true
            } label: {
                SettingsRow(
                    icon: "doc.text",
                    title: "开源许可",
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)

            Divider()
                .overlay(Sf.outline.opacity(0.2))
                .padding(.leading, Spacing.s8)

            Button {
                exportDiagnostics()
            } label: {
                SettingsRow(
                    icon: "square.and.arrow.up",
                    title: "导出诊断",
                    subtitle: "版本 / 设备 / 索引 / 挂载 / 传输",
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.s4)
        .padding(.vertical, Spacing.s1)
        .background(
            RoundedRectangle(cornerRadius: Spacing.radiusM)
                .fill(Sf.surfaceCard)
        )
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }

    private func exportDiagnostics() {
        guard let url = store.createDiagnosticsFile() else { return }
        shareItem = SharePayload(url: url)
    }

    private func iconBadge(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(Sf.primary)
            .frame(width: 32, height: 32)
            .background(
                RoundedRectangle(cornerRadius: Spacing.radiusS)
                    .fill(Sf.searchFieldBg)
            )
    }
}

/// 设置行：左侧图标块 + 标题（可选副标题）+ 右侧箭头。
private struct SettingsRow: View {
    let icon: String
    let title: String
    var subtitle: String?
    var showsChevron = false

    var body: some View {
        HStack(spacing: Spacing.s3) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Sf.primary)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: Spacing.radiusS)
                        .fill(Sf.searchFieldBg)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(Sf.onSurface)
                if let subtitle {
                    Text(subtitle)
                        .font(Sf.metaFont)
                        .foregroundStyle(Sf.onSurfaceVariant)
                }
            }
            Spacer(minLength: Spacing.s2)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Sf.outline)
            }
        }
        .padding(.vertical, Spacing.s2)
        .contentShape(Rectangle())
    }
}

private struct LicenseSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(Self.text)
                    .font(Sf.metaFont)
                    .foregroundStyle(Sf.onSurface)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.s6)
            }
            .background(Sf.surface)
            .navigationTitle("开源许可")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private static let text = """
    Super Files 使用以下开源组件：

    · Super Files Core（Rust 内核）— MIT OR Apache-2.0
    · UniFFI — Mozilla Public License 2.0
    · Rust crates（smb-transport / russh / russh-sftp 等）— 详见源码与 Cargo.lock
    · SQLite — Public Domain

    系统图标与字体（SF Symbols / San Francisco）由 Apple 提供，仅用于本应用界面。
    完整依赖清单见仓库 Cargo.lock 与 docs。
    """
}
