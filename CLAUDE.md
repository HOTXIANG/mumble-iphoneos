# Mumble iOS/macOS - 项目开发规范

## 项目概述

Mumble 是一个跨平台 VoIP 应用，支持 iOS（iPhone + iPad）和 macOS。采用三层混合架构：SwiftUI（UI 层）→ Objective-C/ARC（应用逻辑层）→ MumbleKit/MRC（音频/网络底层）。

当前事实来源：`docs/CURRENT_STATUS.md`。开始处理音频、连接性能、弱网/Opus、欢迎引导、macOS 窗口或自动化测试问题前，先读该文档确认最新预期。

### 技术栈

- **部署目标**: iOS 17.0+ / macOS 14.0+
- **语言**: Swift 5.9+（UI 及新功能）、Objective-C（应用逻辑）、Objective-C MRC（MumbleKit）
- **UI 框架**: SwiftUI，需要 iOS 26 / macOS 26 的 Liquid Glass 特性时用 `#available` 降级
- **数据库**: SQLite（通过 FMDB，串行队列 `dbQueue` 保证线程安全）
- **音频**: MumbleKit 自研框架（Opus 编解码、Speex DSP、Voice Processing / HAL Output）
- **依赖管理**: Xcode 子项目引用（无 SPM/CocoaPods），MumbleKit 和 FMDB 为 git 子模块
- **构建目标**: `Mumble`（主应用）、`MumbleWidgetExtension`（Widget）

---

## 目录结构

```
Source/Classes/
├── MU*.h/.m                    # Objective-C 应用逻辑层（ARC）
├── SwiftUI/
│   ├── MumbleApp.swift         # @main 入口
│   ├── AppState.swift          # 全局状态单例 + 通知定义 + ObjC 桥接类
│   ├── PlatformTypes.swift     # 跨平台 typealias 和 ViewModifier
│   ├── WelcomeView.swift       # 根布局（MumbleContentView：iPad/iPhone/macOS 分流）
│   ├── Channel/                # 频道、消息、ACL 相关视图
│   ├── Components/             # PTTButton、ToastView 等共用组件
│   ├── Core/                   # AsyncWrappers/、Constants/、Errors/、Logger
│   ├── Models/                 # LanDiscovery、RecentServer、ServerPing 等数据模型
│   ├── Preferences/            # 设置界面（共用 + 平台分文件）
│   └── ServerModelManager/     # 服务器状态管理（按职责拆分为多个 +Extension 文件）
MumbleKit/
├── src/                        # MRC，音频引擎、网络连接、协议、加密
└── 3rdparty/                   # Opus、Speex、OpenSSL、ProtocolBuffers
```

---

## 代码风格

### 命名

| 类型 | 规则 | 示例 |
|------|------|------|
| 类/结构体/枚举 | PascalCase | `ServerModelManager`、`CertTrustInfo` |
| 变量/函数 | camelCase | `isConnected`、`calculateEffectiveChatWidth()` |
| ObjC 类 | `MU` 前缀（应用层）/ `MK` 前缀（MumbleKit） | `MUDatabase`、`MKConnection` |
| 通知名 | 以 `Notification` 结尾 | `MUConnectionOpenedNotification` |
| Swift 通知扩展 | `mu` / `mk` 前缀 | `.muConnectionOpened`、`.mkAudioDidRestart` |

### Swift 属性声明顺序

```swift
struct/class Example {
    // 1. @Published
    // 2. @AppStorage / @Environment / @State / @StateObject / @ObservedObject
    // 3. 普通存储属性（先 private，后 internal/public）
    // 4. 计算属性
    // 5. 立即执行闭包的平台常量
    // 6. init
    // 7. body（View）或方法
}
```

### 注释

- 使用 `// MARK: -` 对视图和方法分区
- 中文注释说明设计意图，英文代码标识符
- 不写复述代码逻辑的注释，只解释非显而易见的设计决策

### 文件组织

- 大型类按职责拆分为多个 `+Extension` 文件（如 `ServerModelManager+Messaging.swift`）
- 平台特定逻辑较多时使用独立文件：`PreferencesView+iOS.swift`、`PreferencesView+macOS.swift`
- 简单的平台分支直接在原文件内用 `#if os()` 处理

---

## 架构与数据流

### 音频信号流（DAW 风格）

详细架构请参考 `MIXER_ARCHITECTURE.md`

**输入链路**：
```
Microphone → ADC → MKAudioDevice → MKAudioInput
→ Speex Preprocessor (VAD/降噪/去混响)
→ Gain Adjustment
→ [Input Track 插件链] (short*, 编码前)
→ Opus/Speex Encoder → Network
```

**输出链路**：
```
Network → Opus/Speex Decoder → MKAudioOutputUser (float*, per-user)
→ [Remote Track 插件链] (float*, per-user, 混音前)
→ Mix to Master Bus
→ [Master Bus 插件链] (float*, 混音后)
→ Float→Short Conversion → MKAudioDevice → DAC → Speaker
```

**插件插入点**：
1. **Input Track**: 本地麦克风处理（编码前）
2. **Remote Track**: 每用户独立处理（解码后，混音前）
3. **Master Bus**: 最终混音处理（输出前）

### 音频生命周期规则（2026-04-25）

普通欢迎页和从后台回到前台时，不得仅因为 App 激活就进入 iOS VoiceChat 模式或打开麦克风。允许主动开启麦克风的场景只有：

1. 首次启动的 "Welcome to Mumble" VAD 引导页正在显示
2. Input Setting 正在显示
3. Audio Plugin Mixer 正在显示
4. 服务器连接已建立或连接流程需要通话音频

实现规则：

- `MKAudio.sharedAudio` 不在单例创建时配置 `AVAudioSession`。
- `MKAudio.stop()` 在 iOS 上必须回到 `Ambient` / `Default` 并 deactivate session。
- `MUApplicationDelegate` 只根据真实活动连接决定前后台恢复音频，不根据过期 `_connectionActive` 状态恢复。
- `ServerModelManager.startAudioTest()` 同时检查 `isLocalAudioTestRunning` 和真实 `MKAudio.isRunning()`。
- 本地音频测试启动中用 `isLocalAudioTestStarting` 合并 UI 重试，避免多次 teardown/start。
- 从 Input Setting 打开 VAD 引导页时，调用 `preserveLocalAudioTestForVADOnboardingTransition()`，让设置页 dismiss 期间不关麦；VAD 引导页 `onAppear` 后调用 `finishLocalAudioTestPreservationForVADOnboarding()`。
- AudioUnit 启动顺序必须是：`setupDevice()` 初始化 → `MKAudioInput/MKAudioOutput` 绑定回调 → `startDevice()` 启动 AudioUnit。不要把 `AudioOutputUnitStart` 放回 setup 阶段。

### Opus / 网络策略（2026-04-25）

弱网模式已经删除。不要再新增 `WeakNetwork*` UserDefaults、设置页开关或 WebSocket 命令。网络体验依赖 Opus 默认能力和现有 Mumble 传输/抖动缓冲。

Opus encoder 默认必须保持：

```objc
opus_encoder_ctl(enc, OPUS_SET_VBR(1));
opus_encoder_ctl(enc, OPUS_SET_VBR_CONSTRAINT(1));
opus_encoder_ctl(enc, OPUS_SET_DTX(1));
opus_encoder_ctl(enc, OPUS_SET_INBAND_FEC(1));
opus_encoder_ctl(enc, OPUS_SET_PACKET_LOSS_PERC(10));
```

`AudioOpusCodecForceCELTMode` 默认值是 `false`。不要默认强制 CELT-only，否则会削弱 Opus VOIP 特性。

### 关键状态管理规则

- `AppState` 是 `@MainActor` 单例，存放全局 UI 状态
- `ServerModelManager` 是 `@MainActor ObservableObject`，管理服务器模型和消息
- 从 ObjC 或后台线程更新 UI 状态时必须使用 `DispatchQueue.main.async` 或 `Task { @MainActor in }`
- `@Published` 属性的变更不可在 SwiftUI view update 周期内同步执行，需要 `DispatchQueue.main.async` 延迟

---

## 平台分支规则

### 条件编译

```swift
// 框架导入用 canImport
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// 行为分支用 os()
#if os(iOS)
.toolbarBackground(.hidden, for: .navigationBar)
#else
.toolbarBackground(.hidden, for: .windowToolbar)
#endif

// ObjC 中用 TARGET_OS_IOS
#if TARGET_OS_IOS
// iOS 专用
#endif
```

### 平台抽象（PlatformTypes.swift）

- `PlatformImage` = `UIImage` / `NSImage`
- `PlatformColor` = `UIColor` / `NSColor`
- `Image(platformImage:)` 统一构造
- `Color.systemGray2` ~ `Color.systemGray5` 跨平台颜色

### 平台常量的立即执行闭包模式

```swift
private let splitThreshold: CGFloat = {
    #if os(macOS)
    return 550
    #else
    return 700
    #endif
}()
```

---

## Objective-C 互操作

### Swift → ObjC

通过 `Mumble-Bridging-Header.h` 暴露 ObjC 头文件，Swift 直接调用：

```swift
MUDatabase.storeFavourite(server)
MUConnectionController.shared()?.connect(toHostname: host, port: UInt(port))
MKAudio.shared()?.restart()
```

### ObjC → Swift

ObjC 通过 `#import "Mumble-Swift.h"` 调用 `@objc` 标记的 Swift 类/方法：

```objc
[CertTrustBridge handleTrustFailure:info];
[RecentServerManager.shared addRecent:hostname port:port displayName:name];
```

### 桥接模式

| 方向 | 机制 | 用途 |
|------|------|------|
| ObjC → Swift 状态更新 | `@objc` 静态方法 + `DispatchQueue.main.async` | 证书信任回调 → `AppState` |
| ObjC 事件 → Swift | `NotificationCenter` + `.onReceive` / Combine | 连接状态、音频状态 |
| Swift → ObjC 委托 | `@objc class Wrapper: NSObject, MKServerModelDelegate` | 模型变更回调 |
| ObjC 回调 → async | `withCheckedThrowingContinuation` 包装 | 连接、证书操作 |

### 内存管理

- **Source/Classes/** (应用层 ObjC): ARC，不要写 `retain`/`release`
- **MumbleKit/src/**: MRC，必须手动管理内存（`retain`/`release`/`autorelease`）
- **混编注意**: 从 MumbleKit 返回的对象在 Swift/ARC 端自动管理，无需额外操作

---

## UI 开发规范

### Liquid Glass / 材质效果

始终使用 `#available` 降级：

```swift
if #available(iOS 26.0, macOS 26.0, *) {
    content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
} else {
    content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
}
```

已封装的 ViewModifier（在 `PlatformTypes.swift` 中）：

| Modifier | 用途 |
|----------|------|
| `GlassEffectModifier` | 通用玻璃效果 |
| `TintedGlassRowModifier` | 列表行带色彩的玻璃高亮 |
| `RedGlassCapsuleModifier` | 红色胶囊按钮（闭麦等） |
| `ClearGlassModifier` | 透明玻璃 |

### 颜色与主题

- 背景色由系统窗口提供（黑/白），视图层覆盖半透明渐变 tint
- `globalGradient` 放在 ZStack 最上层，`.allowsHitTesting(false)`，确保始终覆盖包括 TabView 系统背景
- 亮暗模式通过 `@Environment(\.colorScheme)` 读取，按需调整透明度和阴影
- 阴影：亮色模式加阴影，暗色模式减弱或去掉

### 响应式布局（ChannelView）

```
宽度 > splitThreshold (macOS: 550, iOS: 700)
  → 双栏: HStack { ServerChannelView | ResizeHandle | MessagesView }
宽度 ≤ splitThreshold
  → 单栏: TabView { Channels | Messages }
```

- 双栏模式下 `ResizeHandle` 可拖拽调整宽度
- 默认五五开（`userPreferredChatWidth = -1` 哨兵值触发自动计算）
- iPad 使用 `NavigationSplitView`（欢迎界面侧边栏 + 频道详情），连接后根据宽度控制侧边栏可见性

### 窗口尺寸（macOS）

- 最小窗口: 480×400
- 默认窗口: 1100×760
- 侧边栏自动隐藏阈值: 900pt

---

## 线程安全规则

1. **UI 更新必须在主线程**: 使用 `@MainActor`、`DispatchQueue.main.async`、或 `Task { @MainActor in }`
2. **`@Published` 变更时机**: 不可在 SwiftUI view body 计算期间同步变更，需 `DispatchQueue.main.async` 延迟
3. **ObjC 通知回调**: 可能在非主线程，切回主线程后再更新 `AppState` 或 `@Published` 属性
4. **数据库操作**: `MUDatabase` 内部使用串行 `dispatch_queue_t`，外部调用无需额外同步
5. **音频线程**: MumbleKit 的 IO 回调在实时音频线程，禁止 ObjC 消息发送或内存分配（已有 buffer 预分配机制）

---

## Notification 规范

### 定义（AppState.swift）

```swift
extension Notification.Name {
    static let muConnectionOpened = Notification.Name("MUConnectionOpenedNotification")
    static let muConnectionClosed = Notification.Name("MUConnectionClosedNotification")
    static let muConnectionError  = Notification.Name("MUConnectionErrorNotification")
    static let muCertificateTrustFailure = Notification.Name("MUCertificateTrustFailureNotification")
    // ...
}
```

### 接收

```swift
// SwiftUI 内
.onReceive(NotificationCenter.default.publisher(for: .muConnectionOpened)) { _ in ... }

// ObservableObject 内
NotificationCenter.default.addObserver(forName: .muConnectionOpened, object: nil, queue: .main) { ... }
// 通过 ObserverTokenHolder 统一管理 token 生命周期
```

---

## 日志规范

项目使用统一日志系统（`LogManager` 单例 + `MumbleLogger` 入口），全面覆盖 Swift / ObjC / MumbleKit 三层。详细架构参见 `docs/LOGGING.md`。

### 禁止事项

- **禁止 `print()`**：所有正式日志必须通过 `MumbleLogger` 输出
- **禁止裸 `NSLog()`**：ObjC 应用层使用 `MULog*` 宏，MumbleKit 使用 `MKLog*` 宏
- **禁止无分类日志**：每条日志必须属于明确的分类

### 日志等级（从高到低）

| 等级 | 用途 | 示例 |
|------|------|------|
| `error` | 操作失败、需要关注 | 连接断开、证书创建失败 |
| `warning` | 异常但可恢复 | 证书信任失败、格式回退 |
| `info` | 正常操作节点 | 连接成功、服务器发现 |
| `debug` | 开发调试细节 | 状态变更、性能计量 |
| `verbose` | 极详细追踪 | 每帧数据、包收发 |

### Swift 用法

```swift
MumbleLogger.connection.info("已连接到 \(hostname):\(port)")
MumbleLogger.audio.error("音频初始化失败：\(error)")
MumbleLogger.plugin.debug("AU 加载完成：\(pluginName)")
MumbleLogger.discovery.warning("服务解析超时：\(serviceName)")
```

### ObjC 应用层用法（MU* 文件）

```objc
MULogInfo(Connection, @"连接成功: %@:%d", hostname, port);
MULogError(Database, @"数据库迁移失败: %@", error);
MULogDebug(Certificate, @"证书链长度: %d", chainLength);
```

### MumbleKit 用法（MK* 文件）

```objc
MKLogInfo(Audio, @"音频引擎启动: sampleRate=%f", rate);
MKLogError(Network, @"包解析失败: type=%d size=%lu", type, size);
MKLogVerbose(Codec, @"Opus 编码帧: %d bytes", encodedLength);
```

### 13 个日志分类

| 分类 | 覆盖范围 |
|------|---------|
| `Connection` | 服务器连接/断开/重连 |
| `Audio` | 音频引擎、设备、TTS |
| `UI` | 视图状态、渲染性能 |
| `Model` | ServerModelManager 状态 |
| `Handoff` | Handoff/LiveActivity |
| `General` | 应用生命周期、通用 |
| `Notification` | 推送/本地通知 |
| `Database` | SQLite/FMDB 操作 |
| `Certificate` | 证书创建/导入/验证 |
| `Plugin` | AU/VST3 插件加载/渲染 |
| `Network` | 协议层包收发、加密 |
| `Codec` | Opus/Speex 编解码 |
| `Discovery` | LAN 服务发现 |

### 运行时控制

- **设置界面**：iOS `Settings → Developer → Logging` / macOS `Logging` 标签页，可按分类开关日志等级
- **环境变量**（Xcode Scheme → Arguments → Environment Variables）：
  - `MUMBLE_LOG_LEVEL=verbose|debug|info|warning|error`（全局等级覆盖）
  - `MUMBLE_LOG_DISABLED=audio,plugin`（禁用指定分类）
  - `MUMBLE_LOG_VERBOSE=connection,network`（指定分类设为 verbose）
  - `MUMBLE_LOG_FILE=1`（启用文件持久化）
- **默认等级**：Debug 构建 `debug`，Release 构建 `info`

### 文件持久化（可选）

- 设置界面或 `MUMBLE_LOG_FILE=1` 开启
- 日志写入 `Documents/Logs/`（iOS）或 `Application Support/Mumble/Logs/`（macOS）
- 按天滚动，保留最近 7 天
- 设置界面可导出日志文件

### 新增模块日志要求

新增功能模块时必须添加对应日志：
1. 确定所属分类（参考上表），不合适时使用 `General`
2. 关键操作（创建/删除/连接/断开）至少 `info` 级
3. 错误路径必须 `error` 或 `warning` 级，包含错误详情
4. 性能敏感路径用 `debug`，包含耗时信息

---

## 自动化测试（WebSocket 测试服务器）

项目内嵌了 WebSocket 测试服务器（`MUTestServer`），仅 `#if DEBUG` 编译。AI agent 或脚本可通过 WebSocket 远程控制 App 执行全部功能。详细架构和完整命令参考见 `docs/TESTING.md`。

### 架构

```
AI Agent (websocat/Python) → ws://localhost:54296 → MUTestServer → MUTestCommandRouter → App 模块
```

- **零依赖**：基于 Apple `Network.framework` NWListener + NWProtocolWebSocket
- **仅 DEBUG**：Release 构建中完全不存在
- **JSON 协议**：`{"action": "domain.command", "params": {...}}` → `{"success": true, "data": {...}}`

### 快速使用

```bash
# 安装 CLI 工具
brew install websocat

# App 以 Debug 模式运行后连接
websocat ws://localhost:54296

# 发送命令
{"action": "help.actions"}
{"action": "state.get"}
{"action": "favourite.list"}
{"action": "log.getConfig"}
```

### Agent 调试 SOP

新 agent 接手时，默认按这个顺序做：

1. 确认 App 是 `DEBUG` 构建，并且控制台出现 `TestServer: listening on ws://localhost:54296`
2. 建立**长连接**，不要一开始就用 `websocat -n1`
3. 先发：
   - `log.marker`
   - `log.stream`
   - `state.get`
   - `ui.get`
4. 用 `ui.*` 负责导航，用对应语义域负责真正动作
5. 每次修复后重跑同一组命令，比较 `log.entry`、`ui.changed`、`state.get`

详细调试模板、Python 长连接脚本、崩溃取证流程见 `docs/TESTING.md` 顶部新增的“Agent 上手速览 / 推荐调试流程 / 崩溃排查 SOP”。

### 14 个命令域（80+ 命令）

| 域 | 关键命令 | 说明 |
|------|----------|------|
| `connection` | `connect`, `disconnect`, `acceptCert`, `rejectCert`, `status` | 服务器连接管理 |
| `audio` | `mute`, `toggleMute`, `startTest`, `forceTransmit`, `status` | 音频控制与本地测试 |
| `channel` | `list`, `info`, `edit`, `move`, `listen`, `togglePinned` | 频道操作与可见性控制 |
| `message` | `send`, `sendTree`, `sendPrivate`, `sendImage`, `sendPrivateImage`, `listImages`, `exportImage`, `previewImage`, `history`, `markRead` | 文本、图片与图片预览调试 |
| `plugin` | `listTracks`, `available`, `add`, `remove`, `move`, `setBypass`, `setGain`, `load`, `unload`, `parameters`, `setParameter`, `presets` | 插件混音器语义控制 |
| `user` | `list`, `self`, `info`, `kick`, `ban`, `setVolume`, `serverMute`, `stats` | 用户操作 |
| `favourite` | `list`, `info`, `add`, `update`, `remove`, `connect` | 收藏管理 |
| `settings` | `get`, `set`, `list` | UserDefaults 读写 |
| `state` | `get`, `snapshot` | 完整应用状态快照 |
| `app` | `get`, `setTab`, `setViewMode`, `clearError`, `cancelConnection` | UI / 弹窗 / 交互状态控制 |
| `ui` | `get`, `open`, `dismiss`, `back`, `root` | 页面级自动化与导航控制，已覆盖设置子页、关于页、频道编辑页内 tab/弹层、ACL 编辑、Ban Add、插件混音器、证书弹层等 UI 目标 |
| `server` | `getBanList`, `setBanList`, `addBan`, `removeBan`, `getRegisteredUsers` | 管理页数据操作 |
| `certificate` | `list`, `generate`, `delete`, `import`, `export` | 本地身份页自动化 |
| `log` | `setLevel`, `recent`, `stream`, `marker`, `files`, `reset` | 日志系统远程控制与监控 |
| `help` | `actions` | 列出所有命令 |

### 事件推送

连接后自动接收：`connection.opened/closed/connecting/error`、`connection.udpStatus`、`audio.restarted/error`、`app.toast`、`message.sendFailed`、`channel.listeningAdded/Removed`、`log.entry`、`ui.changed`

### 文件结构

| 文件 | 位置 | 职责 |
|------|------|------|
| `MUTestServer.swift` | `Source/Classes/SwiftUI/Core/` | NWListener WebSocket 服务器、连接管理、事件推送 |
| `MUTestCommandRouter.swift` | `Source/Classes/SwiftUI/Core/` | JSON 命令路由、所有域处理器 |

### 已知注意事项

- **`MKAudio.shared()` 不可在未连接时调用**：会阻塞主线程。`audio.*` 命令在未连接时返回安全默认值
- **例外**：`audio.startTest` / `audio.status` 可用于 Input Setting、Mixer、VAD 引导页等本地音频测试场景；普通状态读取仍应避免不必要地初始化音频单例
- **iOS 真机**：需 USB 端口转发或同网络访问设备 IP
- **iOS 模拟器**：直接通过 `localhost:54296` 访问

### 新增测试命令规范

添加新命令时遵循：
1. 在 `MUTestCommandRouter.swift` 对应域的 switch 中添加 case
2. 更新 `handleHelp` 中的命令列表
3. 更新 `docs/TESTING.md` 文档
4. 所有必需参数缺失时抛出 `TestCommandError("Missing 'paramName'")`
5. 需要连接的操作先 `guard let model = MUConnectionController.shared()?.serverModel`
6. 避免在未连接状态下触发可能阻塞主线程的单例初始化（如 `MKAudio.shared()`）

---

## 错误处理

- 统一使用 `MumbleError` 枚举（`Core/Errors/`）
- 通过 `LocalizedError` 协议提供本地化描述
- UI 展示使用 `AppState.activeError` 或 `AppState.activeToast`

---

## 编译与构建

```bash
# 仅支持通过 Xcode target 构建，无独立 scheme
# iOS（需真机或模拟器 destination）
xcodebuild -target Mumble -destination 'generic/platform=iOS' build

# macOS
xcodebuild -target Mumble -destination 'platform=macOS' build
```

注意: OpenSSL.dylib 可能需要先单独构建 MumbleKit 的 OpenSSL target。

---

## Git 提交规范

```
feat: 新功能
fix: 修复 bug
refactor: 重构
style: 代码格式
docs: 文档
chore: 构建/工具变动
```

---

## 关键注意事项

1. **永远先读再改**: 修改任何文件前必须先读取当前内容
2. **MumbleKit 是 MRC**: 修改 `MumbleKit/src/` 下的代码时必须手动管理内存
3. **平台兼容**: 所有新 UI 代码必须同时考虑 iOS 和 macOS，使用 `#if os()` 隔离差异
4. **Liquid Glass 降级**: 使用 `glassEffect` 时必须提供 `#available` 降级路径
5. **不要引入新依赖**: 除非明确要求，不要添加新的第三方库
6. **TabView 背景**: iOS TabView 有系统默认不透明背景，需要 `configureTabBarAppearance()` 清除并将渐变叠加在内容之上
7. **iPad 侧边栏**: 连接服务器后窄窗口应隐藏侧边栏，宽窗口允许用户手动打开
8. **循环引用**: 闭包中使用 `[weak self]`，Notification observer 通过 token holder 管理生命周期
9. **跨层数据规范化**: ObjC/MumbleKit 回调给 SwiftUI 前，优先转换为 `NSArray/NSDictionary/NSNumber/String/Data` 等 Foundation 安全类型，避免 Swift 侧反射解析 protobuf 内部对象
10. **禁止不安全 Selector 反射**: Swift 中禁止用 `perform(_:)`/`toOpaque()` 读取标量返回值（如 `count`）或调用标量参数方法（如 `objectAtIndex:`），这会导致未定义行为和越界崩溃
11. **protobuf 集合解析位置**: `PBArray/PBAppendableArray` 的遍历与字段提取优先放在 ObjC 层（类型已知处）完成，Swift 侧只做展示与轻量映射
12. **工具栏保存按钮规范**: Access Tokens、Ban List 等管理页的保存操作使用图标按钮（推荐 `square.and.arrow.down`），与新增按钮风格保持一致
13. **AU 链并发安全**: 音频回调线程与 UI/状态线程共享 AU 链时，必须使用锁+快照（如 `os_unfair_lock` + retain 快照）避免 `AUHostingService` invalidated
14. **实时线程约束**: 回调路径禁止不受控对象生命周期变更；链更新在控制线程完成，回调只读取快照并执行 DSP
15. **AU 输入拉取规范**: `AURenderPullInputBlock` 需同时兼容 non-interleaved / interleaved 缓冲，`mData == NULL` 时必须提供有效输入指针
16. **参数状态展示规范**: 插件刚加载未扫描参数时显示“params pending”，不要误标成“0 参数”
17. **AU 故障可观测性**: AU render 非 `noErr` 必须记录 status，便于定位“已加载但无效果”场景

---

## 功能补齐状态与工作流程

### 当前状态（相对原版 Mumble 桌面客户端）

**MumbleKit 后端**：已补齐协议层 API（kick/ban、封禁列表、频道链接、UserList、UserStats、ServerConfig、SuggestConfig、VoiceTarget、ContextAction、requestTexture 等），`userWithHash:` 已修复。

**应用层已实现**：

| 功能 | 说明 |
|------|------|
| Kick/Ban | 用户上下文菜单，按 `MKPermissionKick`/`MKPermissionBan` 显示 |
| 封禁列表 | `BanListView`，ChannelListView 菜单入口（需 Ban 权限） |
| 频道链接 | 频道菜单 Link/Unlink/Unlink All，`hasLinkPermission` |
| 注册用户列表 | `RegisteredUserListView`，菜单入口（需 Register 权限） |
| 用户统计 | `UserStatsView`，用户菜单「User Statistics」，6 秒刷新 |
| 优先说话者 | 用户菜单切换，Self 在 ChannelListView 三点菜单 |
| 监听频道 | 频道菜单 Listen/Stop Listening（已取消注释） |
| 发送到频道树 | `sendTextMessageToTree`，MessagesView 可扩展 tree 开关 |
| 复制频道 URL | 频道菜单「Copy URL」，生成 `mumble://host:port/path` |
| 用户头像 | UserInfoView 内 Change/Remove Avatar（PhotosPicker） |
| Access Tokens | `AccessTokensView`，菜单入口，数据库持久化 |
| 录音状态 | UserRowView 显示 `record.circle`，UserState.isRecording |
| 服务器密码 | `connectTo(..., password: String?)` 可选密码参数 |
| 搜索 | ChannelListView `.searchable`，`channelSearchText` |
| Reset Comment | 用户菜单管理员「Reset Comment」 |
| ServerConfig | Delegate 桥接 + 通知，可扩展消息长度校验等 |
| DAW Mixer 独立入口 | Advanced Audio 可打开独立 Mixer 页（macOS 独立窗口 / iOS 独立页面） |
| 轨道化插件链 | Input / Remote Bus / Remote Session 固定插槽，支持添加、替换、移除、旁路、顺序调整 |
| 插件浏览与分类 | 先类别后插件（Dynamics/EQ/Reverb/Utility），支持 AU 扫描与 macOS 文件系统扫描 |
| 插件 UI 热切换 | 已加载 AU 可打开自定义界面，支持锁定槽位与切换时同步 UI |
| 插件链持久化 | 按轨道保存链路、旁路、增益、自动加载与参数值 |
| 插件预设管理 | 保存/加载插件参数配置，按插件标识符分组存储 |
| AU 稳定性修复 | 自动加载串行化、重入保护、列表去重、参数懒加载、链更新并发保护 |
| AU 格式兼容性 | 智能格式检测（interleaved/non-interleaved），声道数自适应（2→1 回退） |
| AU 数据流修复 | 正确的 AudioBufferList 创建、独立声道缓冲区、输入解交织、输出重新交织 |
| AU 配置优化 | 格式配置移到加载时（一次性），运行时只调用 render block，CPU 降低 66% |
| AU DSP 完整接入 | Input / Remote Bus / Remote Session 三轨道全部接入真实 AU render 路径 |
| DSP 可观测性 | 实时显示输入/输出电平、AU 渲染状态、帧计数，200ms 刷新 |

**明确不实现**：Public Server List（公网服务器列表）。

**待实现（按计划顺序）**：

1. **Local Nickname**：用户上下文菜单「Set Nickname」+ `LocalUserPreferences` 持久化 + 显示优先昵称
2. **Friends List**：按 userHash 存储好友，上下文菜单 Add/Remove Friend，频道树高亮
3. **Local Text Ignore**：用户菜单「Ignore Messages」+ 消息接收时按 hash 过滤
4. **Drag Channels**：macOS 频道行 `.onDrag`，drop 时处理 `channel:` 前缀移动频道
5. **TTS**：设置页 TTS 开关，消息/用户事件时 `AVSpeechSynthesizer`
6. **Channel Hide/Pin**：频道菜单 Hide/Pin，`rebuildModelArray` 过滤 + UserDefaults 持久化（按服务器 digest）
7. **Network Settings**：PreferencesView 增加 Network 区块（如自动重连、QoS）
8. **VST3 插件支持**：完善 VST3 bundle 解析、参数映射、状态保存（macOS）
9. **实时线程优化**：把 AU 路径中的临时分配迁移到预分配缓冲，进一步降低抖动与宿主失效风险

**暂缓**：完整桌面版 Audio Wizard、Global Shortcuts、Advanced Log Config、ContextAction、Voice Recording。当前仅实现首次启动 VAD onboarding，并复用本地音频测试链路。

### DAW / AU 插件专项说明（2026-03-23 最终更新）

1. **完整的 AU DSP 架构**：Input、Remote Bus、Remote Session 三轨道全部接入真实 AU 处理链
2. **AU 配置优化**（关键修复）：
    - **问题**：之前每个音频帧（10ms）都重新配置 AU，导致状态重置和音频阻断
    - **修复**：AU 格式配置移到加载时（一次性），运行时只调用 render block
    - **性能提升**：CPU 使用率降低 66%，消除音频阻断
3. **智能格式自适应**：
    - 优先尝试 interleaved 格式（最通用）
    - 失败时自动回退到 non-interleaved 格式
    - 正确处理单声道和立体声插件
    - 修复 -3000 错误（kAudioUnitErr_FormatNotSupported）
4. **数据流正确性**：
    - Interleaved: 1 buffer, N channels（直接复制）
    - Non-interleaved: N buffers, 1 channel each（解交织/重新交织）
    - 输入数据正确传递给 AU
    - 输出数据正确复制回工作缓冲区
5. **插件预设管理**：
    - 保存/加载插件参数配置
    - 按插件标识符分组存储
    - 支持预设重命名和删除
6. **DSP 可观测性**：
    - 实时显示输入/输出电平（200ms 刷新）
    - AU 渲染状态监控（noErr / 错误码）
    - 帧计数统计
    - 详细的调试日志（插件名称、格式、电平）
7. **Mixer 打开后崩溃修复**：已通过链状态加锁快照修复 `AUHostingServiceClient connection invalidated` 高频场景
8. **音频链路完整性**：
    - Input Track: Speex 预处理后 → AU 链 → 编码器前
    - Remote Track: 解码器后 → AU 链 → 混音前（per-user）
    - Master Bus: 混音后 → AU 链 → 输出前
9. **调试和诊断**：
    - 详细的日志输出（Console.app）
    - 电平监控（输入/输出 peak）
    - 格式信息（interleaved/non-interleaved, channels）
    - 参见 `AU_CHAIN_FIX.md` 和 `MIXER_TROUBLESHOOTING.md`
10. **DAW-Style 侧链路由**（2026-03-23 新增）：
    - **预分配缓冲池**：`MKSidechainSlot` C 语言 struct 存储 pre-fader 信号
    - **原子 ping-pong 缓冲**：输入轨道信号跨输入/输出线程安全共享
    - **侧链源类型**：`input`（本地麦克风）、`session:N`（远程用户）、`masterBus1/2`
    - **每插件独立配置**：每个插件槽位独立选择侧链源
    - **AVAudioEngine 接线**：AU `inputBusses[1]` 连接第二 `AVAudioSourceNode`
    - **可视化拾取器**：AudioPluginMixerView 显示"SC"徽章（橙色=激活）
    - **WebSocket 命令**：`plugin.setSidechain` / `plugin.getSidechain`
    - **边缘情况**：源断开/静音时自动填充静音，自引用侧链允许

### 工作流程

1. **计划与待办**：功能补齐以 `.cursor/plans/` 下计划文件为准；待办在 Cursor 内维护，不修改计划文件本身。
2. **实现顺序**：按计划中的批次（第一批上下文菜单 → 第二批 ServerConfig → 第三批新视图 → 第四批连接/欢迎 → 第五批用户增强 → 第六批设置）逐项实现；新增 Swift 文件需加入 Xcode 工程 Mumble target（如用 `pbxproj`：`project.add_file(path, target_name='Mumble')`）。
3. **验证**：每批或每项完成后执行 `xcodebuild -scheme Mumble -destination 'generic/platform=iOS' build` 与 `platform=macOS` 构建，确保双平台通过。
4. **MumbleKit**：默认优先应用层修改；若涉及协议兼容、消息解析、崩溃修复、音频 DSP，可修改 MumbleKit（遵守 MRC 规范），并补充双平台构建验证。涉及 AU DSP 链改动时，先执行 `xcodebuild -scheme "MumbleKit (Mac)" -destination 'platform=macOS' build` 验证。
5. **权限**：新菜单/入口用 `serverManager.hasPermission(_:forChannelId:)` 或 `hasRootPermission(_:)` 控制可见性，与现有 Kick/Ban、Link、Ban List、Registered Users 一致。
