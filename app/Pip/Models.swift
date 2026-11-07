// 设备模型与本地存储 — 对照 REVERSE.md §6。
// 原版 SharedPreferences 文件名 `devices`：
//   `devices`: JSON 数组，每项 {id, name, brand, host, port, credentials, extra}
//   `selected`: 当前选中设备 id
// 小米的 credentials / extra 恒为 null。字段名保持一致，便于对照。
import Foundation

struct PipDevice: Codable, Identifiable, Equatable {
    var id: String          // 小米："XIAOMI:<host>"（REVERSE.md §2，yt.q）
    var name: String        // isalive 返回的 devicename，或手动输入的名称
    var brand: String       // "XIAOMI"
    var host: String
    var port: Int           // 默认 6095
    var credentials: String?
    var extra: String?

    static func xiaomi(host: String, name: String, port: Int = 6095) -> PipDevice {
        PipDevice(id: "XIAOMI:\(host)", name: name, brand: "XIAOMI",
                  host: host, port: port, credentials: nil, extra: nil)
    }

    /// 设备头显示名：小米名字去掉“的”之后的部分（REVERSE.md §5，zg1 case 0）。
    /// 如 "小米电视的客厅" -> "小米电视"；无“的”则原样显示。
    var displayName: String {
        if let idx = name.firstIndex(of: "的") {
            let head = String(name[..<idx])
            return head.isEmpty ? name : head
        }
        return name
    }
}

// 注意：不标 @MainActor（@StateObject 初始化 @MainActor 类在部分 Swift 版本会报
// main actor-isolated initializer 错误）。所有调用点都在 SwiftUI 主线程上下文
//（按钮动作 / .task），@Published 更新都在主线程。
final class DeviceStore: ObservableObject {
    @Published private(set) var devices: [PipDevice] = []
    @Published var selectedID: String?

    private let devicesKey = "devices"
    private let selectedKey = "selected"

    init() {
        load()
    }

    var selectedDevice: PipDevice? {
        guard let id = selectedID else { return nil }
        return devices.first { $0.id == id }
    }

    func load() {
        if let data = UserDefaults.standard.data(forKey: devicesKey),
           let decoded = try? JSONDecoder().decode([PipDevice].self, from: data) {
            devices = decoded
        }
        selectedID = UserDefaults.standard.string(forKey: selectedKey)
        if selectedID != nil && selectedDevice == nil {
            selectedID = nil
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: devicesKey)
        }
        if let id = selectedID {
            UserDefaults.standard.set(id, forKey: selectedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedKey)
        }
    }

    /// 发现/手动添加后合并：同 id 去重（已保存设备优先保留其名称）。
    func upsert(_ device: PipDevice) {
        if let i = devices.firstIndex(where: { $0.id == device.id }) {
            devices[i] = device
        } else {
            devices.append(device)
        }
        save()
    }

    func upsertMany(_ found: [PipDevice]) {
        for d in found { upsert(d) }
    }

    func select(_ device: PipDevice) {
        upsert(device)
        selectedID = device.id
        save()
    }

    func deselect() {
        selectedID = nil
        save()
    }

    func remove(_ device: PipDevice) {
        devices.removeAll { $0.id == device.id }
        if selectedID == device.id { selectedID = nil }
        save()
    }
}
