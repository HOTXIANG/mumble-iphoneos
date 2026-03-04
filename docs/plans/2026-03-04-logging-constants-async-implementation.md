# 实施计划：日志、常量与 Async/Await 重构

## 前置条件

- [ ] 从 master 创建新分支 `refactor/logging-constants-async`

---

## Phase 1: 日志系统统一

### 1.1 创建日志基础设施

**新建文件：**
- `Source/Classes/SwiftUI/Core/LogCategories.swift`
- `Source/Classes/SwiftUI/Core/MumbleLogger.swift`
- `Source/Classes/SwiftUI/Core/MumbleLogger.h` (ObjC 头文件)

**任务：**
1. 定义 LogCategory 枚举（connection, audio, database, certificate, notification, ui）
2. 创建 Logger 扩展，为每个分类提供静态访问
3. 创建 ObjC 兼容宏 (MULogInfo, MULogError, MULogDebug)

**验证：** 编译通过

### 1.2 清理调试日志

**需要修改的文件：**

| 文件 | 行号 | 当前内容 | 改动 |
|------|------|----------|------|
| `MUApplicationDelegate.m` | 196 | `NSLog(@"[DEBUG] 🔧 setupAudio CALLED!...")` | 移除 |
| `MUApplicationDelegate.m` | 301 | `NSLog(@"[DEBUG] 🔧 Settings changed...")` | 改为 `Logger.audio.info` |
| `MUApplicationDelegate.m` | 304 | `NSLog(@"[DEBUG] 💤 Settings updated...")` | 改为 `Logger.audio.debug` |
| `MUApplicationDelegate.m` | 308 | `NSLog(@"[DEBUG] ✅ setupAudio FINISHED...")` | 改为 `Logger.audio.info` |
| `ServerModelNotificationManager.swift` | 119 | `print("✅ DEBUG: Correct delegate...")` | 改为 `Logger.notification.debug` |

**验证：** 编译通过，日志输出正常

---

## Phase 2: 常量整合

### 2.1 创建常量文件

**新建文件：**
- `Source/Classes/SwiftUI/Core/Constants/NotificationConstants.swift`
- `Source/Classes/SwiftUI/Core/Constants/UIConstants.swift`
- `Source/Classes/SwiftUI/Core/Constants/StringConstants.swift`

### 2.2 通知名称整合

**当前分散位置：**
- `MUConnectionController.m:20-23` - 连接相关通知
- `MUApplicationDelegate.m` - 可能的其他通知

**任务：**
1. 在 `NotificationConstants.swift` 中定义所有通知名称
2. 保持 ObjC 兼容（通过 extern 声明）
3. 更新所有使用处

**示例迁移：**
```objc
// 改前
extern NSString *MUConnectionOpenedNotification;

// 改后 (Swift)
extension Notification.Name {
    static let connectionOpened = Notification.Name("MUConnectionOpened")
}
```

### 2.3 UI 尺寸配置整合

**当前分散位置：**
- `ChannelView.swift` - kRowSpacing, kFontSize 等
- `FavouriteServerListView.swift` - 类似常量
- `WelcomeView.swift` - 类似常量

**任务：**
1. 提取所有 `private let k...` 常量
2. 整合到 `UIConstants.swift`
3. 更新所有使用处

### 2.4 字符串常量整合

**任务：**
1. 搜索所有硬编码字符串（UserDefaults keys, Keychain service 等）
2. 整合到 `StringConstants.swift`
3. 更新所有使用处

**验证：** 编译通过，功能回归测试

---

## Phase 3: 错误类型定义

### 3.1 创建错误类型

**新建文件：**
- `Source/Classes/SwiftUI/Core/Errors/MumbleError.swift`
- `Source/Classes/SwiftUI/Core/Errors/MumbleError+Localized.swift`

**任务：**
1. 定义 MumbleError 枚举
2. 实现 LocalizedError 协议
3. 实现 NSError 转换（ObjC 兼容）

**验证：** 编译通过

---

## Phase 4: Async 包装器

### 4.1 创建 async 包装

**新建文件：**
- `Source/Classes/SwiftUI/Core/AsyncWrappers/ConnectionAsync.swift`
- `Source/Classes/SwiftUI/Core/AsyncWrappers/CertificateAsync.swift`
- `Source/Classes/SwiftUI/Core/AsyncWrappers/DatabaseAsync.swift`

### 4.2 连接控制器包装

**目标方法：**
- `connectToHostname:port:username:tokens:withToken:` → `connect(to:port:username:tokens:certificateToken:) async throws`
- `disconnect` → `disconnect() async`
- 其他异步操作

**任务：**
1. 使用 `withCheckedThrowingContinuation` 包装现有回调
2. 标记原方法为 `@available(*, deprecated)`
3. 在 Swift 调用处迁移到新方法

### 4.3 证书控制器包装

**目标方法：**
- 证书创建相关方法
- 证书验证相关方法

### 4.4 数据库包装

**目标方法：**
- `MUDatabase` 中的异步操作

**验证：** 编译通过，连接测试

---

## Phase 5: 清理与测试

### 5.1 更新调用方

**需要更新的 Swift 文件：**
- `ServerModelManager.swift`
- `ServerModelManager+Controls.swift`
- `ServerModelManager+Lifecycle.swift`
- `AppState.swift`
- `FavouriteServerListView.swift`
- `ChannelView.swift`

### 5.2 添加单元测试

**新建测试文件：**
- `MumbleTests/MumbleErrorTests.swift`
- `MumbleTests/AsyncWrapperTests.swift`

### 5.3 全量回归测试

**任务：**
1. 在 iOS 模拟器上完整测试连接流程
2. 在 macOS 上完整测试连接流程
3. 验证日志输出正确性

---

## 文件变更清单

### 新建文件 (10个)

| 文件路径 | 用途 |
|----------|------|
| `Core/LogCategories.swift` | 日志分类 |
| `Core/MumbleLogger.swift` | 日志入口 |
| `Core/MumbleLogger.h` | ObjC 头文件 |
| `Core/Constants/NotificationConstants.swift` | 通知常量 |
| `Core/Constants/UIConstants.swift` | UI 尺寸 |
| `Core/Constants/StringConstants.swift` | 字符串常量 |
| `Core/Errors/MumbleError.swift` | 错误定义 |
| `Core/Errors/MumbleError+Localized.swift` | 本地化 |
| `Core/AsyncWrappers/ConnectionAsync.swift` | 连接 async |
| `Core/AsyncWrappers/CertificateAsync.swift` | 证书 async |
| `Core/AsyncWrappers/DatabaseAsync.swift` | 数据库 async |

### 修改文件 (约15个)

| 文件路径 | 改动类型 |
|----------|----------|
| `MUApplicationDelegate.m` | 日志清理 |
| `MUConnectionController.m` | 标记废弃 |
| `MUConnectionController.h` | 新增声明 |
| `MUDatabase.m` | 标记废弃 |
| `MUCertificateController.m` | 标记废弃 |
| `ChannelView.swift` | 使用新常量 |
| `ServerModelManager.swift` | 日志+常量+async |
| `ServerModelNotificationManager.swift` | 日志清理 |
| `FavouriteServerListView.swift` | 常量迁移 |
| `WelcomeView.swift` | 常量迁移 |
| ... | ... |

---

## 风险与回滚

**风险点：**
1. ObjC/Swift 桥接问题 - 保留原有方法可快速回滚
2. 异步上下文丢失 - 逐步迁移，每步验证

**回滚策略：**
- 每个 Phase 完成后创建检查点 commit
- 出问题可 `git revert` 单个 commit