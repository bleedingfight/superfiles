import SwiftUI

/// 添加 / 编辑 WebDAV / SMB / SFTP 网络存储。密码只写入 Keychain。
@MainActor
struct AddMountSheet: View {
    @ObservedObject var store: VfsStore
    /// 传入已保存连接时进入编辑模式（预填全部字段，保存后重挂载）。
    let editing: SavedMount?
    @Environment(\.dismiss) private var dismiss

    init(store: VfsStore, editing: SavedMount? = nil) {
        _store = ObservedObject(wrappedValue: store)
        self.editing = editing
        _kind = State(initialValue: editing?.kind ?? "webdav")
        _label = State(initialValue: editing?.label ?? "")
        _host = State(initialValue: editing?.host ?? "")
        _share = State(initialValue: editing?.share ?? "Media")
        _port = State(initialValue: editing.map { String($0.port) } ?? "")
        _username = State(initialValue: editing?.username ?? "")
        _password = State(initialValue: editing.flatMap { KeychainStore.load(account: $0.id.uuidString) } ?? "")
        _discovery = StateObject(wrappedValue: SMBDiscovery(netbiosName: { store.core.smbNetbiosName(host: $0) }))
    }

    @State private var kind = "webdav"
    @State private var label = ""
    @State private var host = ""
    @State private var share = "Media"
    @State private var port = ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var showCredentialHelp = false
    @State private var testState: TestState = .idle
    @State private var testError: String?
    @StateObject private var discovery: SMBDiscovery

    private enum TestState {
        case idle
        case testing
        case success
    }

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

                if kind == "smb" {
                    Section("局域网") {
                        if discovery.servers.isEmpty {
                            HStack(spacing: Spacing.s2) {
                                if discovery.isScanning {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(discovery.isScanning ? "正在扫描 SMB 服务器…" : "未发现 SMB 服务器")
                                    .foregroundStyle(Sf.onSurfaceVariant)
                            }
                        } else {
                            ForEach(discovery.servers) { server in
                                Button {
                                    host = server.host
                                    port = String(server.port)
                                    if label.trimmingCharacters(in: .whitespaces).isEmpty {
                                        label = server.name
                                    }
                                } label: {
                                    HStack(spacing: Spacing.s3) {
                                        Image(systemName: "server.rack")
                                            .foregroundStyle(Sf.primary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(server.name)
                                                .foregroundStyle(Sf.onSurface)
                                            Text("\(server.host):\(server.port)")
                                                .font(Sf.metaFont)
                                                .foregroundStyle(Sf.onSurfaceVariant)
                                        }
                                        Spacer(minLength: Spacing.s2)
                                        Image(systemName: "arrow.up.left.circle")
                                            .foregroundStyle(Sf.primary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Button(discovery.isScanning ? "扫描中…" : "重新扫描") {
                            discovery.start()
                        }
                        .disabled(discovery.isScanning)

                        Text("自动扫描 Bonjour 广播的设备和当前 Wi-Fi 网段开放 445 端口的主机；未出现时仍可手动填写。")
                            .font(Sf.metaFont)
                            .foregroundStyle(Sf.onSurfaceVariant)
                    }
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

                if kind == "webdav" {
                    Section {
                        Button {
                            testConnection()
                        } label: {
                            HStack(spacing: Spacing.s3) {
                                Image(systemName: "bolt.fill")
                                    .foregroundStyle(testState == .success ? Sf.success : Sf.primary)
                                Text("测试连接")
                                    .foregroundStyle(Sf.onSurface)
                                Spacer(minLength: Spacing.s2)
                                if testState == .testing {
                                    ProgressView()
                                        .controlSize(.small)
                                } else if testState == .success {
                                    Text("连接成功")
                                        .font(Sf.metaFont)
                                        .foregroundStyle(Sf.success)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(
                            testState == .testing || busy || trimmedHost.isEmpty
                        )

                        if let testError {
                            Text(testError)
                                .font(Sf.metaFont)
                                .foregroundStyle(Sf.error)
                        }
                    }
                }

                if let error {
                    Section {
                        Text(error)
                            .font(Sf.metaFont)
                            .foregroundStyle(Sf.error)
                    }
                }

            }
            .scrollContentBackground(.hidden)
            .background(Sf.surface)
            .navigationTitle(editing == nil ? "添加网络存储" : "编辑网络存储")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    HStack(spacing: Spacing.s2) {
                        Button {
                            showCredentialHelp = true
                        } label: {
                            Image(systemName: "questionmark.circle")
                        }
                        .accessibilityLabel("凭据保存说明")

                        Button(busy ? (editing == nil ? "连接中…" : "保存中…") : (editing == nil ? "连接" : "保存")) {
                            connect()
                        }
                        .disabled(busy || !canConnect)
                    }
                }
            }
            .onChange(of: kind) { value in
                if value == "smb" {
                    port = "445"
                    discovery.start()
                } else {
                    discovery.stop(reset: true)
                }
                if value == "sftp" { port = "22" }
                if value != "webdav" { resetTest() }
            }
            .onChange(of: host) { _ in resetTest() }
            .onChange(of: username) { _ in resetTest() }
            .onChange(of: password) { _ in resetTest() }
            .onAppear {
                if port.isEmpty { port = "445" }
                if label.isEmpty, !host.isEmpty { label = host }
                if kind == "smb" { discovery.start() }
            }
            .onDisappear { discovery.stop() }
            .alert("凭据保存", isPresented: $showCredentialHelp) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text("用户名和密码只写入系统钥匙串，不会明文存在 App 数据里；断开这个网络存储时会一并删除。")
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

    private func resetTest() {
        testState = .idle
        testError = nil
    }

    private func testConnection() {
        resetTest()
        testState = .testing
        let host = trimmedHost
        Task { @MainActor in
            do {
                try await store.testWebdavConnection(
                    host: host,
                    username: username,
                    password: password
                )
                testState = .success
            } catch {
                testState = .idle
                testError = VfsStore.describe(error)
            }
        }
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
                let location: MountedLocation
                if let editing {
                    location = try await store.updateMount(editing, draft: draft)
                } else {
                    location = try await store.addMount(draft)
                }
                store.activate(.mount(location.rootId))
                dismiss()
            } catch {
                self.error = VfsStore.describe(error)
                self.busy = false
            }
        }
    }
}
