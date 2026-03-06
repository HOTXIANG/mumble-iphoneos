# Mumble iPhone/macOS - 项目开发规范

## 项目概述

Mumble 是一个跨平台 VoIP 应用，支持 iOS 和 macOS。这是一个混合架构项目，包含 Objective-C 遗留代码和现代 Swift/SwiftUI 代码。

## 技术栈

- **最低版本**: iOS 17.0+ / macOS 13.0+
- **语言**: Swift 5.9+, Objective-C
- **架构**: SwiftUI + UIKit/AppKit 混合
- **数据库**: SQLite (FMDB)
- **音频**: MumbleKit (自研音频框架)
- **编解码**: Opus

---

## 代码规范

### 1. Swift 代码风格

#### 命名约定
```swift
// 类/结构体/枚举：PascalCase
class ServerModelManager: ObservableObject { }
enum LogCategory: String { }

// 变量/函数：camelCase
private var isConnected: Bool
func connectAsync(to hostname: String) async throws

// 常量：camelCase（枚举内）或 PascalCase（全局常量）
enum StringConstants {
    static let bundleIdentifier = "com.mumble.Mumble"
}

// 类型别名：PascalCase
typealias CompletionHandler = (Result) -> Void
```

#### 访问控制
```swift
// 优先使用最严格的访问级别
private var _internalState: Int  // 仅当前类型可见
fileprivate var _fileState: Int  // 仅当前文件可见
internal func helper()           // 模块内可见（默认）
public func api()                // 模块外可见（谨慎使用）
```

#### 属性声明顺序
```swift
class Example: ObservableObject {
    // 1. Published 属性
    @Published var isConnected: Bool = false

    // 2. 其他 @propertyWrapper 属性
    @AppStorage("key") var storedValue: String = ""

    // 3. 普通属性（先 private/internal，后 public）
    private var internalState: Int = 0

    // 4. 计算属性
    var computedValue: String { return "" }

    // 5. 初始化方法
    init() { }
}
```

---

### 2. 日志规范

使用统一的 `MumbleLogger`（基于 OSLog）：

```swift
import os

// 在 AppState.swift 中定义的 Logger
MumbleLogger.connection.info("连接状态更新")
MumbleLogger.audio.error("音频初始化失败：\(error)")
MumbleLogger.ui.debug("UI 状态：\(state)")
MumbleLogger.model.warning("模型数据异常")
MumbleLogger.handoff.info("Handoff 活动接收")

// 日志级别优先级：debug < info < warning < error < critical
```

**日志分类** (`LogCategory.swift`):
- `connection` - 连接状态
- `audio` - 音频引擎
- `database` - 数据库操作
- `certificate` - 证书管理
- `notification` - 通知系统
- `ui` - UI 状态

---

### 3. 错误处理规范

#### 统一错误类型 (`MumbleError.swift`)

```swift
enum MumbleError: Error {
    // 连接错误
    case connectionFailed(reason: String)
    case connectionTimeout
    case disconnected
    case networkError(underlying: Error)

    // 证书错误
    case certificateCreationFailed
    case certificateNotFound
    case certificateImportFailed(reason: String)

    // 数据库错误
    case databaseError(operation: String, reason: String)
    case dataNotFound

    // ... 其他错误类型
}

// 使用示例
func connect() async throws {
    do {
        try await connection.connect()
    } catch {
        throw MumbleError.connectionFailed(reason: error.localizedDescription)
    }
}
```

#### 错误本地化 (`MumbleError+Localized.swift`)

```swift
extension MumbleError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .connectionFailed(let reason):
            return NSLocalizedString("连接失败：\(reason)", comment: "")
        case .certificateNotFound:
            return NSLocalizedString("未找到证书", comment: "")
        // ...
        }
    }
}
```

---

### 4. 异步编程规范

#### Async/Await 包装器

新代码应使用 async/await，旧回调代码通过包装器转换：

```swift
// ConnectionAsync.swift
extension MUConnectionController {
    func connectAsync(
        to hostname: String,
        port: UInt16,
        username: String,
        password: String? = nil
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let state = ConnectionObserverState()

            state.successObserver = NotificationCenter.default.addObserver(
                forName: .muConnectionOpened,
                object: nil,
                queue: .main
            ) { [weak state] _ in
                state?.cleanup()
                continuation.resume()
            }

            // 发起连接...
        }
    }
}

// 使用示例
Task {
    do {
        try await MUConnectionController.shared().connectAsync(
            to: "server.example.com",
            port: 64738,
            username: "User"
        )
    } catch {
        print("连接失败：\(error)")
    }
}
```

#### Sendable 并发安全

```swift
// 跨并发边界的类使用 @unchecked Sendable
private final class ConnectionObserverState: @unchecked Sendable {
    var observer: NSObjectProtocol?
    private let lock = NSLock()

    func cleanup() {
        lock.lock()
        defer { lock.unlock() }
        // 安全移除观察者
    }
}

// 或使用 UncheckedSendable 包装器
struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
}
```

---

### 5. 常量管理规范

所有硬编码字符串应集中到常量文件：

```swift
// StringConstants.swift
enum StringConstants {
    enum UserDefaultsKey {
        static let lastServer = "MULastConnectedServer"
        static let audioPreprocess = "MUPreprocessAudio"
    }

    enum Keychain {
        static let service = "MumbleKeychainService"
    }

    enum Handoff {
        static let activityType = "info.mumble.Mumble.serverConnection"
    }

    enum Database {
        static let fileName = "mumble.sqlite"
    }
}

// 使用
let key = StringConstants.UserDefaultsKey.lastServer
```

---

### 6. Notification 规范

#### 定义 (`AppState.swift`)

```swift
extension Notification.Name {
    // 连接状态
    static let muConnectionOpened = Notification.Name("MUConnectionOpenedNotification")
    static let muConnectionClosed = Notification.Name("MUConnectionClosedNotification")
    static let muConnectionError = Notification.Name("MUConnectionErrorNotification")

    // 音频
    static let mkAudioDidRestart = Notification.Name("MKAudioDidRestartNotification")

    // 偏好设置
    static let muPreferencesChanged = Notification.Name("MumblePreferencesChanged")

    // macOS 特定
    #if os(macOS)
    static let muMacAudioInputDevicesChanged = Notification.Name("MUMacAudioInputDevicesChanged")
    #endif
}
```

#### 发送和接收

```swift
// 发送
NotificationCenter.default.post(name: .muConnectionOpened, object: nil)

// 接收（SwiftUI 使用 onReceive）
struct MyView: View {
    @State private var isConnected = false

    var body: some View {
        Text(isConnected ? "已连接" : "未连接")
            .onReceive(NotificationCenter.default.publisher(for: .muConnectionOpened)) { _ in
                isConnected = true
            }
    }
}

// 接收（传统方式）
NotificationCenter.default.addObserver(
    self,
    selector: #selector(handleConnectionOpened),
    name: .muConnectionOpened,
    object: nil
)
```

---

### 7. 架构规范

#### 目录结构

```
Source/
├── Classes/
│   ├── SwiftUI/
│   │   ├── Core/
│   │   │   ├── AsyncWrappers/     # async/await 包装器
│   │   │   ├── Constants/         # 常量定义
│   │   │   ├── Errors/            # 错误类型
│   │   │   └── LogCategories.swift
│   │   ├── Channel/               # 频道相关视图
│   │   ├── Preferences/           # 设置界面
│   │   ├── ServerModelManager/    # 服务器管理
│   │   └── Models/                # 数据模型
│   ├── MUMacApplicationDelegate.swift
│   └── MUApplicationDelegate.swift
├── MumbleKit/                     # 音频/网络底层框架
└── MumbleWidget/                  # Widget 扩展
```

#### 数据流向

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│  SwiftUI View   │────▶│  ServerModelMgr  │────▶│ MUConnectionCtl │
└─────────────────┘     └──────────────────┘     └─────────────────┘
                              │                          │
                              ▼                          ▼
                        ┌─────────────┐           ┌─────────────┐
                        │  MUDatabase │           │  MumbleKit  │
                        └─────────────┘           └─────────────┘
```

#### AppState 单例模式

```swift
@MainActor
class AppState: ObservableObject {
    static let shared = AppState()

    @Published var isConnected: Bool = false
    @Published var isConnecting: Bool = false
    @Published var activeError: AppError?
    @Published var activeToast: AppToast?

    private init() { }
}
```

---

### 8. Objective-C 互操作规范

#### Bridging Header

```objc
// Source/Mumble-Bridging-Header.h
#import "MUFavouriteServer.h"
#import "MUDatabase.h"
#import "MUConnectionController.h"
#import "MKAudio.h"
// ... 其他需要暴露给 Swift 的头文件
```

#### Swift 调用 Objective-C

```swift
// 直接调用类方法
MUDatabase.initializeDatabase()
MUDatabase.storeFavourite(server)

// 调用单例
MUConnectionController.shared()?.connect(toHostname: hostname, port: UInt(port))

// 使用 MKAudio
MKAudio.shared()?.update(&settings)
```

#### Objective-C 调用 Swift

```objc
// 通过 Notification 通知 Swift
[[NSNotificationCenter defaultCenter] postNotificationName:@"MUConnectionOpenedNotification" object:nil];

// 或通过 AppDelegate 暴露属性
[MUApplicationDelegate shared].connectionActive = YES;
```

---

### 9. UI 组件规范

#### SwiftUI 视图组织

```swift
struct ParentView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = ViewModel()

    var body: some View {
        VStack {
            HeaderView()
            ContentView()
            FooterView()
        }
        .onAppear {
            viewModel.load()
        }
        .onChange(of: appState.isConnected) {
            handleConnectionChange()
        }
    }
}
```

#### 错误提示组件

```swift
// 使用 AppState 的 activeError 和 activeToast
struct ErrorAlertModifier: ViewModifier {
    @ObservedObject var appState = AppState.shared

    func body(content: Content) -> some View {
        content
            .alert("错误", isPresented: .constant(appState.activeError != nil)) {
                Button("确定") {
                    appState.activeError = nil
                }
            } message: {
                Text(appState.activeError?.message ?? "")
            }
    }
}
```

---

### 10. 平台特定代码规范

#### 条件编译

```swift
#if os(macOS)
import AppKit
// macOS 特定实现
#elseif os(iOS)
import UIKit
// iOS 特定实现
#endif
```

#### 平台隔离

对于复杂功能，使用独立文件：

```
PreferencesView.swift              // 共享逻辑
PreferencesView+iOS.swift          // iOS 特定
PreferencesView+macOS.swift        // macOS 特定
```

---

## 开发工作流

### 编译命令

```bash
# iOS 模拟器
xcodebuild -project Mumble.xcodeproj -scheme Mumble \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' build

# macOS
xcodebuild -project Mumble.xcodeproj -scheme Mumble \
  -sdk macosx -destination 'platform=macOS' build
```

### 代码检查

```bash
# Swift 格式化（如使用 swiftformat）
swiftformat --lint Source/

# 静态分析
xcodebuild analyze -scheme Mumble -sdk iphonesimulator
```

### Git 提交规范

```
feat: 新功能（feature）
fix: 修复 bug
docs: 文档更新
style: 代码格式（不影响功能）
refactor: 重构（既不是新功能也不是 bug 修复）
test: 添加/修复测试
chore: 构建过程或辅助工具变动

# 示例
feat: 添加服务器收藏功能
fix: 修复音频回声问题
refactor: 统一日志系统
```

---

## 关键注意事项

1. **线程安全**: 所有 UI 更新必须在主线程 (`@MainActor`)
2. **内存管理**: 注意循环引用，使用 `[weak self]` 或 `[unowned self]`
3. **异步操作**: 新代码使用 async/await，避免回调地狱
4. **错误处理**: 使用统一的 `MumbleError` 类型
5. **日志输出**: 使用 `MumbleLogger` 而非 `print()`
6. **平台兼容**: 使用 `#if os()` 隔离平台特定代码

---

## 相关文件

- `Source/Classes/SwiftUI/Core/` - 核心工具类和常量
- `Source/Classes/SwiftUI/AppState.swift` - 应用全局状态
- `MumbleKit/` - 底层音频/网络框架
- `docs/plans/` - 架构设计文档
