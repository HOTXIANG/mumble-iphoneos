# Mumble 统一日志系统

## 概述

Mumble 使用基于 `LogManager` 单例的统一日志系统，覆盖 Swift（UI 层）、Objective-C/ARC（应用逻辑层）、MumbleKit/MRC（音频/网络底层）三层。所有日志通过统一管控点路由，支持分类开关、等级过滤、运行时动态调整和可选文件持久化。

## 架构

```
┌─────────────────────────────────────────────────────────────┐
│                     调用层                                    │
├──────────────────┬──────────────────┬────────────────────────┤
│   Swift 层       │   ObjC 应用层    │   MumbleKit (MRC)      │
│ MumbleLogger     │ MULog* 宏       │ MKLog* 宏              │
│   .audio.info()  │ MULogInfo(...)   │ MKLogInfo(...)         │
└────────┬─────────┴────────┬─────────┴──────────┬─────────────┘
         │                  │                    │
         ▼                  ▼                    ▼
┌─────────────────┐  ┌──────────────────┐  ┌──────────────────┐
│    LogProxy     │  │ MumbleLogFormatted│  │ MumbleLogFormatted│
│  (Swift struct) │  │   (C function)   │  │   (C function)   │
└────────┬────────┘  └────────┬─────────┘  └────────┬─────────┘
         │                    │                      │
         ▼                    ▼                      ▼
┌─────────────────────────────────────────────────────────────┐
│                    LogManager.shared                         │
│  - 全局开关 (isEnabled)                                      │
│  - 分类等级过滤 (categoryLevels)                              │
│  - 分类开关 (categoryEnabled)                                 │
│  - OSLog 输出                                                │
│  - 可选文件写入 (LogFileWriter)                               │
└─────────────────────────────────────────────────────────────┘
         │                                    │
         ▼                                    ▼
┌─────────────────┐              ┌──────────────────────────┐
│   Console.app   │              │  Documents/Logs/         │
│   (OSLog)       │              │  mumble-YYYY-MM-DD.log   │
└─────────────────┘              └──────────────────────────┘
```

**MumbleKit 独立构建时**：`MumbleLogFormatted` 通过 `dlsym` 动态查找 `MumbleLogBridge` 符号，如不存在则自动回退到 `os_log` 直接输出。

## 文件结构

| 文件 | 位置 | 职责 |
|------|------|------|
| `LogCategories.swift` | `Source/Classes/SwiftUI/Core/` | `LogLevel`、`LogCategory`、`LogManager`、`LogProxy`、`LogFileWriter`、`MumbleLogger` 枚举、`@_cdecl MumbleLogBridge` |
| `MumbleLogger.h` | `Source/Classes/SwiftUI/Core/` | ObjC 宏定义 `MULog*`/`MKLog*`、等级常量 |
| `MumbleLogger.m` | `Source/Classes/SwiftUI/Core/` | `MumbleLogFormatted()` 实现、dlsym 桥接、os_log 回退 |
| `LogSettingsView.swift` | `Source/Classes/SwiftUI/Preferences/` | 设置界面（全局开关、分类控制、文件持久化、导出） |

## 日志等级

```
error (4) > warning (3) > info (2) > debug (1) > verbose (0)
```

设定某等级后，只输出该等级**及以上**的日志。

| 等级 | OSLogType | 用途 | 示例 |
|------|-----------|------|------|
| `verbose` | `.debug` | 极详细追踪（每帧/每包级别） | UDP ping RTT、编码帧大小 |
| `debug` | `.debug` | 开发调试细节 | 状态变更值、性能计量、中间结果 |
| `info` | `.info` | 正常操作节点 | 连接成功、服务器发现、证书生成 |
| `warning` | `.default` | 异常但可恢复 | 格式回退、信任失败、解析超时 |
| `error` | `.error` | 操作失败 | 连接断开、数据库打开失败、加密错误 |

**默认等级**：
- Debug 构建：`debug`（显示 debug 及以上）
- Release 构建：`info`（显示 info 及以上）

## 日志分类

| 分类 | rawValue | 覆盖范围 |
|------|----------|---------|
| `connection` | `Connection` | 服务器连接/断开/重连/SSL |
| `audio` | `Audio` | 音频引擎、设备切换、VPIO、TTS |
| `ui` | `UI` | 视图状态、渲染性能、UI 交互 |
| `model` | `Model` | ServerModelManager 数据变更 |
| `handoff` | `Handoff` | Handoff/LiveActivity |
| `general` | `General` | 应用生命周期、启动/退出 |
| `notification` | `Notification` | 推送/本地通知 |
| `database` | `Database` | SQLite/FMDB 操作、收藏、令牌 |
| `certificate` | `Certificate` | 证书创建/导入/导出/验证 |
| `plugin` | `Plugin` | AU/VST3 插件加载/渲染/链管理 |
| `network` | `Network` | Mumble 协议层包收发、加密 |
| `codec` | `Codec` | Opus/Speex 编解码 |
| `discovery` | `Discovery` | LAN 服务发现（Bonjour/mDNS） |

## 使用方法

### Swift

```swift
// 基本用法
MumbleLogger.connection.info("已连接到 \(hostname):\(port)")
MumbleLogger.audio.error("音频初始化失败：\(error)")
MumbleLogger.plugin.debug("AU 加载完成：\(pluginName)")
MumbleLogger.discovery.warning("服务解析超时：\(serviceName)")
MumbleLogger.network.verbose("收到 UDP 包: \(packetSize) bytes")

// 所有 13 个分类的入口
MumbleLogger.connection   // 连接
MumbleLogger.audio        // 音频
MumbleLogger.ui           // UI
MumbleLogger.model        // 模型
MumbleLogger.handoff      // Handoff
MumbleLogger.general      // 通用
MumbleLogger.notification // 通知
MumbleLogger.database     // 数据库
MumbleLogger.certificate  // 证书
MumbleLogger.plugin       // 插件
MumbleLogger.network      // 网络协议
MumbleLogger.codec        // 编解码
MumbleLogger.discovery    // 发现

// 每个分类支持 5 个等级方法
MumbleLogger.audio.verbose("...")
MumbleLogger.audio.debug("...")
MumbleLogger.audio.info("...")
MumbleLogger.audio.warning("...")
MumbleLogger.audio.error("...")
```

**注意**：`LogProxy` 接受普通 `String`，不支持 OSLog 的 `privacy:` 和 `format:` 插值参数。格式化请使用 `String(format:)`:

```swift
// 正确
MumbleLogger.ui.debug("elapsed_ms=\(String(format: "%.2f", elapsedMs))")

// 错误 — 编译不过
MumbleLogger.ui.debug("elapsed_ms=\(elapsedMs, format: .fixed(precision: 2))")
```

### ObjC 应用层（MU* 文件）

宏已通过 `Mumble.pch` 全局可用，无需额外 `#import`。

```objc
// category 是裸标识符，不是字符串
MULogInfo(Connection, @"连接成功: %@:%d", hostname, port);
MULogError(Database, @"数据库迁移失败: %@", error);
MULogDebug(Certificate, @"证书链长度: %d", chainLength);
MULogWarning(General, @"检测到异常状态: %d", state);
MULogVerbose(Network, @"收到数据包: %lu bytes", (unsigned long)size);
```

### MumbleKit（MK* 文件）

需要在文件顶部添加 `#import "MumbleLogger.h"`（或使用相对路径）。

```objc
#import "../../Source/Classes/SwiftUI/Core/MumbleLogger.h"

MKLogInfo(Audio, @"音频引擎启动: sampleRate=%f", rate);
MKLogError(Connection, @"包解析失败: type=%d", type);
MKLogWarning(Certificate, @"ASN.1 日期解析异常");
MKLogVerbose(Codec, @"Opus 编码帧: %d bytes", encodedLength);
```

**注意**：MumbleKit 是 MRC 层，宏调用不影响内存管理。`MumbleLogFormatted` 内部使用 ARC（MumbleLogger.m 属于主应用编译单元），但 NSString format 的内存由函数内部管理，调用方无需操心。

## 运行时控制

### 设置界面

- **iOS**：`Settings → Developer → Logging`
- **macOS**：设置窗口 → `Logging` 标签页

界面功能：
- 全局日志开关
- 文件持久化开关
- 每个分类独立启用/禁用
- 每个分类独立等级选择
- 日志文件列表和导出
- 一键重置到默认

### 环境变量

在 Xcode Scheme → Run → Arguments → Environment Variables 中设置：

| 变量 | 值 | 说明 |
|------|-----|------|
| `MUMBLE_LOG_LEVEL` | `verbose`/`debug`/`info`/`warning`/`error` | 全局等级覆盖 |
| `MUMBLE_LOG_DISABLED` | `audio,plugin,...` | 逗号分隔，禁用指定分类 |
| `MUMBLE_LOG_VERBOSE` | `connection,network,...` | 逗号分隔，指定分类设为 verbose 并强制启用 |
| `MUMBLE_LOG_FILE` | `1` 或 `true` | 启用文件持久化 |

**优先级**：环境变量 > UserDefaults（设置界面）> 默认值

### 代码控制

```swift
// 全局开关
LogManager.shared.isEnabled = false

// 分类开关
LogManager.shared.setEnabled(false, for: .audio)

// 分类等级
LogManager.shared.setLevel(.verbose, for: .connection)

// 文件持久化
LogManager.shared.isFilePersistenceEnabled = true

// 重置所有设置
LogManager.shared.resetToDefaults()
```

## 文件持久化

### 存储位置

- **iOS**: `Documents/Logs/mumble-YYYY-MM-DD.log`
- **macOS**: `Application Support/Mumble/Logs/mumble-YYYY-MM-DD.log`

### 文件格式

```
2026-03-21 14:30:15.123 ℹ️ [Connection] ConnectionAsync.swift:29 connectAsync(to:port:username:password:certificateRef:displayName:) — Connecting async to example.com:64738 as user1
2026-03-21 14:30:15.456 ❌ [Audio] MKAudio.m:142 -[MKAudio setupAudioSession] — Audio session setup failed: error -10851
```

### 滚动策略

- 按天创建新文件
- 保留最近 7 天
- 旧文件自动清理

### 导出

- 设置界面提供导出按钮
- iOS：通过 `UIActivityViewController` 分享
- macOS：通过 `NSSavePanel` 保存

### WebSocket 调试集成

在 `DEBUG` 构建中，`MUTestServer` 会额外维护一份内存中的最近日志缓冲，并支持通过 WebSocket 读取和订阅：

- `log.recent`：读取最近日志，支持按分类和最低等级过滤
- `log.stream`：为当前 WebSocket 连接开启实时日志推送
- `log.marker`：写入调试标记，方便 AI agent 划分一次自动化执行前后的日志窗口
- `log.files`：列出当前日志文件和历史文件
- `ui.changed`：配合 `log.entry` 追踪当前页面 / sheet / alert / overlay 状态，便于把日志窗口和具体 UI 交互对齐

实时推送事件格式为：

```json
{
  "event": "log.entry",
  "data": {
    "timestamp": "2026-03-22 15:04:12.345",
    "category": "Audio",
    "level": "debug",
    "message": "Audio restarted - restoring mute state: muted=false, deafened=false",
    "file": "ServerModelManager+AudioState.swift",
    "function": "restoreMuteDeafenStateAfterAudioRestart()",
    "line": 145
  }
}
```

## 当前关键日志点（2026-04-25）

音频生命周期和连接性能排查时，优先关注这些日志：

### 本地音频测试 / 欢迎引导

正常首次 VAD onboarding 应看到：

```text
[Audio] Starting Local Audio for Settings/Testing
[Audio] MKAudioInput: ... Opus (... constrained VBR, DTX, FEC)
[Audio] MKVoiceProcessingDevice: AudioUnit started.
[Audio] MKVoiceProcessingDevice: No buffer allocated. Allocating for ...
```

从 Input Setting 打开 VAD onboarding 时，设置页关闭与 onboarding 出现之间不应看到：

```text
[Audio] Stopping Local Audio (Settings closed)
```

如果看到这条日志，说明转场保留逻辑失效，可能会造成麦克风先关再开。

### 普通欢迎页空闲

普通欢迎页和前后台切换不应出现：

```text
[Audio] Starting Local Audio for Settings/Testing
[Audio] MKVoiceProcessingDevice: AudioUnit started.
```

除非当前正在展示 VAD onboarding、Input Setting、Mixer，或已经连接服务器。

### Opus 网络配置

Opus encoder 初始化日志应包含：

```text
constrained VBR, DTX, FEC
```

弱网模式已经删除，不应再出现 `WeakNetwork`、`weakNetworkMode`、`setWeakNetworkMode` 相关日志。

### 连接首帧性能

连接性能调试建议同时打开 `Connection`、`Audio`、`Model`、`UI` 分类，关注：

- `PERF connect_begin`
- `PERF connect_opened`
- `PERF connect_ready`
- `PERF rebuild_model_array` / model rebuild timing
- `Starting Audio Engine` / audio engine async startup timing

## 新增模块日志规范

为新功能添加日志时遵循以下原则：

1. **确定分类**：根据模块职责选择对应分类，不合适时使用 `General`
2. **关键操作**：创建/删除/连接/断开等操作至少 `info` 级
3. **错误路径**：所有 `catch` 块和失败分支必须 `error` 或 `warning` 级，包含错误详情
4. **性能路径**：耗时操作用 `debug` 级，包含 elapsed_ms
5. **高频路径**：每帧/每包级别的日志用 `verbose`，避免 debug 模式下刷屏
6. **消息简洁**：不加 emoji 前缀（等级已区分严重性），不复述函数名（文件持久化会自动记录）
7. **敏感信息**：不记录密码、证书内容等，用户 hash 只记录前 8 位

### 检查清单

新增模块 PR 前确认：

- [ ] 所有公开方法入口有 `info` 或 `debug` 日志
- [ ] 所有错误路径有 `error` 或 `warning` 日志，包含错误对象
- [ ] 无 `print()` 或 `NSLog()` 残留
- [ ] 分类选择正确（参考分类表）
- [ ] 高频路径使用 `verbose` 而非 `debug`

## 调试技巧

### Console.app 过滤

1. 打开 Console.app
2. 选择对应设备/模拟器
3. 搜索框输入 `subsystem:cn.hotxiang.Mumble`
4. 可进一步过滤 `category:Audio` 等

### Xcode Console

Xcode 调试运行时，`debug` 及以上日志自动显示在控制台。`verbose` 级别需要在 Console.app 中查看（Xcode 默认过滤 `.debug` 类型）。

### 快速排查场景

| 场景 | 环境变量设置 |
|------|------------|
| 排查连接问题 | `MUMBLE_LOG_VERBOSE=Connection,Network` |
| 排查音频问题 | `MUMBLE_LOG_VERBOSE=Audio,Codec` |
| 排查插件问题 | `MUMBLE_LOG_VERBOSE=Plugin,Audio` |
| 只看错误 | `MUMBLE_LOG_LEVEL=error` |
| 全量日志写文件 | `MUMBLE_LOG_LEVEL=verbose MUMBLE_LOG_FILE=1` |
