// UI — 对照 REVERSE.md §5（fh1 / lp0 / zg1）。
// 只有两个页面：设备选择页 + 遥控页。小米分支无触控板、无正在播放、无应用列表、
// 无键盘、无配对——不要自造这些页面。
import SwiftUI

// MARK: - Toast（原版 l72 不支持操作时只弹 Toast，不重试）

struct ToastModifier: ViewModifier {
    var message: String?
    func body(content: Content) -> some View {
        ZStack(alignment: .bottom) {
            content
            if let message {
                Text(message)
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(.systemGray6))
                    .foregroundColor(.primary)
                    .cornerRadius(20)
                    .shadow(radius: 4)
                    .padding(.bottom, 32)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: message)
    }
}

extension View {
    func toast(_ message: String?) -> some View {
        modifier(ToastModifier(message: message))
    }
}

// MARK: - 设备选择页

struct DeviceListView: View {
    @EnvironmentObject var store: DeviceStore
    @State private var scanning = false
    @State private var scanError: String?
    @State private var toast: String?
    @State private var showManualAdd = false
    @State private var connectingID: String?

    var body: some View {
        NavigationView {
            List {
                if store.devices.isEmpty && !scanning {
                    Section {
                        VStack(spacing: 8) {
                            Text("还没有设备")
                                .font(.headline)
                            Text("轻点选择要遥控的设备")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                }
                ForEach(store.devices) { device in
                    Button {
                        connect(device)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "tv")
                                .font(.title3)
                                .foregroundColor(.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.displayName)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Text("\(device.host):\(device.port)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if connectingID == device.id {
                                ProgressView()
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) { store.remove(device) }
                    }
                }
                Section {
                    Button {
                        Task { await scan() }
                    } label: {
                        HStack {
                            if scanning { ProgressView() }
                            Text(scanning ? "正在扫描局域网…" : "重新扫描")
                        }
                    }
                    .disabled(scanning)
                    Button("手动添加") { showManualAdd = true }
                } footer: {
                    if let scanError {
                        Text(scanError).foregroundColor(.red)
                    } else {
                        Text("自动发现会扫描当前 Wi-Fi 的 6095 端口。首次使用需要允许访问局域网。")
                    }
                }
            }
            .navigationTitle("Pip")
            .sheet(isPresented: $showManualAdd) {
                ManualAddView()
            }
            .task {
                if store.devices.isEmpty { await scan() }
            }
            .toast(toast)
        }
        .navigationViewStyle(.stack)
    }

    private func scan() async {
        guard !scanning else { return }
        scanning = true
        scanError = nil
        defer { scanning = false }
        guard Discovery.localWiFiIPv4() != nil else {
            scanError = "未连入 Wi-Fi，无法扫描局域网"
            return
        }
        let found = await Discovery.scan()
        store.upsertMany(found)
        if found.isEmpty && store.devices.isEmpty {
            scanError = "没有发现小米电视，请确认电视与手机在同一 Wi-Fi"
        }
    }

    private func connect(_ device: PipDevice) {
        connectingID = device.id
        Task {
            let client = XiaomiClient(device: device)
            let ok = await client.isAlive()
            connectingID = nil
            if ok {
                store.select(device)
            } else {
                showToast("电视未响应")
            }
        }
    }

    private func showToast(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if toast == message { toast = nil }
        }
    }
}

// MARK: - 手动添加（qh1.addManually，REVERSE.md §4.2）

struct ManualAddView: View {
    @EnvironmentObject var store: DeviceStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var host = ""
    @State private var portText = ""
    @State private var error: String?
    @State private var checking = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("设备")) {
                    TextField("名称", text: $name)
                    TextField("IP 地址", text: $host)
                        .keyboardType(.decimalPad)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("端口", text: $portText)
                        .keyboardType(.numberPad)
                        .placeholder(when: portText.isEmpty) {
                            Text("6095（默认）").foregroundColor(.secondary)
                        }
                }
                Section(header: Text("品牌")) {
                    Text("小米")
                }
                if let error {
                    Section { Text(error).foregroundColor(.red) }
                }
                Section {
                    Button(checking ? "正在验证…" : "添加") {
                        Task { await add() }
                    }
                    .disabled(checking || host.trimmingCharacters(in: .whitespaces).isEmpty)
                } footer: {
                    Text("保存前会先验证电视是否响应（isalive）。")
                }
            }
            .navigationTitle("手动添加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func add() async {
        let host = host.trimmingCharacters(in: .whitespaces)
        let port = Int(portText.trimmingCharacters(in: .whitespaces)) ?? 6095
        let name = name.trimmingCharacters(in: .whitespaces)
        checking = true
        defer { checking = false }
        // 手动添加后同样先走 isalive 校验再进遥控页（REVERSE.md §4.2）。
        let probe = PipDevice.xiaomi(host: host, name: name.isEmpty ? host : name, port: port)
        let client = XiaomiClient(device: probe)
        guard await client.isAlive() else {
            error = "电视未响应，请检查 IP 与端口"
            return
        }
        store.select(probe)
        dismiss()
    }
}

extension View {
    func placeholder<Content: View>(when shouldShow: Bool, @ViewBuilder placeholder: () -> Content) -> some View {
        ZStack(alignment: .leading) {
            placeholder().opacity(shouldShow ? 1 : 0)
            self
        }
    }
}

// MARK: - 遥控页（fh1.g，REVERSE.md §5）

struct RemoteView: View {
    @EnvironmentObject var store: DeviceStore
    let device: PipDevice

    @State private var client: XiaomiClient?
    @State private var toast: String?
    @State private var connectionFailed = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                // 设备头：品牌图标 + 设备名 + 切换设备（zg1）
                HStack(spacing: 10) {
                    Image(systemName: "tv")
                        .font(.title3)
                    Text(device.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Button("切换设备") {
                        Task { await client?.disconnect() }
                        store.deselect()
                    }
                    .font(.subheadline)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.top, 8)

                if connectionFailed {
                    Button {
                        Task { await retry() }
                    } label: {
                        HStack {
                            Image(systemName: "wifi.exclamationmark")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("连接失败").font(.subheadline).bold()
                                Text("轻点重试").font(.caption)
                            }
                            Spacer()
                            Image(systemName: "arrow.clockwise")
                        }
                        .foregroundColor(.white)
                        .padding(12)
                        .background(Color.red.opacity(0.7))
                        .cornerRadius(12)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }

                Spacer()

                // 方向键区：上/下/左/右 + OK（qa / de）
                VStack(spacing: 18) {
                    remoteButton(systemName: "chevron.up", label: "上") { try await key(.up) }
                    HStack(spacing: 44) {
                        remoteButton(systemName: "chevron.left", label: "左") { try await key(.left) }
                        okButton()
                        remoteButton(systemName: "chevron.right", label: "右") { try await key(.right) }
                    }
                    remoteButton(systemName: "chevron.down", label: "下") { try await key(.down) }
                }

                Spacer()

                // 功能按钮行（t21）：播放/暂停、主页、返回、菜单、电源、静音、音量 ±
                VStack(spacing: 14) {
                    HStack(spacing: 14) {
                        funcButton(systemName: "playpause.fill", title: "播放/暂停") {
                            // PLAY_PAUSE 发的也是 enter，与 OK 相同（REVERSE.md §3.2）
                            try await key(.playPause)
                        }
                        funcButton(systemName: "house.fill", title: "主页") { try await key(.home) }
                        funcButton(systemName: "chevron.backward", title: "返回") { try await key(.back) }
                        funcButton(systemName: "ellipsis", title: "菜单") { try await key(.menu) }
                    }
                    HStack(spacing: 14) {
                        funcButton(systemName: "power", title: "电源") { try await key(.power) }
                        funcButton(systemName: "speaker.slash.fill", title: "静音") {
                            try await mute()
                        }
                        funcButton(systemName: "speaker.wave.1.fill", title: "音量－") {
                            try await key(.volumeDown)
                        }
                        funcButton(systemName: "speaker.wave.3.fill", title: "音量＋") {
                            try await key(.volumeUp)
                        }
                    }
                    // 原版保留但小米不支持的操作：点按只弹 Toast（REVERSE.md §3.2 / §7）
                    HStack(spacing: 14) {
                        funcButton(systemName: "rectangle.grid.2x2.fill", title: "控制中心") {
                            try await unsupported { try $0.unsupportedControlCenter() }
                        }
                        funcButton(systemName: "backward.end.fill", title: "上一首") {
                            try await unsupported { try $0.unsupportedSkip() }
                        }
                        funcButton(systemName: "forward.end.fill", title: "下一首") {
                            try await unsupported { try $0.unsupportedSkip() }
                        }
                        funcButton(systemName: "goforward.10", title: "快进 10 秒") {
                            try await unsupported { try $0.unsupportedSkip() }
                        }
                        funcButton(systemName: "gobackward.10", title: "快退 10 秒") {
                            try await unsupported { try $0.unsupportedSkip() }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
        }
        .toast(toast)
        .onAppear {
            if client == nil { client = XiaomiClient(device: device) }
        }
    }

    // MARK: - 按键分发（u00.a 包装：IOException 重试一次在 XiaomiClient 内；l72 只弹 Toast）

    private func key(_ key: RemoteKey) async throws {
        guard let client else { return }
        do {
            try await client.sendKey(key)
            connectionFailed = false
        } catch let e as PipError {
            handle(error: e)
            throw e
        }
    }

    private func mute() async throws {
        guard let client else { return }
        do {
            try await client.toggleMute()
            connectionFailed = false
        } catch let e as PipError {
            handle(error: e)
            throw e
        }
    }

    /// 不支持的操作（ke2 抛 l72）：只弹 Toast，不重试（REVERSE.md §3.1）。
    private func unsupported(_ call: (XiaomiClient) throws -> Never) async throws {
        guard let client else { return }
        do {
            try call(client)
        } catch let e as PipError {
            handle(error: e)
            throw e
        }
    }

    private func handle(error: PipError) {
        switch error {
        case .notResponding:
            connectionFailed = true
        case .unsupported(let msg), .volumeTarget(let msg):
            showToast(msg)
        }
    }

    private func retry() async {
        guard let client else { return }
        if await client.isAlive() {
            connectionFailed = false
        } else {
            showToast("电视未响应")
        }
    }

    private func showToast(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if toast == message { toast = nil }
        }
    }

    // MARK: - 按钮样式

    private func remoteButton(systemName: String, label: String, action: @escaping () async throws -> Void) -> some View {
        Button {
            Task {
                do { try await action() } catch { /* 错误已在 handle() 里处理 */ }
            }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 68, height: 68)
                .background(Color(white: 0.18))
                .clipShape(Circle())
        }
        .accessibilityLabel(label)
    }

    private func okButton() -> some View {
        Button {
            Task {
                do { try await key(.ok) } catch { }
            }
        } label: {
            Text("OK")
                .font(.headline)
                .foregroundColor(.black)
                .frame(width: 84, height: 84)
                .background(Color.white)
                .clipShape(Circle())
        }
        .accessibilityLabel("确认")
    }

    private func funcButton(systemName: String, title: String, action: @escaping () async throws -> Void) -> some View {
        Button {
            Task {
                do { try await action() } catch { /* 错误已在 handle() 里处理 */ }
            }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: systemName)
                    .font(.system(size: 20))
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(Color(white: 0.18))
            .cornerRadius(14)
        }
        .accessibilityLabel(title)
    }
}
