# 代码重构设计文档：日志、常量与 Async/Await

## 概述

本文档描述了 Mumble iOS/macOS 项目的代码重构计划，包括：
- 日志系统统一
- 常量整合
- 错误处理现代化
- Async/Await 迁移

## 目标

1. 移除调试日志，保留生产级日志，统一使用 OSLog/Logger
2. 整合分散的常量（通知名称、UI 尺寸、字符串常量）
3. 定义统一错误类型，迁移到 async/await

## 分支

```
refactor/logging-constants-async
```

## 第一部分：日志系统

### 结构

```
Source/Classes/SwiftUI/Core/
├── MumbleLogger.swift          # 统一日志入口
└── LogCategories.swift         # 日志分类定义
```

### 日志分类

```swift
enum LogCategory {
    case connection    // 连接状态
    case audio         // 音频引擎
    case database      // 数据库操作
    case certificate   // 证书管理
    case notification  // 通知系统
    case ui            // UI 状态
}
```

### 使用示例

```swift
// 替换前
NSLog(@"[DEBUG] 🔧 setupAudio CALLED!")

// 替换后
Logger.audio.info("Audio engine setup completed")
Logger.connection.error("Connection failed: \(error)")
```

### ObjC 兼容

```objc
#define MULogInfo(category, format, ...)  ...
#define MULogError(category, format, ...) ...
```

## 第二部分：常量整合

### 结构

```
Source/Classes/SwiftUI/Core/Constants/
├── NotificationConstants.swift    # 通知名称
├── UIConstants.swift              # UI 尺寸配置
└── StringConstants.swift          # 字符串常量
```

### 通知名称

```swift
extension Notification.Name {
    static let connectionOpened = Notification.Name("MUConnectionOpened")
    static let connectionClosed = Notification.Name("MUConnectionClosed")
    static let connectionError = Notification.Name("MUConnectionError")
    static let certificateCreated = Notification.Name("MUCertificateCreated")
}
```

### UI 尺寸配置

```swift
enum UIConstants {
    enum Spacing {
        #if os(macOS)
        static let rowSpacing: CGFloat = 6.0
        static let rowPaddingV: CGFloat = 4.0
        #else
        static let rowSpacing: CGFloat = 7.0
        static let rowPaddingV: CGFloat = 6.0
        #endif
    }

    enum FontSize {
        #if os(macOS)
        static let body: CGFloat = 13.0
        #else
        static let body: CGFloat = 16.0
        #endif
    }
}
```

### 字符串常量

```swift
enum StringConstants {
    enum UserDefaults {
        static let lastServer = "MULastConnectedServer"
        static let audioSettings = "MUPreprocessAudio"
    }

    enum Keychain {
        static let service = "MumbleKeychainService"
    }
}
```

## 第三部分：错误处理与 Async/Await

### 结构

```
Source/Classes/SwiftUI/Core/
├── Errors/
│   ├── MumbleError.swift           # 统一错误类型定义
│   └── MumbleError+Localized.swift # 本地化描述
├── AsyncWrappers/
│   ├── ConnectionAsync.swift       # 连接相关 async 包装
│   ├── CertificateAsync.swift      # 证书相关 async 包装
│   └── DatabaseAsync.swift         # 数据库相关 async 包装
```

### 统一错误类型

```swift
enum MumbleError: Error {
    // 连接错误
    case connectionFailed(reason: String)
    case connectionTimeout
    case disconnected

    // 证书错误
    case certificateCreationFailed
    case certificateNotFound

    // 数据库错误
    case databaseError(operation: String, reason: String)

    // 网络错误
    case networkError(underlying: Error)
    case serverError(code: Int, message: String)

    // 认证错误
    case authenticationFailed
    case invalidCredentials
}
```

### Async 包装器示例

```swift
extension MUConnectionController {
    func connect(
        to hostname: String,
        port: UInt16,
        username: String,
        tokens: [String]? = nil,
        certificateToken: Data? = nil
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.connect(toHostname: hostname,
                        port: port,
                        username: username,
                        tokens: tokens,
                        withToken: certificateToken) { error in
                if let error = error {
                    continuation.resume(throwing: MumbleError.from(error))
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
```

## 第四部分：执行计划

### 阶段划分

| 阶段 | 任务 | 验证方式 |
|------|------|----------|
| Phase 1 | 创建分支 + 日志系统 | 编译通过 + 日志输出验证 |
| Phase 2 | 常量整合 | 编译通过 + 功能回归 |
| Phase 3 | 错误类型定义 | 编译通过 + 单元测试 |
| Phase 4 | Async 包装器 | 编译通过 + 连接测试 |
| Phase 5 | 清理废弃代码 | 全量回归测试 |

### 需要修改的文件

| 文件 | 改动类型 |
|------|----------|
| `MUApplicationDelegate.m` | 移除调试日志，使用新日志宏 |
| `MUConnectionController.m/.swift` | 添加 async 包装 |
| `MUCertificateController.m` | 添加 async 包装 |
| `MUDatabase.m` | 添加 async 包装 |
| `ChannelView.swift` | 使用 UIConstants |
| `ServerModelManager.swift` | 使用新常量和日志 |

## 最终文件结构

```
Source/Classes/SwiftUI/Core/
├── MumbleLogger.swift
├── LogCategories.swift
├── Constants/
│   ├── NotificationConstants.swift
│   ├── UIConstants.swift
│   └── StringConstants.swift
├── Errors/
│   ├── MumbleError.swift
│   └── MumbleError+Localized.swift
└── AsyncWrappers/
    ├── ConnectionAsync.swift
    ├── CertificateAsync.swift
    └── DatabaseAsync.swift
```