import SwiftUI

/// 添加 WebDAV / SMB / SFTP 网络存储。密码只写入 Keychain。
@MainActor
struct AddMountSheet: View {
    @ObservedObject var store: VfsStore
    @Environment(\.dismiss) private var dismiss

    @State private var kind = "webdav"
    @State private var label = ""
    @State private var host = ""
    @State private var share = "Media"
    @State private var port = ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("协议", selection: $kind) {
                        Text("WebDAV").tag("webdav")
                        Text("SMB").tag("smb")
                        Text("SFTP").tag("sftp")
                    }
                    .pickerStyle(.segmented)
                }

                Section("连接") {
                    TextField("名称（可留空）", text: $label)

                    if kind == "webdav" {
                        TextField("地址，例如 https://nas.local/dav", text: $host)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        TextField("主机，例如 192.168.1.10", text: $host)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    if kind == "smb" {
                        TextField("共享名，例如 Media", text: $share)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    if kind != "webdav" {
                        TextField("端口", text: $port)
                            .keyboardType(.numberPad)
                    }

                    TextField("用户名", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("密码", text: $password)
                }

                if let error {
                    Section {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Text("凭据保存在系统钥匙串；断开连接时一并删除。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("添加网络存储")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "连接中…" : "连接") { connect() }
                        .disabled(busy || !canConnect)
                }
            }
            .onChange(of: kind) { value in
                if value == "smb" { port = "445" }
                if value == "sftp" { port = "22" }
            }
            .onAppear {
                if port.isEmpty { port = "445" }
                if label.isEmpty, !host.isEmpty { label = host }
            }
        }
    }

    private var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canConnect: Bool {
        guard !trimmedHost.isEmpty else { return false }
        if kind == "smb" {
            return !share.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    private var resolvedPort: Int {
        if let value = Int(port), value > 0, value <= 65535 { return value }
        return kind == "sftp" ? 22 : 445
    }

    private func connect() {
        error = nil
        busy = true
        let draft = MountDraft(
            label: label,
            kind: kind,
            host: trimmedHost,
            share: share.trimmingCharacters(in: .whitespacesAndNewlines),
            port: resolvedPort,
            username: username,
            password: password
        )
        Task { @MainActor in
            do {
                let location = try await store.addMount(draft)
                store.sidebar = .mount(location.rootId)
                dismiss()
            } catch {
                self.error = VfsStore.describe(error)
                self.busy = false
            }
        }
    }
}
