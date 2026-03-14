# Mumble iOS/macOS - 项目开发规范

## 项目概述

Mumble 是一个跨平台 VoIP 应用，支持 iOS（iPhone + iPad）和 macOS。采用三层混合架构：SwiftUI（UI 层）→ Objective-C/ARC（应用逻辑层）→ MumbleKit/MRC（音频/网络底层）。

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

```
SwiftUI Views
    │
    ├─ @StateObject / @ObservedObject ──▶ ServerModelManager (@MainActor, ObservableObject)
    │                                         │
    │                                         ├─ ServerModelDelegateWrapper (@objc, MKServerModelDelegate)
    │                                         │       └─ 接收 MumbleKit 回调 → Task { @MainActor in ... }
    │                                         │
    │                                         └─ NotificationCenter 观察者 (ObserverTokenHolder 管理生命周期)
    │
    ├─ @ObservedObject ──▶ AppState.shared (@MainActor 单例)
    │                         ├─ @Published isConnected, isConnecting, activeToast, activeError...
    │                         └─ CertTrustBridge (@objc, 供 ObjC 直接调用)
    │
    ├─ 直接调用 ──▶ MUConnectionController.sharedController() (ObjC 单例, ARC)
    │                  ├─ MKConnection (MumbleKit, MRC)
    │                  └─ MUDatabase (ObjC, ARC, 类方法, dispatch_queue_t 串行)
    │
    └─ 直接调用 ──▶ MKAudio.shared() (MumbleKit, MRC)
```

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

使用 `MumbleLogger`（基于 OSLog），禁止 `print()` 用于正式日志：

```swift
MumbleLogger.connection.info("连接状态更新")
MumbleLogger.audio.error("音频初始化失败：\(error)")
MumbleLogger.ui.debug("UI 状态变更")
```

分类: `general`、`connection`、`audio`、`database`、`certificate`、`notification`、`ui`、`model`、`handoff`

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

**明确不实现**：Public Server List（公网服务器列表）。

**待实现（按计划顺序）**：

1. **Local Nickname**：用户上下文菜单「Set Nickname」+ `LocalUserPreferences` 持久化 + 显示优先昵称
2. **Friends List**：按 userHash 存储好友，上下文菜单 Add/Remove Friend，频道树高亮
3. **Local Text Ignore**：用户菜单「Ignore Messages」+ 消息接收时按 hash 过滤
4. **Drag Channels**：macOS 频道行 `.onDrag`，drop 时处理 `channel:` 前缀移动频道
5. **TTS**：设置页 TTS 开关，消息/用户事件时 `AVSpeechSynthesizer`
6. **Channel Hide/Pin**：频道菜单 Hide/Pin，`rebuildModelArray` 过滤 + UserDefaults 持久化（按服务器 digest）
7. **Network Settings**：PreferencesView 增加 Network 区块（如自动重连、QoS）

**暂缓**：Audio Wizard、Global Shortcuts、Advanced Log Config、ContextAction、Voice Recording。

### 工作流程

1. **计划与待办**：功能补齐以 `.cursor/plans/` 下计划文件为准；待办在 Cursor 内维护，不修改计划文件本身。
2. **实现顺序**：按计划中的批次（第一批上下文菜单 → 第二批 ServerConfig → 第三批新视图 → 第四批连接/欢迎 → 第五批用户增强 → 第六批设置）逐项实现；新增 Swift 文件需加入 Xcode 工程 Mumble target（如用 `pbxproj`：`project.add_file(path, target_name='Mumble')`）。
3. **验证**：每批或每项完成后执行 `xcodebuild -scheme Mumble -destination 'generic/platform=iOS' build` 与 `platform=macOS` 构建，确保双平台通过。
4. **MumbleKit**：默认优先应用层修改；若涉及协议兼容、消息解析、崩溃修复，可修改 MumbleKit（遵守 MRC 规范），并补充双平台构建验证。
5. **权限**：新菜单/入口用 `serverManager.hasPermission(_:forChannelId:)` 或 `hasRootPermission(_:)` 控制可见性，与现有 Kick/Ban、Link、Ban List、Registered Users 一致。
