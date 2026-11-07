import SwiftUI

struct ContentView: View {
    @StateObject private var store = VfsStore()
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var pendingDelete: Entry?

    var body: some View {
        NavigationStack {
            list
                .navigationTitle(store.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .overlay { if store.isLoading { ProgressView() } }
                .refreshable { store.load(store.currentId) }
                .task { store.start() }
                .safeAreaInset(edge: .bottom) { footer }
        }
        .alert("新建文件夹", isPresented: $showNewFolder) {
            TextField("名称", text: $newFolderName)
            Button("创建") {
                store.createFolder(named: newFolderName)
                newFolderName = ""
            }
            Button("取消", role: .cancel) { newFolderName = "" }
        }
        .confirmationDialog(
            "删除「\(pendingDelete?.name ?? "")」？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let entry = pendingDelete { store.delete(entry) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        }
        .alert(
            "出错了",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.dismissError() } }
            )
        ) {
            Button("好", role: .cancel) { store.dismissError() }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var list: some View {
        List {
            ForEach(store.entries, id: \.id) { entry in
                FileRow(entry: entry)
                    .contentShape(Rectangle())
                    .onTapGesture { store.open(entry) }
                    .swipeActions {
                        Button(role: .destructive) {
                            pendingDelete = entry
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.plain)
        .overlay {
            if store.entries.isEmpty && !store.isLoading {
                VStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("这里还没有文件").font(.headline)
                    Text("点右上角「建立索引」，或新建文件夹")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if store.canGoUp {
                Button {
                    store.goUp()
                } label: {
                    Image(systemName: "chevron.backward")
                }
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button {
                    showNewFolder = true
                } label: {
                    Label("新建文件夹", systemImage: "folder.badge.plus")
                }
                Button {
                    store.indexAll()
                } label: {
                    Label("建立索引", systemImage: "arrow.triangle.2.circlepath")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(store.subtitle)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.thinMaterial)
    }
}

private struct FileRow: View {
    let entry: Entry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(entry.kind == .directory ? Color.accentColor : Color.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if entry.kind == .directory {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        switch entry.kind {
        case .directory: return "folder.fill"
        case .symlink: return "link"
        default:
            if let mime = entry.mime {
                if mime.hasPrefix("image/") { return "photo" }
                if mime.hasPrefix("video/") { return "film" }
                if mime.hasPrefix("audio/") { return "music.note" }
                if mime.hasPrefix("text/") { return "doc.text" }
            }
            return "doc"
        }
    }

    private var detail: String {
        guard entry.kind != .directory else { return "文件夹" }
        var parts = [ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file)]
        if let mime = entry.mime {
            parts.append(String(mime.split(separator: "/").last ?? ""))
        }
        return parts.joined(separator: " · ")
    }
}
