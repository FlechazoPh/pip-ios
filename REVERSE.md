# Pip iOS 复刻规格 — 小米安卓电视分支（REVERSE.md）

> 来源：静态逆向 `Pip.apk`（2.5 MB，SHA-256 `a9e945b10f8d2b753639cfc9127b919404ef9d0c42570c7b089a26c64c0cdc0c`，与 https://pip.qust.me 官网一致）。
> 工具：apktool 3.0.3 + jadx（`~/workspace/tools/rea/` 工具链）。代码经 R8 重度混淆（应用类全在 `defpackage` 短名），以下结论以 jadx 反编译 + smali 交叉核对为准；反编译失败的方法（`p0.r`、`ge.r`、`h00.a`、`k00` 等）已标注。
> **范围：只做小米安卓电视。Apple TV / MRP / AirPlay / 配对相关一律不做，见 §8。**

## 1. 应用身份

| 项 | 值 |
|---|---|
| 包名 | `app.pipremote` |
| 应用名 | Pip |
| 版本 | 1.0（versionCode 1） |
| minSdk / targetSdk / compileSdk | 26（Android 8.0）/ 36 / 37 |
| 语言/框架 | Kotlin + Jetpack Compose，单 Activity，单 `classes.dex`（4.5 MB） |
| 原生库 | 仅 `libandroidx.graphics.path.so`（Compose 自带），无自研 native 代码 |
| `usesCleartextTraffic` | `true`（明文 HTTP） |
| `allowBackup` | `false` |
| 第三方库 | 仅 AndroidX + Kotlin + BouncyCastle（后者只用于 Apple TV 配对/加密，**小米分支完全不用**）；无 OkHttp/Retrofit/Protobuf——网络全是 `java.net.HttpURLConnection` / `java.net.Socket` 手写 |

权限（AndroidManifest）：`INTERNET`、`ACCESS_NETWORK_STATE`、`ACCESS_WIFI_STATE`、`CHANGE_WIFI_MULTICAST_STATE`、`VIBRATE`、`FOREGROUND_SERVICE`、`FOREGROUND_SERVICE_MEDIA_PLAYBACK`、`POST_NOTIFICATIONS`。
组件：`MainActivity`（唯一 Activity，LAUNCHER）、`NowPlayingService`（foregroundServiceType=mediaPlayback，**只服务 Apple TV 的正在播放，见 §5**）。

## 2. 品牌与驱动分发

品牌枚举 `zj`（`zj.java`）：

| 品牌 | 显示名 | 默认端口 `zj.c` |
|---|---|---|
| APPLE_TV | Apple TV | 49152 |
| **XIAOMI** | **小米** | **6095** |
| TCL | TCL | 6553 |
| HISENSE | 海信 | 36669 |
| XBOX | Xbox | 5050 |

会话 `u00` 按品牌 ordinal 选驱动（`mg1` 接口：`b(RemoteKey)` 按键、`c()` 连接检查、`close()`、`a()` 心跳默认空实现）：

- 0 APPLE_TV → `xd`（Companion Link，**不做**）
- **1 XIAOMI → `ke2(host, port)`（本规格全部内容）**
- 2 TCL → `uy1`、3 HISENSE → `x8`、4 XBOX → `je2`（均不做）

设备模型 `b00`：`id`、`name`、`brand`、`host`、`port`、`credentials`（小米恒为 null）、`extra`（小米恒为 null）。
小米设备 id 生成（`yt.q`）：`"XIAOMI:" + host`，端口取品牌默认值 6095。

## 3. 小米协议：纯明文 HTTP（`ke2.java`，`mg1` 实现）

无配对、无加密、无鉴权、无账号、无云。每个操作都是一次独立的 `HttpURLConnection` GET，无持久连接、无自定义请求头。

### 3.1 连接检查 `ke2.c()`

```
GET http://<host>:6095/request?action=isalive
```

- 超时：connect 2500 ms / read 3000 ms（`ke2.e()`）。
- 成功条件：响应体包含 `"status":0`；否则抛错，UI 显示 `电视未响应`。
- 会话层（`u00.b()`）在每次按键前若未连接先调 `c()`；`u00.a()` 包装调用：`IOException` → 关闭驱动后**自动重连重试一次**，仍失败则进入错误态显示异常 message；`l72`（不支持的操作）→ 只弹 Toast，不重试。

### 3.2 按键 `ke2.b(RemoteKey)` → `GET /controller?action=keyevent&keycode=<name>`

`RemoteKey` 枚举 `ng1`（共 18 个）到 keycode 的映射：

| 按键 | keycode | 说明 |
|---|---|---|
| UP | `up` | 方向上 |
| DOWN | `down` | 方向下 |
| LEFT | `left` | 方向左 |
| RIGHT | `right` | 方向右 |
| OK | `enter` | 确认 |
| PLAY_PAUSE | `enter` | **注意：与 OK 相同，都是 `enter`**（`case 4 / case 8` 同分支） |
| BACK | `back` | 返回 |
| HOME | `home` | 主页 |
| MENU | `menu` | 菜单 |
| VOLUME_UP | `volumeup` | 音量 +1 |
| VOLUME_DOWN | `volumedown` | 音量 −1 |
| MUTE | — | 见 §3.4，不走 keyevent |
| POWER | `power` | 电源（仅发 keycode；电视关机/休眠后 HTTP 服务一般不可达，此时 `isalive` 先失败，UI 报 `电视未响应`） |
| CONTROL_CENTER | — | 抛 `l72("这台设备没有控制中心")` |
| NEXT / PREVIOUS / SKIP_FORWARD / SKIP_BACKWARD | — | 抛 `l72("这台设备不支持这个操作")` |

### 3.3 读音量 `ke2.d()`

```
GET http://<host>:6095/controller?action=getvolume
```

响应体用正则 `"volume"\s*:\s*(\d+)` 提取整数；匹配不到抛 `l72("这台电视不支持静音")`。即：**静音功能依赖电视返回音量数值**，不支持读音量的小米电视静音键直接报错。

### 3.4 静音 `MUTE`（`ke2.b` case 11，无专用静音接口，靠循环调音量模拟）

`ke2` 内部缓存上次静音前的音量 `c: Integer?`：

- **当前是静音态**（`c != null`）：循环发 `volumeup`，每发一次就 `getvolume()` 核对，直到音量 ≥ 缓存值后清空缓存；最多 101 次，调不到抛 `音量没有调到 <目标值>`。
- **当前非静音**（`c == null`）：先 `getvolume()` 读当前值；若 ≤ 0 直接返回；否则循环发 `volumedown`，每次核对，直到音量 ≤ 0，并把原音量记入缓存 `c`；最多 101 次，调不到抛 `音量没有调到 0`。

要点：静音 = 步进式循环（每次 ±1），不是一次请求；每次按键都带一次 `getvolume` 往返。复刻时照此实现，注意中途失败要保留/清理缓存状态与报错文案一致。

### 3.5 心跳 / 关闭

`ke2.a()`（心跳）与 `close()` 均为默认空实现：**小米分支无心跳、无长连接**，每次操作都是短连接 HTTP。

## 4. 发现：局域网 /24 扫描 + 手动添加

### 4.1 自动发现（`qh1.j()` 启动 `p0(qh1, byte 22)` → 扫描协程）

扫描由 `r01` + `yt.Q(ip)` 实现：

- 取本机 IPv4 前缀（到最后一个 `.` 为止，即 /24 网段；**前缀来源静态未完全确认**：dex 中无 `WifiManager.getConnectionInfo` / `NetworkInterface` / `Formatter.formatIpAddress` 调用，推测为调用方传入的本机 IP 字符串，iOS 复刻时直接用本机 Wi-Fi IP 推导即可）。
- 枚举 `前缀.1` ～ `前缀.254`，跳过本机 IP。
- 并发上限 48（`Semaphore cq1(48)`），每 IP 一个 `u8(byte 5)` 协程调 `yt.Q(ip)`。
- 同一轮扫描还并行做 Xbox 的 UDP 广播发现（`v11`，端口 5050，**不做**）。

每 IP 探测 `yt.Q(ip)` 的小米分支：

```
1. TCP connect <ip>:6095，超时 350 ms；不通 → 不是小米，跳过
2. GET http://<ip>:6095/request?action=isalive（connect 800 ms / read 800 ms）
3. 响应体用正则 "devicename"\s*:\s*"([^"]+)" 提取设备名（ke2.e）
4. 命中 → Device(id="XIAOMI:<ip>", name=<devicename>, brand=XIAOMI, host=<ip>, port=6095)
```

要点：

- **没有 mDNS/NSD、没有 SSDP、没有 UDP 广播**：小米发现就是纯 TCP 端口扫描。NSD 只用于 Apple TV 的 `_companion-link._tcp`（`h00`，MulticastLock 名 `aremote-discovery`，TXT `rpMd` 以 `AppleTV` 开头才采纳）。
- 同一轮 `yt.Q` 还会探 TCL（6553，`159>>Pip>>0` 定长包握手）和海信（36669 端口能连上即认）——小米复刻不需要。
- 发现结果进入设备列表；已保存设备去重后合并。

### 4.2 手动添加（`qh1.addManually(name, brand, host, port)`，设备页调用）

字段：名称、品牌（下拉选小米）、IP/主机名、端口（留空则取品牌默认端口 6095）。手动添加后同样先走 `isalive` 校验（`u00.b()` 连接检查）再进遥控页。

## 5. 页面与功能清单（小米分支实际有的）

UI 为 Jetpack Compose，入口 `fh1.e(hh1, kr1, qh1)` → 主屏 `lp0 case 2` → 遥控页 `fh1.g(...)`。

| 页面/区域 | 内容（小米） | 来源 |
|---|---|---|
| 遥控页（`遥控页`） | 设备头（品牌图标 + 设备名；小米名字会去掉 `的` 之后的部分，如 `小米电视的…` → 截断，`zg1 case 0`）+ `切换设备` 按钮 | `fh1.g`、`zg1` |
| 方向键区 | 上/下/左/右 + OK（`qa.smali` 方向键、`de.smali` OK） | 发 `up/down/left/right/enter` |
| 功能按钮行 | 播放或暂停、主页、返回、菜单、电源、静音、音量 ±（`t21.smali`） | 见 §3.2/§3.4；其中 `播放或暂停` 发的也是 `enter` |
| 设备选择页 | 已发现/已保存设备列表、手动添加入口；空态 `还没有设备`；提示 `轻点选择要遥控的设备` | `fh1` |
| 状态/错误 | `连接失败` + `轻点重试`（调 `qh1.retry()`）、操作不支持时 Toast（`这台设备没有控制中心` / `这台设备不支持这个操作` / `电视未响应` / `音量没有调到 0` 等） | `qh1`、`u00.a` |
| 系统音量键 | `MainActivity.dispatchKeyEvent` 拦截 `KEYCODE_VOLUME_UP/DOWN`（24/25），仅 `ACTION_DOWN` 时发 `VOLUME_UP/DOWN` + 触感反馈；无选中设备时走系统默认 | `MainActivity.java` |

### 明确没有的功能（小米分支）

- **触控板**：静态未找到任何手势实现。应用代码中无 `detectDragGestures` / `detectTapGestures` / `pointerInput` / `onTouch` 的应用层调用链，也不存在 `_touchMove` / `_touchEnd` 这类协议调用（Apple 分支也只有连接握手时的 `_touchStart`，无滑动上报）。**遥控页实际就是方向键 + OK + 功能按钮**。官网文案的“滑动触控板”在 v1.0 小米分支中没有对应的实现与协议，iOS 版按 D-pad 实现，不自造触控板协议。
- **正在播放**：无。`NowPlaying` 模型 `r21`、事件 `_iMC` / `NowPlayingInfo`、刷新 `FetchCurrentNowPlayingInfoEvent` 全是 Apple Companion 专属；`u00` 中小米驱动的 nowPlaying/apps/keyboard 三个 StateFlow 恒为 null（`h62.d(null)`）；`qh1.g()` 只有拿到 `r21 != null` 才启动 `NowPlayingService`，小米永远不会触发。因此**无通知栏/锁屏控制、无后台播放服务**。
- **应用列表**：无。`FetchLaunchableApplicationsEvent` / `_launchApp` 是 Apple 专属；`fh1` 中的 `应用页` 标签只在 Apple 分支有内容。
- **自动键盘**：无。`_tiC` / `_tiStart` 文本输入是 Apple 专属；小米无键盘 UI、无文本下发。
- **配对/PIN**：无。小米无 `credentials`，`b00.b()`（需配对）只对 Apple TV 为真。
- **封面/歌手名/商店查询**：无。`ud.java` 的 iTunes lookup（`artworkUrl512`）只服务 Apple 的应用图标。
- **长按 Home 开控制中心**：无。这是 Apple 专属（HID 7 长按 1000 ms）；小米 `CONTROL_CENTER` 直接抛错。

## 6. 本地存储（复刻时照搬结构）

`SharedPreferences` 文件名 `devices`（`MODE_PRIVATE`，`z.java:669`）：

- `devices`：JSON 数组，每项 `{id, name, brand, host, port, credentials, extra}`（小米后两项为 null）。
- `selected`：当前选中设备 id。
- `recent_apps_<deviceId>`：最近使用的应用（Apple 专属，小米无此 key）。

iOS 侧用 UserDefaults（或 SwiftData）存同款 JSON 即可；字段名保持一致便于对照。

## 7. iOS 复刻映射

| Android（小米） | iOS 实现 | 备注 |
|---|---|---|
| `ke2` HTTP GET（§3） | `URLSession` GET | 需 `NSAppTransportSecurity → NSAllowsLocalNetworking = true`（局域网明文 HTTP）；或 `NSAllowsArbitraryLoads`。无鉴权、无自定义头、无 Cookie |
| /24 扫描（§4.1） | Swift Concurrency 任务组，48 并发，逐 IP `NWConnection` / BSD socket 350 ms 超时 + `isalive` GET | iOS 侧取本机 Wi-Fi IP（`getifaddrs`，`en0`）推导 /24；首次访问局域网会弹系统权限框，需 `NSLocalNetworkUsageDescription`。不走 Bonjour 就不必声明 `NSBonjourServices` |
| 手动添加 | 同款表单（名称/品牌固定小米/IP/端口默认 6095） | 保存后先 `isalive` 校验再进遥控页 |
| 设备持久化 | UserDefaults 存 `devices` JSON + `selected` | 字段名与 §6 一致 |
| 遥控页 D-pad + OK + 功能按钮 | SwiftUI 同款布局 | 按钮全部直调 §3.2 的 keycode；`播放或暂停` 发 `enter`（与 OK 相同，照搬，不要“修正”成别的键） |
| 静音 | 照 §3.4 的循环逻辑实现（缓存原音量、每次核对、101 次上限、相同报错文案） | 注意：静音态再次点按 = 恢复；恢复失败要报 `音量没有调到 <值>` |
| 不支持的操作 | 点按 `控制中心` / `上一首` / `下一首` / `快进快退` 时弹同款 Toast（`这台设备没有控制中心` / `这台设备不支持这个操作`） | 按钮可保留（与 Android 一致）或隐藏；保留并弹提示更贴近原版 |
| 系统音量键调电视音量 | **iOS 受限，无等价实现** | iOS 不提供拦截硬件音量键的 API（只能 `MPVolumeView` 改系统音量，与电视无关）。改为屏上音量 ± 按钮；不要声称支持硬件音量键 |
| 后台/锁屏/通知控制 | **不需要** | 小米分支无正在播放、无后台服务；应用前台使用即可，不用 `UIBackgroundModes`、不用 `MPNowPlayingInfoCenter` |
| 键盘/应用列表/配对 | **不做** | 见 §5、§8 |

### iOS 侧不需要的东西

- 不需要 Bonjour 浏览、不需要 `Network` 框架的 mDNS、不需要 TLS/证书、不需要 BouncyCastle 同类库、不需要 Protobuf、不需要 SRP/Ed25519/X25519/ChaCha20-Poly1305/HKDF（全是 Apple 分支的）。
- 不需要 Apple TV 相关 entitlement，不需要 `com.apple.developer` 系列配置。

## 8. Apple TV 专属功能（明确不做）

以下只在 `xd` / `rp` / `b7` / `ie2` / `w3` / `ud` / `NowPlayingService` 中出现，**iOS 小米版一律不实现、不预留**：

- 发现：Bonjour `_companion-link._tcp`（`NsdManager`，TXT `rpMd` 以 `AppleTV` 开头），默认端口 49152。
- 配对：HomeKit 风格 SRP 配对（PIN 码，`ie2.b/c`：TLV 载荷、`SRP6Client`、HKDF-SHA512 派生 `Pair-Setup-*-Salt/Info`、Ed25519 控制器密钥对、`PS-Msg05/06` ChaCha20-Poly1305 加密）；配对凭证 `qp`（deviceLtpk / clientLtsk / deviceId / clientId，冒号分隔 hex 存 `credentials`）。
- 会话：`b7.C` Pair-Verify（X25519 + `PV-Msg02/03`）；Companion 帧（1 字节类型 + 3 字节大端长度，bplist 载荷，ChaCha20-Poly1305 加密，12 字节小端计数器 nonce，AAD=帧头）；`_systemInfo`（冒充 `iPhone14,3`、`_sv 170.18`、name `Pip`）、`_sessionStart`（`com.apple.tvremoteservices`）、`TVRCSessionStart`（ProtocolVersionKey 1.2）、`_touchStart`、`_tiStart`、`_interest`（`_iMC`）。
- 控制：HID 事件 `_hidC`（上下左右 1–4、菜单/返回 5、确认 6、Home 7、音量 8/9、睡眠/唤醒 12/13、播放暂停 14）、媒体命令 `_mcc`（3 下一首、4 上一首、7 ±10 秒 `_skpS`）、电源（`FetchAttentionState` 判睡/醒）、控制中心（HID 7 长按 1000 ms）。
- 正在播放：`FetchCurrentNowPlayingInfoEvent`、`NowPlayingInfo` bplist 解析（`vd.z`：title/episodeTitle/seasonNumber/episodeNumber/playerIdentifier/iTunesStoreIdentifier/duration/timeOffset/timestamp/imageData）、`_iMC` 的 `_mcF` 位（canPrevious bit 8、canNext bit 4、canSkipForward bit 512、canSkipBackward bit 1024）。
- 应用列表：`FetchLaunchableApplicationsEvent`（`{bundleID: 显示名}`，NBSP 转空格）+ `_launchApp`；图标经 iTunes Lookup（`ud.java`，cn/us 店面，先 `artworkUrl512` 后改 `160x160bb`）。
- 键盘：`_tiC` 文本差分下发（`cv.j/t`，按字形簇删/插）。
- 静音（Apple 路径）：不用 `ke2`，而走 AirPlay 2（`w3.java`）：7000 端口 Pair-Verify → RTSP `SETUP`/`RECORD`（`AirPlay/550.10`）→ 加密数据流上发手写 MRP protobuf（含 HID 静音 press/release）。
- 锁屏/通知/控制中心：`NowPlayingService`（`MediaSession "Pip"` + `now_playing` 通知渠道 + 媒体样式通知 + `SCREEN_ON/USER_PRESENT` 监听）。

## 9. 未确认项（静态分析的边界）

1. /24 扫描的本机 IP 前缀来源未完全确认（dex 中无 Wifi/NetworkInterface 相关调用；`p0.r`、`ge.r` 反编译失败）。iOS 复刻直接用本机 Wi-Fi IP 推导，不影响行为。
2. 遥控页中 `控制中心` 标签页（`fh1` 字符串）在小米分支下的具体呈现未完全确认；已知 `CONTROL_CENTER` 按键必抛错，页面级差异不影响协议。
3. 小米电视端 HTTP 服务的具体行为（`devicename` 字段格式、`volume` 取值范围、关机后端口是否存活）只能由真机验证，静态无法确认；建议 iOS 版先以一台小米电视实测 `isalive` / `getvolume` / 各 keycode 的回包。
4. `qh1.h()` 为非 Apple 分支启动的 `p0(13)` / `ge(2)` 后台任务反编译失败；从 `ge.smali` 残片看与 `VolumeProvider` 同步有关，在小米分支上无可见行为（无 MediaSession），复刻时可忽略。
5. 本报告只做静态分析，未连接任何真实电视，未抓包；所有协议细节均来自反编译代码，未做动态验证。

## 附录：关键类名对照（R8 混淆后）

| 含义 | 类/文件 |
|---|---|
| 品牌枚举 | `zj`（APPLE_TV/XIAOMI/TCL/HISENSE/XBOX） |
| 远程按键枚举 | `ng1`（UP/DOWN/LEFT/RIGHT/OK/BACK/HOME/MENU/PLAY_PAUSE/VOLUME_UP/VOLUME_DOWN/MUTE/POWER/CONTROL_CENTER/NEXT/PREVIOUS/SKIP_FORWARD/SKIP_BACKWARD） |
| 驱动接口 | `mg1`（`b/c/close/a`） |
| **小米驱动** | **`ke2`** |
| 设备模型 | `b00` |
| 会话/重连 | `u00` |
| ViewModel | `qh1`（`press` / `launchApp` / `addManually` / `onDiscovered` / `retry`） |
| 局域网扫描 | `yt.Q(ip)`、`r01`（1–254，48 并发）、`yt.E(port, ip)`（TCP 连通性） |
| 存储 | `z`（SharedPreferences `devices`） |
| 主 Activity | `app.pipremote.MainActivity`（音量键拦截） |
| 前台服务 | `app.pipremote.NowPlayingService`（仅 Apple） |
| UI | `fh1`（页面）、`lp0`（主屏组装）、`zg1`（设备头/事件分发） |
