# Mumble WebSocket 自动化测试服务器

## 概述

Mumble 内嵌了一个 WebSocket 测试服务器（`MUTestServer`），仅在 `DEBUG` 构建中编译。AI agent 或自动化脚本可通过 WebSocket 连接到运行中的 App，远程执行所有功能并验证结果。

## 弱网模式测试指南

### 启用弱网模式

```json
// 1. 启用弱网模式
{"action":"audio.setWeakNetworkMode","params":{"enabled":true}}

// 2. 配置弱网参数
{"action":"audio.setWeakNetworkConfig","params":{
    "jitterBufferMs": 150,
    "expectedLoss": 30,
    "adaptiveBitrate": true,
    "enhancedPLC": true,
    "minBitrate": 16000,
    "maxBitrate": 48000
}}

// 3. 查看弱网状态
{"action":"audio.weakNetworkStatus"}
```

### 弱网测试流程

1. **基线测试**（不启用弱网模式）
   - 连接服务器
   - 发送 `audio.status` 记录正常网络状态
   - 使用 `log.stream` 监控音频日志

2. **启用弱网模式**
   - 发送 `audio.setWeakNetworkMode` 启用
   - 发送 `audio.setWeakNetworkConfig` 配置参数
   - 等待 5 秒让设置生效

3. **模拟弱网条件**（需外部网络条件）
   - 使用 Network Link Conditioner 或 Clumsy 模拟：
     - 延迟：200-500ms
     - 丢包：10-30%
     - 抖动：±50ms

4. **监控指标**
   - `audio.weakNetworkStatus` - 每秒查询一次
   - 记录 `metrics.qualityScore` 变化
   - 记录 `metrics.packetLossPercent` 和 `metrics.effectiveLatencyMs`

5. **语音质量验证**
   - 发送 `audio.forceTransmit` 持续传输
   - 监听输出音频是否连续无断音
   - 检查 `log.entry` 中是否有 PLC 触发日志

### 弱网模式预期效果

| 指标 | 普通模式 | 弱网模式 |
|------|---------|---------|
| Jitter Buffer | 10-30ms | 100-300ms |
| FEC | 关闭 | 开启 |
| 丢包隐藏 | 基础 | 增强 + 平滑 |
| 码率 | 固定 | 16-64kbps 自适应 |
| 20% 丢包可懂度 | ~60% | ~85% |

## Agent 上手速览

如果你是第一次接手这个项目，按下面顺序做，不要直接盲点 UI：

1. **先确认是 Debug App**
   - `MUTestServer` 只在 `DEBUG` 构建存在。
   - App 启动后控制台必须出现 `TestServer: listening on ws://localhost:54296`。
2. **使用“长连接”而不是一次性请求**
   - `log.stream`、`ui.changed`、`connection.*` 等事件都是**推送式**。
   - `websocat -n1` 只适合一次性 query，不适合调试流程。
3. **先开日志，再做复现**
   - 先调用 `log.marker` 标记本轮调试开始。
   - 再用 `log.stream` 打开相关分类的实时日志。
4. **先读状态，再发动作**
   - 调试前至少执行一次：`state.get`、`ui.get`。
   - 如果是连接态问题，再加 `connection.status`。
   - 如果是插件/混音器问题，再加 `plugin.listTracks`、`plugin.available`。
5. **优先走语义命令，UI 命令只做导航**
   - 例如：插件链操作优先 `plugin.add/remove/load/unload/...`
   - 页面打开/关闭优先 `ui.open` / `ui.dismiss`
   - 不要把“能直接语义操作”的事情退化成模拟点击。
6. **每次改代码后重放同一组命令**
   - 保持复现脚本最小化，修复前后跑同一套步骤，便于确认回归。

## 推荐调试流程

### 1. 建立长连接

推荐用 Python 或 `websocat` 保持一个常驻连接，持续接收日志和事件。

### 2. 打开日志流

典型调试开始前先做：

```json
{"id":"m1","action":"log.marker","params":{"message":"debug session start","category":"General","level":"info"}}
{"id":"l1","action":"log.setLevel","params":{"category":"Plugin","level":"debug"}}
{"id":"l2","action":"log.setLevel","params":{"category":"Audio","level":"debug"}}
{"id":"l3","action":"log.stream","params":{"enabled":true,"categories":["Plugin","Audio","UI","General"],"minimumLevel":"debug"}}
```

### 3. 读取起始快照

```json
{"id":"s1","action":"state.get"}
{"id":"s2","action":"ui.get"}
{"id":"s3","action":"connection.status"}
```

### 4. 导航到目标页面

页面导航统一走 `ui.*`，例如：

```json
{"id":"u1","action":"ui.root"}
{"id":"u2","action":"ui.open","params":{"target":"audioPluginMixer"}}
{"id":"u3","action":"ui.open","params":{"target":"pluginBrowser","trackKey":"input"}}
```

### 5. 执行功能动作

进入页面后，优先使用对应语义域：

- 连接问题：`connection.*`
- 音频问题：`audio.*`
- 频道/消息问题：`channel.*` / `message.*`
- 插件链问题：`plugin.*`
- 设置问题：`settings.*`

### 6. 取证

每轮复现至少保留这几样：

- `log.entry` 实时日志
- `ui.changed` 页面状态流
- `state.get` 或 `state.snapshot`
- `log.recent`
- `log.export`

如果 App 崩溃，优先保留崩溃前最后一个 `log.marker` 到断连之间的日志窗口。

## 命令选择原则

### 语义命令优先

如果已有语义命令，不要绕去做 UI 自动化。例如：

- 添加插件：用 `plugin.add`，不要靠点插件浏览器列表
- 发送消息：用 `message.send`，不要靠编辑框输入
- 改设置：用 `settings.set`，不要靠设置页逐项点击

### UI 命令只负责“进入场景”

`ui.open` / `ui.dismiss` / `ui.back` / `ui.root` 的职责是：

- 打开页面
- 关闭 sheet / alert / overlay
- 校正当前导航状态
- 为语义命令创造前置环境

### 什么时候必须看 `ui.changed`

这些场景必须订阅 `ui.changed`：

- 复现 sheet / alert / overlay 相关 bug
- 需要确认当前页面是否真的切换成功
- 同一动作可能弹多个系统/自定义面板
- 崩溃发生在“打开页面”而不是“执行业务动作”时

## 最小可用 Agent 脚本

### Python 长连接模板

下面这个脚本适合新 agent 直接复制后改命令序列：

```python
import asyncio
import json
import websockets

WS_URL = "ws://localhost:54296"

async def send(ws, action, params=None, req_id=None):
    payload = {"action": action}
    if req_id:
        payload["id"] = req_id
    if params:
        payload["params"] = params
    await ws.send(json.dumps(payload, ensure_ascii=False))

async def main():
    async with websockets.connect(WS_URL, max_size=8 * 1024 * 1024) as ws:
        await send(ws, "log.marker", {"message": "agent debug start", "category": "General", "level": "info"}, "m1")
        await send(ws, "log.stream", {"enabled": True, "categories": ["Plugin", "Audio", "UI"], "minimumLevel": "debug"}, "l1")
        await send(ws, "state.get", req_id="s1")
        await send(ws, "ui.open", {"target": "audioPluginMixer"}, "u1")

        async for raw in ws:
            msg = json.loads(raw)
            print(json.dumps(msg, ensure_ascii=False, indent=2))

asyncio.run(main())
```

### websocat 调试方式

`websocat` 适合手工调试，但注意：

- `websocat ws://localhost:54296`：适合**长连接**
- `echo ... | websocat -n1 ...`：适合**单次查询**
- 想看 `log.stream` / `ui.changed` 时，不要用 `-n1`

## 高频调试模板

### 页面 / 导航类问题

1. `ui.root`
2. `ui.get`
3. `ui.open`
4. 观察 `ui.changed`
5. 若失败，再查 `log.recent` 中 `UI` / `General`

### 连接类问题

1. `log.stream` 打开 `Connection` / `Network` / `Audio`
2. `connection.connect`
3. 观察 `connection.*` 事件
4. `connection.status`
5. 如失败，`log.export`

### 插件 / Mixer 类问题

1. `ui.open target=audioPluginMixer`
2. `plugin.listTracks`
3. `plugin.available`
4. `plugin.add` 或 `ui.open target=pluginBrowser`
5. `plugin.load`
6. `plugin.parameters`
7. 同时订阅 `Plugin` / `Audio` / `UI` 日志

### 设置 / 状态类问题

1. `settings.get`
2. `settings.set`
3. `state.get`
4. 必要时再 `ui.open` 到对应页面核对展示

## 崩溃 / 卡死排查 SOP

如果自动化过程中 App 崩溃、socket 断开或页面不再响应，按这个顺序取证：

1. 在复现前写 `log.marker`
2. 保持 websocket 长连接，持续接收 `log.entry`
3. 记录最后一个成功响应和最后一个事件
4. 断连后立即读取：
   - `~/Library/Logs/DiagnosticReports/`
   - `log.export` 导出的最近日志文件
5. 重新启动 App 后，先执行：
   - `state.get`
   - `ui.get`
   - `log.recent`
6. 使用**同一组命令**重放，不要边试边改脚本

## 常见误区

- **误区：直接用一次性请求跑整套流程**
  - 结果：拿不到 `log.stream` / `ui.changed`，问题不可观测
- **误区：只会 `ui.open`，不会用语义命令**
  - 结果：脚本脆弱、调试成本高、回归难复现
- **误区：每次动作前不读状态**
  - 结果：脚本在错误上下文里执行，出现假失败
- **误区：日志分类开太少**
  - 结果：只看到 UI 表象，看不到音频 / 插件 / 网络根因
- **误区：不打 `log.marker`**
  - 结果：多轮自动化日志混在一起，难以切片分析

## 架构

```
┌─────────────────────────────────┐
│   AI Agent / 自动化脚本          │
│   (websocat / Python / Node.js) │
└──────────────┬──────────────────┘
               │ WebSocket (ws://localhost:54296)
               ▼
┌─────────────────────────────────┐
│        MUTestServer             │
│   NWListener + WebSocket 协议    │
│   JSON 消息收发 + 事件推送        │
└──────────────┬──────────────────┘
               │
               ▼
┌─────────────────────────────────┐
│      MUTestCommandRouter        │
│   action 路由 → 域处理器          │
├─────────────────────────────────┤
│ connection │ audio │ channel    │
│ message    │ user  │ favourite  │
│ settings   │ state │ app        │
│ ui         │ server│ certificate│
│ log        │       │            │
└──────────────┬──────────────────┘
               │
               ▼
┌─────────────────────────────────┐
│         App 模块                 │
│ MUConnectionController          │
│ MKAudio / MKServerModel         │
│ ServerModelManager              │
│ MUDatabase / AppState           │
│ LogManager                      │
└─────────────────────────────────┘
```

## 快速开始

### 1. 安装 websocat

```bash
brew install websocat
```

### 2. 启动 App（Debug 模式）

在 Xcode 中以 Debug 配置运行 App（模拟器或真机均可）。启动后控制台会输出：

```
TestServer: listening on ws://localhost:54296
```

### 3. 连接

```bash
# 真机需要在同一网络，使用设备 IP
websocat ws://localhost:54296

# 连接后发送 JSON 命令
{"action": "help.actions"}
{"action": "state.get"}
{"action": "connection.status"}
```

## JSON 协议

### 请求格式

```json
{
  "id": "optional-request-id",
  "action": "domain.command",
  "params": { "key": "value" }
}
```

- `id`（可选）：请求标识，响应中会原样返回
- `action`（必需）：`域.命令` 格式
- `params`（可选）：命令参数

### 成功响应

```json
{
  "id": "request-id",
  "success": true,
  "data": { ... }
}
```

### 失败响应

```json
{
  "id": "request-id",
  "success": false,
  "error": "错误描述"
}
```

### 事件推送

服务器会主动推送状态变更事件到所有连接的客户端：

```json
{
  "event": "connection.opened",
  "data": { "connected": true }
}
```

## 命令参考

### connection — 连接管理

| 命令 | 参数 | 说明 |
|------|------|------|
| `connection.connect` | `hostname`(必需), `port`(64738), `username`("TestUser"), `password`(""), `displayName` | 连接到服务器 |
| `connection.disconnect` | 无 | 断开连接 |
| `connection.acceptCert` | 无 | 接受待确认的服务器证书 |
| `connection.rejectCert` | 无 | 拒绝待确认的服务器证书 |
| `connection.status` | 无 | 获取连接状态 |

```bash
# 连接服务器
{"action": "connection.connect", "params": {"hostname": "mumble.example.com", "port": 64738, "username": "TestBot"}}

# 断开
{"action": "connection.disconnect"}

# 查看状态
{"action": "connection.status"}
```

### audio — 音频控制

| 命令 | 参数 | 说明 |
|------|------|------|
| `audio.mute` | 无 | 自我静音 |
| `audio.unmute` | 无 | 取消静音 |
| `audio.deafen` | 无 | 自我耳聋（同时静音） |
| `audio.undeafen` | 无 | 取消耳聋 |
| `audio.toggleMute` | 无 | 切换自我静音 |
| `audio.toggleDeafen` | 无 | 切换自我耳聋 |
| `audio.startTest` | 无 | 启动本地音频测试引擎 |
| `audio.stopTest` | 无 | 停止本地音频测试引擎 |
| `audio.restart` | 无 | 重启音频引擎 |
| `audio.forceTransmit` | `enabled`(必需) | 设置 Push-to-Talk 强制发话 |
| `audio.status` | 无 | 获取音频状态 |

```bash
{"action": "audio.mute"}
{"action": "audio.status"}
# → {"success": true, "data": {"running": true, "selfMuted": true, "selfDeafened": false}}
```

### channel — 频道操作

| 命令 | 参数 | 说明 |
|------|------|------|
| `channel.list` | 无 | 获取完整频道树（含用户） |
| `channel.info` | `channelId`(必需) | 获取频道详情 |
| `channel.join` | `channelId`(必需) | 加入指定频道 |
| `channel.create` | `parentId`(必需), `name`(必需), `temporary`(false) | 创建频道 |
| `channel.edit` | `channelId`(必需), `name`, `description`, `position`, `maxUsers` | 编辑频道 |
| `channel.move` | `channelId`(必需), `parentId`(必需) | 移动频道到新父频道 |
| `channel.remove` | `channelId`(必需) | 删除频道 |
| `channel.listen` | `channelId`(必需) | 监听频道 |
| `channel.unlisten` | `channelId`(必需) | 取消监听频道 |
| `channel.toggleCollapse` | `channelId`(必需) | 切换频道折叠 |
| `channel.togglePinned` | `channelId`(必需) | 切换频道置顶 |
| `channel.toggleHidden` | `channelId`(必需) | 切换频道隐藏 |
| `channel.requestACL` | `channelId`(必需) | 请求频道 ACL |
| `channel.setAccessTokens` | `tokens`(必需, string[]) | 设置 access token 列表 |
| `channel.submitPassword` | `channelId`(必需), `password`(必需) | 提交频道密码并尝试进入 |
| `channel.scanPermissions` | 无 | 重新扫描所有频道权限 |
| `channel.current` | 无 | 获取当前所在频道 |

```bash
# 获取频道树
{"action": "channel.list"}

# 加入频道
{"action": "channel.join", "params": {"channelId": 1}}

# 创建临时频道
{"action": "channel.create", "params": {"parentId": 0, "name": "Test Room", "temporary": true}}
```

### message — 消息

| 命令 | 参数 | 说明 |
|------|------|------|
| `message.send` | `text`(必需) | 发送频道消息 |
| `message.sendTree` | `text`(必需) | 发送到频道树 |
| `message.sendPrivate` | `text`(必需), `session`(必需) | 发送私聊消息 |
| `message.sendImage` | `path` 或 `base64`(必需) | 发送频道图片消息 |
| `message.sendPrivateImage` | `session`(必需), `path` 或 `base64`(必需) | 发送私聊图片消息 |
| `message.listImages` | 无 | 列出包含图片的消息 |
| `message.exportImage` | `messageID` 或 `messageIndex`, `imageIndex` | 导出消息图片到临时文件 |
| `message.previewImage` | `messageID` 或 `messageIndex`, `imageIndex` | 打开消息图片预览 overlay |
| `message.history` | `limit`(50) | 获取消息历史 |
| `message.markRead` | 无 | 标记消息为已读并清除未读计数 |

```bash
# 发送消息
{"action": "message.send", "params": {"text": "Hello from AI agent!"}}

# 获取最近消息
{"action": "message.history", "params": {"limit": 10}}
```

### user — 用户操作

| 命令 | 参数 | 说明 |
|------|------|------|
| `user.list` | 无 | 列出所有在线用户 |
| `user.self` | 无 | 获取自身用户信息 |
| `user.info` | `session`(必需) | 获取指定用户信息 |
| `user.kick` | `session`(必需), `reason`(可选) | 踢出用户 |
| `user.ban` | `session`(必需), `reason`(可选) | 封禁用户 |
| `user.setVolume` | `session`(必需), `volume`(必需, 0.0-4.0) | 设置用户音量 |
| `user.setLocalMute` | `session`(必需), `muted`(可选) | 切换或设置本地静音 |
| `user.move` | `session`(必需), `channelId`(必需) | 移动用户到指定频道 |
| `user.serverMute` | `session`(必需), `enabled`(必需) | 管理员静音用户 |
| `user.serverDeafen` | `session`(必需), `enabled`(必需) | 管理员耳聋用户 |
| `user.stats` | `session`(必需) | 获取用户统计信息 |

```bash
# 列出所有用户
{"action": "user.list"}

# 获取自身信息
{"action": "user.self"}
```

### favourite — 收藏服务器

| 命令 | 参数 | 说明 |
|------|------|------|
| `favourite.list` | 无 | 列出所有收藏 |
| `favourite.info` | `primaryKey` 或 `hostname`(+`port`) | 获取单个收藏详情 |
| `favourite.add` | `hostname`(必需), `port`(64738), `username`, `password`, `displayName` | 添加收藏 |
| `favourite.update` | `primaryKey` 或 `hostname`(+`port`), 其余字段可选 | 更新收藏 |
| `favourite.remove` | `primaryKey` 或 `hostname`(+`port`) | 删除收藏 |
| `favourite.connect` | `primaryKey` 或 `hostname`(+`port`) | 按收藏配置直接连接 |
| `favourite.pinWidget` | `primaryKey` 或 `hostname`(+`port`) | 固定到 Widget |
| `favourite.unpinWidget` | `primaryKey` 或 `hostname`(+`port`) | 从 Widget 取消固定 |

### settings — 设置

| 命令 | 参数 | 说明 |
|------|------|------|
| `settings.get` | `key`(必需) | 读取 UserDefaults 值 |
| `settings.set` | `key`(必需), `value` | 写入 UserDefaults 值 |
| `settings.list` | `prefix`(可选) | 列出所有或指定前缀的 UserDefaults |

### state — 应用状态

| 命令 | 参数 | 说明 |
|------|------|------|
| `state.get` | 无 | 获取完整应用状态快照 |
| `state.snapshot` | 无 | `state.get` 的别名 |

返回字段包括：`isConnected`, `isConnecting`, `isReconnecting`, `reconnectAttempt`, `reconnectMaxAttempts`, `reconnectReason`, `serverDisplayName`, `unreadMessageCount`, `currentTab`, `isUserAuthenticated`, `serverName`, `channelCount`, `messageCount`, `modelItemCount`, `viewMode`, `localAudioTestRunning`, `collapsedChannelIds`, `listeningChannels`, `activeError`, `activeToast`, `pendingCertTrust`, `connectedUser`, `currentChannel`, `ui`

### app — UI / 交互状态

| 命令 | 参数 | 说明 |
|------|------|------|
| `app.get` | 无 | 获取 UI / 弹窗 / 当前视图状态 |
| `app.setTab` | `tab`(必需, `channels`/`messages`) | 切换底部 Tab |
| `app.setViewMode` | `mode`(必需, `server`/`channel`) | 切换服务器视图 / 当前频道视图 |
| `app.clearError` | 无 | 清空当前错误弹窗 |
| `app.clearToast` | 无 | 清空当前 toast |
| `app.dismissCert` | 无 | 清空待确认的证书弹窗 |
| `app.cancelConnection` | 无 | 取消当前连接 / 重连流程 |
| `app.refreshModel` | 无 | 强制刷新当前频道树模型 |

### ui — 页面级自动化

| 命令 | 参数 | 说明 |
|------|------|------|
| `ui.get` | 无 | 获取当前页面 / sheet / alert / overlay 状态 |
| `ui.open` | `target`(必需) | 打开页面或 sheet。除基础目标外，还支持 `notificationSettings` / `ttsSettings` / `audioTransmissionSettings` / `advancedAudioSettings` / `certificateSettings` / `logSettings` / `about` / `aboutLicense` / `aboutAcknowledgements` / `audioPluginMixer` / `pluginBrowser` / `pluginEditor` / `channelProperties` / `channelEditACL` / `channelACLAcls` / `channelACLGroups` / `aclEntryEdit` / `groupEntryEdit` / `channelDelete` / `banAdd` / `certificateExportPassword` / `certificateDelete` / `favouriteDelete` |
| `ui.dismiss` | `target`(可选) | 关闭当前或指定 UI。除 `toast` / `error` / `certTrust` / `imagePreview` 外，也支持上述各 sheet / alert，例如 `audioPluginMixer` / `pluginBrowser` / `pluginEditor` / `imageSendConfirm` / `channelDelete` / `banAdd` / `certificateExportPassword` / `certificateDelete` / `preferencesLanguageChanged` / `logReset` |
| `ui.back` | 无 | 导航返回 |
| `ui.root` | 无 | 导航回根页面 |

### plugin — 插件混音器语义控制

| 命令 | 参数 | 说明 |
|------|------|------|
| `plugin.listTracks` | 无 | 列出所有插件轨道及当前链路 |
| `plugin.get` | `trackKey` 或 `session` | 获取单个轨道链路 |
| `plugin.available` | 无 | 列出可添加的 AU / VST3 插件与当前扫描路径 |
| `plugin.scanPaths` | 无 | 获取自定义 VST3 扫描路径 |
| `plugin.addScanPath` | `path`(必需) | 增加自定义扫描路径 |
| `plugin.removeScanPath` | `path`(必需) | 删除自定义扫描路径 |
| `plugin.buffer` | 无 | 获取插件 host buffer frames |
| `plugin.setBuffer` | `frames`(必需) | 设置插件 host buffer frames |
| `plugin.add` | `trackKey` 或 `session`, `identifier`(必需) | 往轨道追加插件；`identifier` 建议来自 `plugin.available` |
| `plugin.remove` | `trackKey` 或 `session`, `pluginID` 或 `index` | 删除轨道上的插件 |
| `plugin.move` | `trackKey` 或 `session`, `pluginID` 或 `index`, `toIndex`(必需) | 调整插件顺序 |
| `plugin.setBypass` | `trackKey` 或 `session`, `pluginID` 或 `index`, `bypassed` | 设置 bypass |
| `plugin.setGain` | `trackKey` 或 `session`, `pluginID` 或 `index`, `gain` | 设置 stage gain |
| `plugin.load` | `trackKey` 或 `session`, `pluginID` 或 `index` | 主动加载插件实例 |
| `plugin.unload` | `trackKey` 或 `session`, `pluginID` 或 `index` | 卸载插件实例 |
| `plugin.parameters` | `trackKey` 或 `session`, `pluginID` 或 `index` | 获取自动化参数列表 |
| `plugin.setParameter` | `trackKey` 或 `session`, `pluginID` 或 `index`, `parameterID`, `value` | 设置插件参数 |
| `plugin.presets` | `trackKey` 或 `session`, `pluginID` 或 `index` | 列出该插件已保存 preset |
| `plugin.savePreset` | `trackKey` 或 `session`, `pluginID` 或 `index`, `name` | 保存 preset |
| `plugin.applyPreset` | `trackKey` 或 `session`, `pluginID` 或 `index`, `presetID` | 应用 preset |
| `plugin.deletePreset` | `pluginIdentifier`(必需), `presetID`(必需) | 删除 preset |
| `plugin.setSidechain` | `trackKey` 或 `session`, `pluginID` 或 `index`, `source`(必需) | 设置插件侧链源（`"none"` 清空） |
| `plugin.getSidechain` | `trackKey` 或 `session`, `pluginID` 或 `index` | 获取插件侧链源配置 |

### server — 管理页数据

| 命令 | 参数 | 说明 |
|------|------|------|
| `server.getBanList` | 无 | 请求并返回封禁列表 |
| `server.setBanList` | `entries`(必需) | 用完整列表覆盖服务器封禁列表 |
| `server.addBan` | `address`(必需), `mask`, `username`, `certHash`, `reason`, `start`, `duration` | 追加封禁项 |
| `server.removeBan` | `index` 或 `address` | 删除封禁项 |
| `server.getRegisteredUsers` | 无 | 请求并返回注册用户列表 |

### certificate — 身份证书

| 命令 | 参数 | 说明 |
|------|------|------|
| `certificate.list` | 无 | 列出所有本地证书 |
| `certificate.generate` | `name`(必需), `email` | 生成新证书 |
| `certificate.delete` | `id` 或 `name` | 删除证书 |
| `certificate.import` | `path`(必需), `password` | 从本地路径导入 `.p12` |
| `certificate.export` | `id` 或 `name`, `password` | 导出到临时文件并返回路径 |

### log — 日志控制

| 命令 | 参数 | 说明 |
|------|------|------|
| `log.setLevel` | `category`(必需), `level`(必需) | 设置分类日志等级 |
| `log.setEnabled` | `category`(必需), `enabled`(必需) | 开关分类日志 |
| `log.getConfig` | 无 | 获取完整日志配置 |
| `log.setGlobalEnabled` | `enabled`(必需) | 全局日志开关 |
| `log.setFilePersistence` | `enabled`(必需) | 开关日志文件持久化 |
| `log.recent` | `limit`(200), `category`, `minimumLevel` | 获取最近日志缓冲 |
| `log.clearRecent` | 无 | 清空最近日志缓冲 |
| `log.marker` | `message`, `category`, `level` | 写入调试标记日志 |
| `log.stream` | `enabled`(true), `categories`, `minimumLevel` | 为当前 websocket 连接开启/关闭实时日志流 |
| `log.streamStatus` | 无 | 获取当前连接的日志流订阅状态 |
| `log.files` | 无 | 获取日志文件列表与当前文件路径 |
| `log.export` | 无 | 导出当前日志文件到临时合并文件 |
| `log.reset` | 无 | 重置日志配置 |

```bash
# 开启 verbose 级别音频日志
{"action": "log.setLevel", "params": {"category": "Audio", "level": "verbose"}}

# 查看当前配置
{"action": "log.getConfig"}

# 获取最近 100 条音频错误日志
{"action": "log.recent", "params": {"limit": 100, "category": "Audio", "minimumLevel": "warning"}}

# 为当前 websocket 连接开启实时日志流
{"action": "log.stream", "params": {"enabled": true, "categories": ["Audio", "Connection"], "minimumLevel": "debug"}}
```

### help — 帮助

| 命令 | 参数 | 说明 |
|------|------|------|
| `help.actions` | 无 | 列出所有可用命令 |

## 事件推送

连接后自动接收以下事件：

| 事件 | 触发时机 | data 字段 |
|------|----------|-----------|
| `connection.opened` | 连接成功 | `connected: true` |
| `connection.closed` | 连接断开 | `connected: false` |
| `connection.connecting` | 正在连接 | — |
| `connection.error` | 连接错误 | `title`, `message` |
| `connection.udpStatus` | UDP 传输状态变化 | `state` |
| `audio.restarted` | 音频引擎重启 | — |
| `audio.error` | 音频错误 | `error` |
| `app.toast` | App 内 toast / banner 更新 | `message`, `type`, `jumpToMessages` |
| `message.sendFailed` | 文本消息发送失败 | `reason` |
| `channel.listeningAdded` | 增加监听频道 | `channelIds` |
| `channel.listeningRemoved` | 移除监听频道 | `channelIds` |
| `log.entry` | 实时日志流推送 | `timestamp`, `category`, `level`, `message`, `file`, `function`, `line` |
| `ui.changed` | 页面 / sheet / alert / overlay 状态变化 | `currentScreen`, `presentedSheet`, `presentedAlert`, `visibleOverlays` |

## 自动化测试示例

### Bash 脚本（websocat）

```bash
#!/bin/bash
# test_connection.sh — 测试连接流程

WS="ws://localhost:54296"

echo '连接到服务器...'
echo '{"id":"1","action":"connection.connect","params":{"hostname":"mumble.example.com"}}' | websocat -n1 $WS

sleep 3

echo '检查连接状态...'
echo '{"id":"2","action":"connection.status"}' | websocat -n1 $WS

echo '获取频道列表...'
echo '{"id":"3","action":"channel.list"}' | websocat -n1 $WS

echo '断开连接...'
echo '{"id":"4","action":"connection.disconnect"}' | websocat -n1 $WS
```

### Python 脚本

```python
import asyncio
import websockets
import json

async def test_mumble():
    async with websockets.connect("ws://localhost:54296") as ws:
        # 获取帮助
        await ws.send(json.dumps({"action": "help.actions"}))
        print(await ws.recv())

        # 检查状态
        await ws.send(json.dumps({"action": "state.get"}))
        state = json.loads(await ws.recv())
        print(f"Connected: {state['data']['isConnected']}")

        # 获取收藏列表
        await ws.send(json.dumps({"action": "favourite.list"}))
        favs = json.loads(await ws.recv())
        print(f"Favourites: {favs['data']}")

asyncio.run(test_mumble())
```

### AI Agent 集成

AI agent 可通过 `websocat` CLI 与 App 交互：

```bash
# 发送命令并获取响应
echo '{"action":"state.get"}' | websocat -n1 ws://localhost:54296

# 持续监听事件 / 实时日志
websocat ws://localhost:54296
```

## 文件结构

| 文件 | 位置 | 职责 |
|------|------|------|
| `MUTestServer.swift` | `Source/Classes/SwiftUI/Core/` | NWListener WebSocket 服务器、连接管理、事件推送 |
| `MUTestCommandRouter.swift` | `Source/Classes/SwiftUI/Core/` | JSON 命令路由、所有域处理器 |

## 安全说明

- 测试服务器 **仅在 `#if DEBUG` 下编译**，Release 构建中不存在
- 监听 `localhost:54296`，仅本机可访问
- 无身份验证（Debug 工具，不面向生产环境）
- iOS 模拟器可直接通过 `localhost` 访问；真机需要 USB 端口转发或同网络

## 扩展

添加新命令：

1. 在 `MUTestCommandRouter.swift` 中新增域处理方法或在已有域中添加 case
2. 更新 `handleHelp` 的命令列表
3. 更新本文档
