// Pip — iOS 版（仅小米电视）
// 依据 ~/workspace/projects/pip-ios/REVERSE.md 静态逆向规格从零复刻。
// 小米分支：纯明文 HTTP，无配对、无加密、无鉴权。Apple TV / MRP / AirPlay 一律不做。
import SwiftUI

@main
struct PipApp: App {
    @StateObject private var store = DeviceStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: DeviceStore

    var body: some View {
        Group {
            if let device = store.selectedDevice {
                RemoteView(device: device)
            } else {
                DeviceListView()
            }
        }
        .environmentObject(store)
    }
}
