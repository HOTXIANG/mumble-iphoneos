# Mumble Audio Mixer 架构文档

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

## 📝 测试清单

- [ ] 单声道插件（压缩器、门限）
- [ ] 立体声插件（混响、延迟）
- [ ] 插件链（多个插件串联）
- [ ] 参数实时调整
- [ ] Bypass 开关
- [ ] 预设保存/加载
- [ ] 多用户场景（Remote Track）
- [ ] 高负载场景（多个插件 + 多个用户）

---

**最后更新**: 2026-03-16
**架构版本**: v2.0
**状态**: ✅ 链路正确，格式自适应已实现
