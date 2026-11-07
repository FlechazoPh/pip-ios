# Pip iOS — 小米电视版（未签名，自用侧载）

Pip（https://pip.qust.me ，Apple TV 的 Android 遥控器 v1.0）的 iOS 复刻，**仅小米安卓电视**。
依据 APK 静态逆向规格（`REVERSE.md`，app.pipremote，jadx）从零用 SwiftUI 重写，
不是把 APK 转制、也不是上游源码移植（上游未开源）。

## 实现的功能

- 发现：取本机 Wi-Fi IP 推 /24，1–254 跳过本机，48 并发，TCP 连 6095（350ms），
  通了再 GET `isalive`（800ms），响应含 `"status":0` 且取到 `devicename` 即认作小米电视
- 手动添加：名称 / IP / 端口（默认 6095），保存前先 `isalive` 校验
- 遥控：D-pad 上下左右 + OK、播放/暂停（发 `enter`，与 OK 相同，照原版）、主页、返回、
  菜单、电源、音量±、静音（循环调音量模拟，缓存原音量、每次 `getvolume` 核对、最多 101 次）
- 不支持的操作保留按钮并弹 Toast：“这台设备没有控制中心”/“这台设备不支持这个操作”
- 每次按键前未连接先 `isalive`，网络错误自动重连重试一次，仍失败显示“电视未响应”+轻点重试
- 存储：UserDefaults 存 `devices` JSON + `selected`，字段与原版 SharedPreferences 一致

## 明确不做的（小米分支本来就没有）

触控板、正在播放（锁屏/通知/后台）、应用列表、自动键盘、配对/PIN、硬件音量键拦截
（iOS 无等价 API，改屏上按钮）。Apple TV / MRP / AirPlay 一律不做。

## 构建

GitHub Actions（macos-15-intel + Xcode 26）打未签名 IPA：

- `app/Pip.xcodeproj`，bundle id `app.pipremote.ios`，版本 1.0（build 1），最低 iOS 15.0
- push 到 main 或手动触发 `.github/workflows/build.yml`，产物为 workflow artifact
  `pip-xiaomi-unsigned.ipa`（无签名，需自行签名后侧载安装）
- 仅静态验证（IPA 结构、Info.plist、权限字符串），真机实测留给用户

## 权限

- `NSLocalNetworkUsageDescription`：发现与遥控局域网内的小米电视
- `NSAppTransportSecurity.NSAllowsLocalNetworking`：局域网明文 HTTP（电视端只提供 HTTP）
