# Pip iOS 复刻 — 范围（2026-11-08 用户确认）

只做小米安卓电视，不做 Apple TV。

依据（APK 静态逆向，app.pipremote，jadx）：
- 设备分品牌枚举 `zj`：APPLE_TV 49152、XIAOMI 6095、TCL 6553、HISENSE 36669、XBOX 5050，`b00` 的 `c` 字段即默认端口。
- 小米是独立驱动 `ke2.java`，与 Apple TV 的 AirPlay/MRP（`w3.java`，7000 端口、冒充 iPhone14,3、com.apple.TVRemote）完全分开。
- 小米协议：明文 HTTP，`http://<电视IP>:6095`
  - 存活：`GET /request?action=isalive`，回包含 `"status":0`
  - 按键：`GET /controller?action=keyevent&keycode=<up|down|left|right|enter|back|home|menu|volumeup|volumedown|power>`
  - 音量：`GET /controller?action=getvolume`，解析 `"volume":(\d+)`
  - 静音无原生接口：循环 volumeup/volumedown 调到 0 / 恢复缓存音量来模拟
  - 发现：扫局域网 6095 端口通 + isalive 返回 devicename
- 小米明确不支持（ke2 抛错）：
  - CONTROL_CENTER（13）：“这台设备没有控制中心”
  - NEXT / PREVIOUS / SKIP_FORWARD / SKIP_BACKWARD（14-17）：“这台设备不支持这个操作”
  - 无正在播放、无应用列表、无自动键盘 — 这些是 Apple TV 专属（MRP），小米分支没有对应接口（`mg1` 只有按键/存活/关闭）。
- 结论：iOS 版只需实现小米 HTTP 遥控：方向/确认/返回/主页/菜单/播放暂停（映射为 enter）/音量加减/静音模拟/电源，无需 PIN 配对、无加密、无 Apple TV 相关功能。
