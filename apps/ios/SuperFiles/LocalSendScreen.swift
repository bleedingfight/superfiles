import SwiftUI

/// 近邻传输（LocalSend 兼容）：HTTPS 接收 + 组播发现 + 手动 IP 兜底。
/// 接收文件默认落到「应用存储」根目录，可修改。
@MainActor
struct LocalSendScreen: View {
    @ObservedObject var store: VfsStore
    @Environment(\.dismiss) private var dismiss

    @State private var manualIP = ""
    @State private var manualPort = "53317"
    @State private var manualError: String?
    @State private var manualBusy = false
    @State private var showDestPicker = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.s4) {
                    statusCard
                    receiveCard
                    devicesCard
                    manualCard
                    if !store.localSendErrors.isEmpty {
                        errorsCard
                    }
                    Text("LocalSend 兼容协议 · 仅在同一局域网内传输 · 无传输活动 5 分钟后自动关闭")
                        .font(Sf.metaFont)
                        .foregroundStyle(Sf.onSurfaceVariant)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(Spacing.s6)
            }
            .background(Sf.surface)
            .navigationTitle("近邻传输")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                if store.localSendRunning { store.refreshLocalSendPeers() }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: Spacing.s3) {
            HStack(spacing: Spacing.s2) {
                Circle()
                    .fill(store.localSendRunning ? Sf.success : Sf.outline)
                    .frame(width: 10, height: 10)
                Text(store.localSendRunning ? "正在接收与发现" : "未开启")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Sf.onSurface)
                Spacer()
                if store.localSendBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Sf.primary)
                }
            }

            Text("设备名：\(store.localSendInfo?.alias ?? deviceAlias)")
                .font(Sf.metaFont)
                .foregroundStyle(Sf.onSurfaceVariant)

            if let info = store.localSendInfo {
                Text("端口 \(info.port) · 指纹 \(shortFingerprint(info.fingerprint))")
                    .font(Sf.metaFont)
                    .foregroundStyle(Sf.onSurfaceVariant)
            }

            HStack(spacing: Spacing.s2) {
                if store.localSendRunning {
                    Button("刷新设备") { store.refreshLocalSendPeers() }
                        .buttonStyle(.borderedProminent)
                        .tint(Sf.primary)
                        .disabled(store.localSendBusy)
                    Spacer()
                    Button("关闭", role: .destructive) { store.stopLocalSend() }
                        .buttonStyle(.bordered)
                } else {
                    Button("开启接收与发现") { store.startLocalSend() }
                        .buttonStyle(.borderedProminent)
                        .tint(Sf.primary)
                        .disabled(store.localSendBusy)
                    Spacer()
                }
            }

            if let error = store.localSendStartError {
                Text(error)
                    .font(Sf.metaFont)
                    .foregroundStyle(Sf.error)
            }

            if store.localSendRunning {
                Text("开启后，附近的 LocalSend 设备可直接向你发送文件；你也可以从文件菜单把文件发到附近设备。")
                    .font(Sf.metaFont)
                    .foregroundStyle(Sf.onSurfaceVariant)
            } else {
                Text("若一直无法发现设备：确认两台设备连在同一个 Wi-Fi，并在 设置 → 隐私与安全性 → 本地网络 中允许 Super Files。")
                    .font(Sf.metaFont)
                    .foregroundStyle(Sf.onSurfaceVariant)
            }
        }
        .padding(Spacing.s4)
        .background(
            RoundedRectangle(cornerRadius: Spacing.radiusM)
                .fill(Sf.surfaceTint)
        )
    }

    private var receiveCard: some View {
        VStack(alignment: .leading, spacing: Spacing.s2) {
            HStack {
                Text("接收位置")
                    .font(Sf.cardTitleFont)
                    .foregroundStyle(Sf.onSurfaceVariant)
                Spacer()
                Button("修改") { showDestPicker = true }
                    .font(Sf.cardTitleFont)
                    .foregroundStyle(Sf.primary)
            }
            Text(store.localSendDestName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Sf.onSurface)
            Text(store.localSendDestDir)
                .font(Sf.metaFont)
                .foregroundStyle(Sf.onSurfaceVariant)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.s4)
        .background(
            RoundedRectangle(cornerRadius: Spacing.radiusM)
                .fill(Sf.surfaceCard)
        )
        .sheet(isPresented: $showDestPicker) {
            DestinationPicker(store: store) { id in
                let name: String
                if id.hasPrefix("/") {
                    let comp = (id as NSString).lastPathComponent
                    name = comp.isEmpty ? "应用存储" : comp
                } else {
                    name = store.displayPath(of: id)
                }
                store.setLocalSendDestination(id, name: name)
            }
        }
    }

    private var devicesCard: some View {
        VStack(alignment: .leading, spacing: Spacing.s3) {
            HStack {
                Text("附近设备")
                    .font(Sf.appBarFont)
                    .foregroundStyle(Sf.onSurface)
                Spacer()
                if store.localSendRunning {
                    Button("刷新") { store.refreshLocalSendPeers() }
                        .font(Sf.cardTitleFont)
                        .buttonStyle(.plain)
                        .foregroundStyle(Sf.primary)
                }
            }

            if !store.localSendRunning {
                Text("开启近邻传输后会自动发现同一局域网内的设备。")
                    .font(Sf.metaFont)
                    .foregroundStyle(Sf.onSurfaceVariant)
            } else if store.localSendPeers.isEmpty {
                HStack(spacing: Spacing.s2) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Sf.primary)
                    Text("正在寻找附近设备…")
                        .font(Sf.metaFont)
                        .foregroundStyle(Sf.onSurfaceVariant)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(store.localSendPeers, id: \.fingerprint) { peer in
                        PeerRow(peer: peer)
                        if peer.fingerprint != store.localSendPeers.last?.fingerprint {
                            Divider()
                                .overlay(Sf.outline.opacity(0.2))
                                .padding(.leading, Spacing.s8)
                        }
                    }
                }
            }
        }
        .padding(Spacing.s4)
        .background(
            RoundedRectangle(cornerRadius: Spacing.radiusM)
                .fill(Sf.surfaceCard)
        )
    }

    private var manualCard: some View {
        VStack(alignment: .leading, spacing: Spacing.s3) {
            Text("手动连接")
                .font(Sf.appBarFont)
                .foregroundStyle(Sf.onSurface)
            Text("组播被路由器隔离时，填写对方 IP 直连。")
                .font(Sf.metaFont)
                .foregroundStyle(Sf.onSurfaceVariant)

            HStack(spacing: Spacing.s2) {
                TextField("192.168.1.10", text: $manualIP)
                    .keyboardType(.decimalPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(Spacing.s2)
                    .background(
                        RoundedRectangle(cornerRadius: Spacing.radiusS)
                            .fill(Sf.searchFieldBg)
                    )
                TextField("53317", text: $manualPort)
                    .keyboardType(.numberPad)
                    .frame(width: 72)
                    .padding(Spacing.s2)
                    .background(
                        RoundedRectangle(cornerRadius: Spacing.radiusS)
                            .fill(Sf.searchFieldBg)
                    )
            }

            if let manualError {
                Text(manualError)
                    .font(Sf.metaFont)
                    .foregroundStyle(Sf.error)
            }

            HStack {
                Spacer()
                Button {
                    connectManually()
                } label: {
                    if manualBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("连接")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Sf.primary)
                .disabled(manualBusy || manualIP.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Spacing.s4)
        .background(
            RoundedRectangle(cornerRadius: Spacing.radiusM)
                .fill(Sf.surfaceCard)
        )
    }

    private var errorsCard: some View {
        VStack(alignment: .leading, spacing: Spacing.s1) {
            Text("协议诊断")
                .font(Sf.cardTitleFont)
                .foregroundStyle(Sf.onSurfaceVariant)
            ForEach(store.localSendErrors.suffix(3), id: \.self) { error in
                Text(error)
                    .font(Sf.metaFont)
                    .foregroundStyle(Sf.error)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.s4)
        .background(
            RoundedRectangle(cornerRadius: Spacing.radiusM)
                .fill(Sf.surfaceCard)
        )
    }

    private var deviceAlias: String {
        let name = UIDevice.current.name
        return name.isEmpty ? "Super Files" : name
    }

    private func connectManually() {
        guard store.localSendRunning else {
            manualError = "请先开启近邻传输"
            return
        }
        manualError = nil
        manualBusy = true
        let port = UInt16(manualPort) ?? 53317
        Task {
            let error = await store.registerLocalSendPeer(
                ip: manualIP,
                port: port,
                fingerprint: nil
            )
            manualBusy = false
            manualError = error
        }
    }
}

/// 发送文件时的附近设备选择器。打开即自动开启发现。
@MainActor
struct LocalSendPeerPicker: View {
    @ObservedObject var store: VfsStore
    let entries: [Entry]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.s4) {
                    Text("将发送 \(fileCount) 个文件")
                        .font(Sf.metaFont)
                        .foregroundStyle(Sf.onSurfaceVariant)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let error = store.localSendStartError {
                        Text(error)
                            .font(Sf.metaFont)
                            .foregroundStyle(Sf.error)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let error = store.localSendSendError {
                        Text(error)
                            .font(Sf.metaFont)
                            .foregroundStyle(Sf.error)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text("若提示「对方没有在接收」，让对方打开近邻传输；若提示网络不可达/权限被拒，检查同一 Wi-Fi 和本地网络权限。")
                                .font(Sf.metaFont)
                                .foregroundStyle(Sf.onSurfaceVariant)
                                .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !store.localSendRunning {
                        VStack(spacing: Spacing.s3) {
                            if store.localSendBusy {
                                ProgressView()
                                    .tint(Sf.primary)
                                Text("正在开启近邻传输…")
                                    .font(Sf.metaFont)
                                    .foregroundStyle(Sf.onSurfaceVariant)
                            } else {
                                Text("近邻传输未开启")
                                    .font(Sf.emptyTitleFont)
                                    .foregroundStyle(Sf.onSurface)
                                Button("开启接收与发现") { store.startLocalSend() }
                                    .buttonStyle(.borderedProminent)
                                    .tint(Sf.primary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.s8)
                    } else if store.localSendPeers.isEmpty {
                        VStack(spacing: Spacing.s3) {
                            ProgressView()
                                .tint(Sf.primary)
                            Text("正在寻找附近设备…")
                                .font(Sf.metaFont)
                                .foregroundStyle(Sf.onSurfaceVariant)
                            Text("确认两台设备在同一 Wi-Fi，且已允许 Super Files 访问本地网络。仍找不到可到「我的 → 近邻传输」用 IP 手动连接。")
                                .font(Sf.metaFont)
                                .foregroundStyle(Sf.onSurfaceVariant)
                                .multilineTextAlignment(.center)
                            Button("重新搜索") { store.refreshLocalSendPeers() }
                                .buttonStyle(.bordered)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.s8)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(store.localSendPeers, id: \.fingerprint) { peer in
                                Button {
                                    store.sendViaLocalSend(
                                        peer: peer,
                                        entries: entries,
                                        onSuccess: { dismiss() }
                                    )
                                } label: {
                                    HStack(spacing: Spacing.s3) {
                                        Image(systemName: "desktopcomputer")
                                            .font(.system(size: 16))
                                            .foregroundStyle(Sf.primary)
                                            .frame(width: 32, height: 32)
                                            .background(
                                                RoundedRectangle(cornerRadius: Spacing.radiusS)
                                                    .fill(Sf.avatarBg)
                                            )
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(peer.alias)
                                                .font(.system(size: 14, weight: .medium))
                                                .foregroundStyle(Sf.onSurface)
                                            Text("\(peer.ip):\(peer.port) · \(peer.deviceType)")
                                                .font(Sf.metaFont)
                                                .foregroundStyle(Sf.onSurfaceVariant)
                                        }
                                        Spacer(minLength: Spacing.s2)
                                        if store.localSendBusy {
                                            ProgressView()
                                                .controlSize(.small)
                                        } else {
                                            Image(systemName: "paperplane")
                                                .foregroundStyle(Sf.primary)
                                        }
                                    }
                                    .padding(.vertical, Spacing.s2)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(store.localSendBusy)

                                if peer.fingerprint != store.localSendPeers.last?.fingerprint {
                                    Divider()
                                        .overlay(Sf.outline.opacity(0.2))
                                        .padding(.leading, Spacing.s8)
                                }
                            }
                        }
                    }

                    Text("提示：仅支持发送文件；文件夹请先在文件菜单里压缩成 zip。")
                        .font(Sf.metaFont)
                        .foregroundStyle(Sf.onSurfaceVariant)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(Spacing.s6)
            }
            .background(Sf.surface)
            .navigationTitle("发送到附近设备")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .task {
                // 等 sheet 完成呈现再启动，避免首次弹出本地网络权限/状态变更时抢展示。
                try? await Task.sleep(nanoseconds: 250_000_000)
                store.ensureLocalSendStarted()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var fileCount: Int {
        entries.filter { $0.kind == .file }.count
    }
}

private struct PeerRow: View {
    let peer: LocalSendPeer

    var body: some View {
        HStack(spacing: Spacing.s3) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 16))
                .foregroundStyle(Sf.primary)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: Spacing.radiusS)
                        .fill(Sf.avatarBg)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.alias)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Sf.onSurface)
                Text("\(peer.ip):\(peer.port) · \(peer.deviceType)")
                    .font(Sf.metaFont)
                    .foregroundStyle(Sf.onSurfaceVariant)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Spacing.s2)
    }
}

private func shortFingerprint(_ value: String) -> String {
    value.count <= 16 ? value : "\(value.prefix(8))…\(value.suffix(8))"
}
