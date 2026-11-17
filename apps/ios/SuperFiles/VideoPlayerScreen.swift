import SwiftUI
import AVKit
import Combine
import UIKit

struct VideoPlaybackRequest: Identifiable {
    let id = UUID()
    let entry: Entry
}

/// 系统播放器（AVPlayer）直接播放：WebDAV/SMB 走回环 stream URL，
/// 不先下载整份文件；顶部同时提供「用其他 App 播放」。
@MainActor
struct VideoPlayerScreen: View {
    @ObservedObject var store: VfsStore
    let entry: Entry
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer?
    @State private var playerError: String?
    @State private var openInPayload: OpenInPayload?
    @State private var preparingExternal = false
    @State private var externalProgress: Double?
    @State private var externalBytes: Int64 = 0
    @State private var externalTotal: Int64?
    @State private var externalError: String?
    @State private var directPlayerError: String?
    @State private var prepareTask: Task<Void, Never>?
    @State private var startTask: Task<Void, Never>?
    @State private var cancellables: Set<AnyCancellable> = []

    private var unsupportedMessage: String? {
        Fmt.systemCanPlayVideo(entry)
            ? nil
            : "系统播放器不支持 \(Fmt.ext(entry.name).uppercased())"
    }

    /// 本机已安装、且能直连当前 WebDAV 文件的外部播放器。
    private var directPlayers: [ExternalPlayer] {
        store.installedExternalPlayers(for: entry)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else if let message = unsupportedMessage ?? playerError {
                VStack(spacing: Spacing.s3) {
                    Image(systemName: "play.slash")
                        .font(.system(size: 52))
                        .foregroundStyle(.white.opacity(0.6))
                    Text(message)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    if directPlayers.isEmpty {
                        Text("安装 Infuse 或 VLC 后，可在这里直接播放，无需下载整份文件")
                            .font(Sf.metaFont)
                            .foregroundStyle(.white.opacity(0.65))
                            .multilineTextAlignment(.center)
                    } else {
                        Text("可直接连接 WebDAV 边读边播，不占用本机空间")
                            .font(Sf.metaFont)
                            .foregroundStyle(.white.opacity(0.65))
                            .multilineTextAlignment(.center)

                        VStack(spacing: Spacing.s2) {
                            ForEach(directPlayers) { player in
                                Button {
                                    openDirect(with: player)
                                } label: {
                                    Label(
                                        "用 \(player.displayName) 直接播放",
                                        systemImage: "play.rectangle.on.rectangle"
                                    )
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Sf.primary)
                            }
                        }
                        .frame(maxWidth: 340)

                        Text("会将该存储的账号密码交给 \(directPlayers.map(\.displayName).joined(separator: " / "))")
                            .font(Sf.metaFont)
                            .foregroundStyle(.white.opacity(0.45))
                            .multilineTextAlignment(.center)
                    }

                    if let directPlayerError {
                        Text(directPlayerError)
                            .font(Sf.metaFont)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }

                    Button {
                        openExternal()
                    } label: {
                        if preparingExternal {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Label("下载后用其他 App 播放", systemImage: "arrow.up.forward.app")
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .disabled(preparingExternal)
                }
                .padding(Spacing.s6)
            } else {
                ProgressView()
                    .tint(.white)
            }

            VStack {
                header
                Spacer()
            }

            if preparingExternal {
                preparingOverlay
            }
        }
        .statusBarHidden()
        .onAppear { prepare() }
        .onDisappear {
            prepareTask?.cancel()
            prepareTask = nil
            startTask?.cancel()
            startTask = nil
            player?.pause()
            player = nil
            cancellables.removeAll()
            // 播放结束：删掉该文件的边播边缓存临时文件
            store.releaseStream(entry)
        }
        .sheet(item: $openInPayload) { payload in
            OpenInSheet(url: payload.url) {
                store.cleanupTemporaryCopy(payload.url)
                openInPayload = nil
            }
        }
        .alert(
            "准备文件失败",
            isPresented: Binding(
                get: { externalError != nil },
                set: { if !$0 { externalError = nil } }
            )
        ) {
            Button("好", role: .cancel) { externalError = nil }
        } message: {
            Text(externalError ?? "")
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
                Text("系统播放器")
                    .font(Sf.metaFont)
                    .foregroundStyle(.white.opacity(0.65))
            }
            Spacer(minLength: Spacing.s2)

            Button {
                openExternal()
            } label: {
                if preparingExternal {
                    ProgressView()
                        .tint(.white)
                        .frame(width: 34, height: 34)
                } else {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(.black.opacity(0.45)))
                }
            }
            .buttonStyle(.plain)
            .disabled(preparingExternal)
            .accessibilityLabel("用其他 App 播放")
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

    private func prepare() {
        guard unsupportedMessage == nil else { return }
        guard let url = store.streamURL(for: entry) else {
            playerError = "无法生成播放地址"
            return
        }

        // 只看扩展名不够：MP4 里也可能是 AV1/VP9/MPEG-2 等 AVFoundation
        // 不支持的视频编码，表现为「有声音没画面」。先检查视频轨能否解码。
        let asset = AVURLAsset(url: url)
        startTask = Task { @MainActor in
            do {
                let playable = try await asset.load(.isPlayable)
                guard playable else {
                    playerError = "系统播放器无法解析该视频"
                    return
                }
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                guard let video = videoTracks.first else {
                    playerError = "该文件没有视频轨道"
                    return
                }
                guard video.isDecodable else {
                    playerError = "系统播放器不支持该视频编码（可能只有声音），请用 VLC / Infuse 打开"
                    return
                }
                guard !Task.isCancelled else { return }

                let item = AVPlayerItem(asset: asset)
                let player = AVPlayer(playerItem: item)
                self.player = player

                item.publisher(for: \.status)
                    .receive(on: DispatchQueue.main)
                    .sink { status in
                        guard status == .failed else { return }
                        self.playerError = item.error?.localizedDescription
                            ?? "系统播放器无法播放此视频"
                        self.player = nil
                        player.pause()
                    }
                    .store(in: &cancellables)

                player.play()
            } catch {
                if Task.isCancelled { return }
                playerError = "系统播放器无法解析该视频：\(error.localizedDescription)"
            }
        }
    }

    private var preparingOverlay: some View {
        ZStack {
            Color.black.opacity(0.78)
                .ignoresSafeArea()

            VStack(spacing: Spacing.s3) {
                Text("正在准备文件")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Text(entry.name)
                    .font(Sf.metaFont)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)

                if let total = externalTotal, total > 0, let progress = externalProgress {
                    ProgressView(value: progress)
                        .tint(Sf.primary)
                        .frame(width: 240)
                    Text(
                        "\(Fmt.bytes.string(fromByteCount: externalBytes)) / \(Fmt.bytes.string(fromByteCount: total))"
                    )
                    .font(Sf.metaFont)
                    .foregroundStyle(.white.opacity(0.7))
                } else {
                    ProgressView()
                        .tint(.white)
                    Text("已下载 \(Fmt.bytes.string(fromByteCount: externalBytes))")
                        .font(Sf.metaFont)
                        .foregroundStyle(.white.opacity(0.7))
                }

                Text("大文件需要先完整复制到本机，再交给 VLC 等 App；导入过程也可能需要时间。")
                    .font(Sf.metaFont)
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)

                Button("取消") {
                    prepareTask?.cancel()
                    prepareTask = nil
                    preparingExternal = false
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
            .padding(Spacing.s6)
        }
    }

    /// 直接把该文件的 WebDAV 地址交给 Infuse / VLC，边读边播，不落盘。
    private func openDirect(with player: ExternalPlayer) {
        guard let url = store.externalPlayerURL(for: entry, player: player) else {
            directPlayerError = "无法生成 WebDAV 直连地址"
            return
        }
        directPlayerError = nil
        let name = player.displayName
        UIApplication.shared.open(url, options: [:]) { opened in
            guard !opened else { return }
            DispatchQueue.main.async {
                directPlayerError = "无法打开 \(name)，请确认已安装"
            }
        }
    }

    private func openExternal() {
        guard !preparingExternal else { return }
        preparingExternal = true
        externalProgress = 0
        externalBytes = 0
        externalTotal = nil
        player?.pause()

        prepareTask = Task { @MainActor in
            defer {
                preparingExternal = false
                prepareTask = nil
            }
            do {
                let url = try await store.prepareExternalPlaybackCopy(for: entry) { done, total in
                    Task { @MainActor in
                        self.externalBytes = done
                        self.externalTotal = total
                        self.externalProgress = total.flatMap {
                            $0 > 0 ? Double(done) / Double($0) : nil
                        }
                    }
                }
                guard !Task.isCancelled else {
                    store.cleanupTemporaryCopy(url)
                    return
                }
                openInPayload = OpenInPayload(url: url)
            } catch {
                let error = error as NSError
                guard error.code != NSURLErrorCancelled else { return }
                externalError = "准备文件失败：\(error.localizedDescription)"
            }
        }
    }
}
