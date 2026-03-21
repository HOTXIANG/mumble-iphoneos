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
│ settings   │ state │ log        │
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
| `audio.restart` | 无 | 重启音频引擎 |
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
| `channel.join` | `channelId`(必需) | 加入指定频道 |
| `channel.create` | `parentId`(必需), `name`(必需), `temporary`(false) | 创建频道 |
| `channel.remove` | `channelId`(必需) | 删除频道 |
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
| `message.history` | `limit`(50) | 获取消息历史 |

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
| `favourite.add` | `hostname`(必需), `port`(64738), `username`, `password`, `displayName` | 添加收藏 |
| `favourite.remove` | `hostname`(必需), `port`(64738) | 删除收藏 |

### settings — 设置

| 命令 | 参数 | 说明 |
|------|------|------|
| `settings.get` | `key`(必需) | 读取 UserDefaults 值 |
| `settings.set` | `key`(必需), `value` | 写入 UserDefaults 值 |

### state — 应用状态

| 命令 | 参数 | 说明 |
|------|------|------|
| `state.get` | 无 | 获取完整应用状态快照 |

返回字段包括：`isConnected`, `isConnecting`, `isReconnecting`, `serverDisplayName`, `unreadMessageCount`, `currentTab`, `isUserAuthenticated`, `serverName`, `channelCount`, `messageCount`

### log — 日志控制

| 命令 | 参数 | 说明 |
|------|------|------|
| `log.setLevel` | `category`(必需), `level`(必需) | 设置分类日志等级 |
| `log.setEnabled` | `category`(必需), `enabled`(必需) | 开关分类日志 |
| `log.getConfig` | 无 | 获取完整日志配置 |
| `log.setGlobalEnabled` | `enabled`(必需) | 全局日志开关 |
| `log.reset` | 无 | 重置日志配置 |

```bash
# 开启 verbose 级别音频日志
{"action": "log.setLevel", "params": {"category": "Audio", "level": "verbose"}}

# 查看当前配置
{"action": "log.getConfig"}
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

# 持续监听事件
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
