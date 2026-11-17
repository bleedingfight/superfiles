import SwiftUI

/// 复制/移动的目标选择器：应用存储 + 各网络挂载，可逐层下钻。
@MainActor
struct DestinationPicker: View {
    @ObservedObject var store: VfsStore
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var currentId = ""
    @State private var path = ""
    @State private var directories: [Entry] = []
    @State private var history: [String] = []
    @State private var loading = false

    var body: some View {
        NavigationStack {
            List {
                Section("位置") {
                    locationRow("应用存储", id: store.appRoot, icon: "internaldrive")
                    ForEach(store.mounts) { mount in
                        locationRow(mount.label, id: mount.rootId, icon: icon(for: mount.scheme))
                    }
                }

                Section("子文件夹") {
                    if loading {
                        HStack(spacing: Spacing.s2) {
                            ProgressView().tint(Sf.primary)
                            Text("加载中…")
                                .font(Sf.metaFont)
                                .foregroundStyle(Sf.onSurfaceVariant)
                        }
                        .listRowBackground(Sf.surfaceCard)
                    } else if directories.isEmpty {
                        Text("没有子文件夹")
                            .font(Sf.metaFont)
                            .foregroundStyle(Sf.onSurfaceVariant)
                            .listRowBackground(Sf.surfaceCard)
                    } else {
                        ForEach(directories, id: \.id) { dir in
                            Button {
                                open(dir.id)
                            } label: {
                                HStack {
                                    Label(dir.name, systemImage: "folder")
                                        .font(Sf.fileNameFont)
                                        .foregroundStyle(Sf.onSurface)
                                        .lineLimit(1)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Sf.outline)
                                }
                            }
                            .listRowBackground(Sf.surfaceCard)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Sf.surface)
            .navigationTitle("选择目标文件夹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !history.isEmpty {
                        Button {
                            back()
                        } label: {
                            Image(systemName: "chevron.backward")
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: Spacing.s2) {
                        Button("取消") { dismiss() }
                        Button("选择此文件夹") {
                            onPick(currentId)
                            dismiss()
                        }
                        .disabled(currentId.isEmpty)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Text(path)
                        .font(Sf.footerFont)
                        .foregroundStyle(Sf.onSurfaceVariant)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, Sf.safeMargin)
                .padding(.vertical, 6)
                .background(Sf.surface)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Sf.outline.opacity(0.25))
                        .frame(height: 0.5)
                }
            }
        }
        .onAppear {
            if currentId.isEmpty { selectRoot(store.appRoot) }
        }
    }

    private func locationRow(_ title: String, id: String, icon: String) -> some View {
        Button {
            selectRoot(id)
        } label: {
            HStack {
                Label(title, systemImage: icon)
                    .font(Sf.fileNameFont)
                    .foregroundStyle(Sf.onSurface)
                    .lineLimit(1)
                Spacer()
                if currentId == id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Sf.primary)
                }
            }
        }
        .listRowBackground(Sf.surfaceCard)
    }

    private func icon(for scheme: String) -> String {
        switch scheme {
        case "smb": return "externaldrive"
        case "sftp": return "terminal"
        default: return "cloud"
        }
    }

    private func selectRoot(_ id: String) {
        history = []
        load(id)
    }

    private func open(_ id: String) {
        history.append(currentId)
        load(id)
    }

    private func back() {
        guard let previous = history.popLast() else { return }
        load(previous)
    }

    private func load(_ id: String) {
        loading = true
        currentId = id
        Task { @MainActor in
            let list = await store.listDirectories(in: id)
            directories = list
            path = store.displayPath(of: id)
            loading = false
        }
    }
}
