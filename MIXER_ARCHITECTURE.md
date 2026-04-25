# Mumble Audio Mixer 架构文档

最新状态请先看 `docs/CURRENT_STATUS.md`。当前音频生命周期要求：普通欢迎页不进入 VoiceChat/不调用麦克风；只有首次 VAD onboarding、Input Setting、Mixer、服务器连接会启动本地输入。AudioUnit 现在在输入/输出回调绑定后才 `startDevice()`，避免只进入语音模式但麦克风回调未运行。

## 🎚️ 音频信号流

### 输入链路（Input Chain）

```
┌─────────────┐
│ Microphone  │ 硬件麦克风
│   (ADC)     │
└──────┬──────┘
       │ short* (48kHz, 1-2ch)
       ↓
┌─────────────────────────────┐
│ MKAudioDevice::inputCallback│ 音频设备回调
└──────┬──────────────────────┘
       │
       ↓
┌──────────────────────────────────┐
│ MKAudioInput::                   │
│ addMicrophoneDataWithBuffer      │ 累积音频帧
└──────┬───────────────────────────┘
       │ 累积到 frameSize (480 samples @ 48kHz = 10ms)
       │ 重采样（如果需要）
       ↓
┌──────────────────────────────────┐
│ MKAudioInput::                   │
│ processAndEncodeAudioFrame       │ 处理和编码
└──────┬───────────────────────────┘
       │
       ├─→ Speex Preprocessor
       │   ├─ VAD (Voice Activity Detection)
       │   ├─ Denoise (降噪)
       │   └─ Dereverb (去混响)
       │
       ├─→ Gain Adjustment (增益调整)
       │   └─ amplification * micBoost
       │
       ├─→ 【插件插入点 1】
       │   _inputTrackProcessor(short*, frameSize, channels, sampleRate)
       │   ↓
       │   MKAudioInputDSPProcess
       │   ↓
       │   MKAudioRunAudioUnitChain (AU 插件链)
       │
       ├─→ Peak Detection (电平检测)
       │
       └─→ Opus/Speex Encoder
           └─→ Network (UDP)
```

当前 Opus 默认启用 constrained VBR、DTX、in-band FEC，并设置默认丢包预期；旧 Weak Network Mode 已删除，不再通过独立 UI 或 WebSocket 命令控制。

### 输出链路（Output Chain）

```
Network (UDP)
       │
       ↓
┌──────────────────────────────────┐
│ Opus/Speex Decoder               │ 解码器
└──────┬───────────────────────────┘
       │ float* (48kHz, 1-2ch)
       ↓
┌──────────────────────────────────┐
│ MKAudioOutputUser::buffer        │ 每用户缓冲区
└──────┬───────────────────────────┘
       │
       ├─→ 【插件插入点 2】Per-User Track
       │   _remoteTrackProcessors[sessionID](float*, nsamp, channels, freq)
       │   ↓
       │   MKAudioRemoteTrackDSPProcess
       │   ↓
       │   MKAudioRunAudioUnitChain (AU 插件链)
       │
       ├─→ Volume Control (音量控制)
       │   └─ sessionVolumes[sessionID] * globalVolume
       │
       └─→ Mix to Master Bus
           ↓
┌──────────────────────────────────┐
│ MKAudioOutput::mixFrames         │ 混音器
└──────┬───────────────────────────┘
       │ float* mixBuffer (所有用户混音后)
       │
       ├─→ 【插件插入点 3】Master Bus
       │   _remoteBusProcessor(float*, nsamp, channels, freq)
       │   ↓
       │   MKAudioRemoteBusDSPProcess
       │   ↓
       │   MKAudioRunAudioUnitChain (AU 插件链)
       │
       ├─→ Float to Short Conversion
       │   └─ Clipping: [-1.0, 1.0] → [-32768, 32767]
       │
       └─→ short* (48kHz, 1-2ch)
           ↓
┌──────────────────────────────────┐
│ MKAudioDevice::outputCallback    │ 音频设备回调
└──────┬───────────────────────────┘
       │
       ↓
┌─────────────┐
│  Speaker    │ 硬件扬声器
│   (DAC)     │
└─────────────┘
```

## 🎛️ 插件插入点详解

### 插入点 1: Input Track（输入轨道）
- **位置**: Speex 预处理之后，编码器之前
- **格式**: `short*` (16-bit PCM)
- **用途**: 处理本地麦克风输入
- **典型插件**: 压缩器、EQ、降噪、去齿音
- **API**: `MKAudio::setInputTrackAudioUnitChain:`

### 插入点 2: Remote Track（远程轨道，每用户）
- **位置**: 解码器之后，混音之前
- **格式**: `float*` (32-bit float)
- **用途**: 独立处理每个远程用户的音频
- **典型插件**: EQ、压缩器、门限、音高校正
- **API**: `MKAudio::setRemoteTrackAudioUnitChain:forSession:`

### 插入点 3: Master Bus（主总线）
- **位置**: 混音之后，输出之前
- **格式**: `float*` (32-bit float)
- **用途**: 处理最终混音
- **典型插件**: 限制器、混响、立体声增强、母带处理
- **API**: `MKAudio::setRemoteBusAudioUnitChain:`

## 🔧 AU 插件处理流程

### MKAudioRunAudioUnitChain 函数

```c
static void MKAudioRunAudioUnitChain(
    float *samples,          // 输入/输出缓冲区（interleaved）
    NSUInteger frameCount,   // 帧数（通常是 480 @ 48kHz）
    NSUInteger channels,     // 声道数（1 或 2）
    NSUInteger sampleRate,   // 采样率（48000）
    NSArray *audioUnits      // AU 插件数组
)
```

**处理步骤**：
1. 创建工作缓冲区（interleaved float*）
2. 复制输入数据到工作缓冲区
3. 对每个 AU 插件：
   a. 尝试 interleaved 格式
   b. 失败则尝试 non-interleaved 格式
   c. 创建 AudioBufferList
   d. 调用 AU render block
   e. 复制输出到工作缓冲区
4. 复制最终结果回输入缓冲区

### 格式自适应

| 格式 | 数据布局 | AudioBufferList | 适用插件 |
|------|---------|----------------|---------|
| Interleaved | `[L0,R0,L1,R1,...]` | 1 buffer, N channels | 大多数插件 |
| Non-interleaved | `[L0,L1,...],[R0,R1,...]` | N buffers, 1 channel | 某些专业插件 |

## 🎯 UI 层集成

### AudioPluginMixerView

**轨道类型**：
- `input`: 输入轨道
- `remoteBus`: 主总线
- `remoteSession:N`: 远程用户轨道（N = session ID）

**插件链管理**：
```swift
pluginChainByTrack: [String: [TrackPlugin]]
// 例如:
// "input" → [EQ, Compressor]
// "remoteBus" → [Limiter, Reverb]
// "remoteSession:123" → [Gate, EQ]
```

**同步到 MKAudio**：
```swift
func syncAudioUnitDSPChainForTrackKey(_ key: String) {
    if key == "input" {
        MKAudio.shared().setInputTrackAudioUnitChain(activeAudioUnitChain(for: key))
    } else if key == "remoteBus" {
        MKAudio.shared().setRemoteBusAudioUnitChain(activeAudioUnitChain(for: key))
    } else if let session = parseRemoteSessionID(from: key) {
        MKAudio.shared().setRemoteTrackAudioUnitChain(
            activeAudioUnitChain(for: key),
            forSession: UInt(session)
        )
    }
}
```

## 🐛 常见问题诊断

### 问题 1: 插件加载但无效果

**可能原因**：
1. ✅ 插件被 bypass 了
2. ✅ 插件格式不匹配（已修复：自适应格式）
3. ✅ AU render 失败（检查日志）
4. ❌ 插件链没有被正确设置到 MKAudio
5. ❌ 插件参数全部为默认值（无明显效果）

**诊断步骤**：
```bash
# 1. 检查 Console.app 日志
# 搜索: "MKAudio: AU render failed"
# 搜索: "MKAudio: Interleaved format failed"

# 2. 检查 DSP 状态面板
# - Input Peak / Output Peak 是否有变化？
# - AU Status 是否为 "OK (noErr)"？

# 3. 检查插件状态
# - 是否显示 "Loaded"？
# - 参数数量是否正确？
# - Bypass 是否关闭？
```

### 问题 2: 单声道插件报错 -3000

**已修复**：智能格式检测
- 优先尝试 interleaved
- 失败则尝试 non-interleaved
- 正确创建 AudioBufferList

### 问题 3: 立体声插件有声音但无效果

**已修复**：数据流正确性
- Interleaved: 直接复制
- Non-interleaved: 解交织 + 重新交织

## 📊 性能考虑

### 实时线程约束
- **禁止**: 内存分配、锁、ObjC 消息发送
- **当前状态**: 使用 `calloc`/`free`（需要优化）
- **TODO**: 预分配缓冲区池

### 延迟
- **Input Track**: ~10ms (1 frame @ 48kHz)
- **Remote Track**: ~10ms per user
- **Master Bus**: ~10ms
- **总延迟**: ~30-50ms（可接受）

## 🔮 未来优化

1. **预分配缓冲区**：消除实时线程的内存分配
2. **SIMD 优化**：使用 vDSP 加速格式转换
3. **并行处理**：多个 Remote Track 可以并行处理
4. **零拷贝**：某些情况下可以避免数据复制

## 🔌 DAW-Style 侧链路由（Sidechain Routing）

### 架构概述

侧链路由功能允许 AU 插件通过 `inputBusses[1]` 接收来自其他轨道的预衰减（pre-fader）音频信号作为控制信号。这实现了：

- **压缩器 Ducking**: 当特定用户说话时，自动降低其他音频的音量
- **门限触发**: 使用外部信号触发噪声门
- **动态 EQ**: 基于外部信号的频率响应调整

### 侧chain 信号源类型

| 源类型 | 键值 | 描述 |
|--------|------|------|
| 无 | `none` | 不启用侧链（默认） |
| 本地麦克风 | `input` | 本地麦克风信号（Int16→Float 转换后，预处理后） |
| 远程用户 | `session:<N>` | 远程用户 N 的解码音频（每用户，混音前） |
| 主总线 1 | `masterBus1` | 主总线 1 混音信号（混音后，总线插件前） |
| 主总线 2 | `masterBus2` | 主总线 2 混音信号（混音后，总线插件前） |

### 信号流

```
                    ┌─────────────────────────────────────────┐
                    │          Sidechain Buffer Pool           │
                    │  (MKAudioOutput,每 mixFrames 周期填充)    │
                    │                                         │
                    │  "input"      → [float*] 麦克风预 AU     │
                    │  "session:5"  → [float*] 用户 5 预 AU     │
                    │  "masterBus1" → [float*] 总线 1 预 AU     │
                    └──────────┬──────────────────────────────┘
                               │ 读取 by AU sidechain bus
    ┌──────────────────────────┼──────────────────────────┐
    │                          ▼                          │
    │  Master Bus 1 Track                                 │
    │  ┌─────────┐   ┌──────────────────┐   ┌─────────┐ │
    │  │ Mixed   │──▶│ Compressor (AU)  │──▶│ Output  │ │
    │  │ Bus 1   │   │ SC: "session:5"  │   │         │ │
    │  └─────────┘   │ bus0: 混音信号    │   └─────────┘ │
    │                 │ bus1: 用户 5 信号  │                │
    │                 └──────────────────┘                │
    └─────────────────────────────────────────────────────┘
```

### 实现细节

**Layer 1: 侧链缓冲池（MKAudioOutput.m）**
- 预分配 C 语言数组存储音频（`struct MKSidechainSlot`）
- 每 `mixFrames:amount:` 周期填充：
  - 每用户 pre-fader 缓冲区（解码后，插件前）
  - 主总线 1/2 pre-fader 缓冲区（混音后，总线插件前）
- 原子 ping-pong 双缓冲用于输入轨道信号（跨输入/输出线程）

**Layer 2-3: StageHost AVAudioEngine 接线（Rack.swift）**
- 检查 AU 是否有 `inputBusses.count > 1`
- 创建第二个 `AVAudioSourceNode` 连接到 AU bus 1
- 侧链提供者回调从缓冲池读取数据

**Layer 4: 桥接层（Bridge.m）**
- ObjC 桥接类包装 `MKAudioOutput` 查找为 Swift 闭包
- MRC 安全：不持有音频指针，仅传递原始指针

**Layer 5: 持久化与 UI（AudioPluginMixerView.swift）**
- 每插件槽位独立侧链源配置
- 可视化拾取器：None / Input / 活跃用户 / Master Bus 1/2
- "SC" 徽章指示（橙色=激活，灰色=未激活）

### WebSocket 测试命令

```bash
# 设置侧链源
{"action": "plugin.setSidechain", "params": {"trackKey": "masterBus1", "index": 0, "source": "session:5"}}

# 获取侧链源
{"action": "plugin.getSidechain", "params": {"trackKey": "masterBus1", "index": 0}}

# 查看轨道插件链（包含 sidechainSource）
{"action": "plugin.listTracks"}
```

### 边缘情况处理

- **AU 无侧链总线**: `inputBusses.count <= 1` → UI 隐藏，不接线
- **源用户断开**: 源键失效 → 提供者返回 nil → 填充静音
- **源自引用**: 允许用户选择自己轨道作为侧链源（pre-fader 反馈，无无限循环）
- **VAD 静音**: 源停止说话 → 缓冲未填充 → 填充静音（正确行为）

---

## 📝 测试清单

- [ ] 单声道插件（压缩器、门限）
- [ ] 立体声插件（混响、延迟）
- [ ] 插件链（多个插件串联）
- [ ] 参数实时调整
- [ ] Bypass 开关
- [ ] 预设保存/加载
- [ ] 多用户场景（Remote Track）
- [ ] 高负载场景（多个插件 + 多个用户）
- [ ] 侧链路由（压缩器 ducking）
- [ ] 侧链源切换（None → Input → Session → Master Bus）
- [ ] 自引用侧链（用户选择自己轨道）

---

**最后更新**: 2026-03-23
**架构版本**: v2.1 (DAW-Style Sidechain Routing)
**状态**: ✅ 链路正确，格式自适应已实现，侧链路由完整实现
