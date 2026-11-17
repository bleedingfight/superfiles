import SwiftUI
import UIKit

struct ImageGalleryRequest: Identifiable {
    let id = UUID()
    let entries: [Entry]
    let startID: String
}

/// 全屏图片浏览器：左右滑动切换当前列表里的上一张/下一张图片。
@MainActor
struct ImageGalleryView: View {
    @ObservedObject var store: VfsStore
    let entries: [Entry]
    @Environment(\.dismiss) private var dismiss

    @State private var index: Int
    @State private var images: [String: UIImage] = [:]
    @State private var temporaryURLs: [String: URL] = [:]
    @State private var failed: Set<String> = []
    @State private var loading: Set<String> = []
    @State private var dismissed = false

    init(store: VfsStore, entries: [Entry], startID: String) {
        self.store = store
        self.entries = entries
        _index = State(initialValue: entries.firstIndex { $0.id == startID } ?? 0)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if entries.indices.contains(index) {
                page(entries[index])
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .contentShape(Rectangle())
                    .gesture(swipeGesture)
            }
        }
        .overlay(alignment: .top) { header }
        .statusBarHidden()
        .onAppear {
            dismissed = false
            loadNeighbors(index)
        }
        .onChange(of: index) { value in
            loadNeighbors(value)
            trim(around: value)
        }
        .onDisappear {
            dismissed = true
            cleanupAll()
        }
    }

    /// 只在手势结束时直接切换到上一张/下一张，不跟随手指移动，
    /// 避免过渡时同时露出两张图的一半。
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                let horizontal = value.translation.width
                guard abs(horizontal) > abs(value.translation.height) else { return }
                if horizontal < -60 {
                    step(1)
                } else if horizontal > 60 {
                    step(-1)
                }
            }
    }

    private func step(_ delta: Int) {
        let next = index + delta
        guard entries.indices.contains(next) else { return }
        index = next
    }

    @ViewBuilder
    private func page(_ entry: Entry) -> some View {
        Group {
            if let image = images[entry.id] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if failed.contains(entry.id) {
                VStack(spacing: Spacing.s2) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 40))
                    Text("无法加载图片")
                        .font(Sf.metaFont)
                }
                .foregroundStyle(.white.opacity(0.75))
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                Text(entries.indices.contains(index) ? entries[index].name : "")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(min(index + 1, entries.count)) / \(entries.count)")
                    .font(Sf.metaFont)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.s4)
        .padding(.top, Spacing.s2)
    }

    private func load(_ entry: Entry) {
        let id = entry.id
        guard images[id] == nil, !failed.contains(id), !loading.contains(id) else { return }
        loading.insert(id)

        Task { @MainActor in
            defer { loading.remove(id) }

            if let local = store.localFileURL(for: entry),
               let image = UIImage(contentsOfFile: local.path) {
                images[id] = image
                return
            }

            guard let url = await store.localCopy(for: entry, silent: true) else {
                failed.insert(id)
                return
            }
            guard !dismissed else {
                store.cleanupTemporaryCopy(url)
                return
            }
            if let image = UIImage(contentsOfFile: url.path) {
                temporaryURLs[id] = url
                images[id] = image
            } else {
                store.cleanupTemporaryCopy(url)
                failed.insert(id)
            }
        }
    }

    private func loadNeighbors(_ center: Int) {
        guard !entries.isEmpty else { return }
        for offset in [center, center + 1, center - 1] where entries.indices.contains(offset) {
            load(entries[offset])
        }
    }

    /// 只缓存当前附近几张，避免大相册把内存吃满。
    private func trim(around center: Int) {
        let keep = Set((-2...2).compactMap { delta -> String? in
            let i = center + delta
            guard entries.indices.contains(i) else { return nil }
            return entries[i].id
        })
        for id in images.keys where !keep.contains(id) {
            images.removeValue(forKey: id)
            if let url = temporaryURLs.removeValue(forKey: id) {
                store.cleanupTemporaryCopy(url)
            }
        }
        failed = failed.filter { keep.contains($0) }
    }

    private func cleanupAll() {
        for url in temporaryURLs.values {
            store.cleanupTemporaryCopy(url)
        }
        temporaryURLs.removeAll()
        images.removeAll()
    }
}
