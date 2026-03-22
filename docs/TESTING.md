# Mumble WebSocket 自动化测试服务器

## 概述

Mumble 内嵌了一个 WebSocket 测试服务器（`MUTestServer`），仅在 `DEBUG` 构建中编译。AI agent 或自动化脚本可通过 WebSocket 连接到运行中的 App，远程执行所有功能并验证结果。

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
