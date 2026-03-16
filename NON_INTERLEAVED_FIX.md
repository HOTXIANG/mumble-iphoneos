# 🔧 Non-Interleaved 格式和单声道插件修复（2026-03-16 最终版）

## 问题 1: Pro-Q 4（立体声）无声音

### 症状
```
MKAudio: Remote Bus - processing 1 AU(s), inputPeak=0.002
MKAudio: Processing AU 'Pro-Q 4', interleaved=0, channels=2
MKAudio: AU 'Pro-Q 4' rendered successfully, peak=0.000, channels=2, interleaved=0
MKAudio: Remote Bus - AU chain processed, outputPeak=0.000
```
- 有输入（inputPeak=0.002）
- **无输出（outputPeak=0.000）**
- 插件界面也显示无输入

### 根本原因

**Bug 1: 输出缓冲区分配错误**
```c
// 错误的代码（之前）
float *outputBuffer = (float *)calloc(sampleCount, sizeof(float));
// sampleCount = frameCount * channels

// Non-interleaved 模式下：
outABL->mBuffers[0].mData = outputBuffer + (0 * frameCount);
outABL->mBuffers[1].mData = outputBuffer + (1 * frameCount);
//                           ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
//                           两个声道共享同一个 buffer！
//                           第二个声道会覆盖第一个声道的数据！
```

**Bug 2: 输出数据重新交织错误**
```c
// 错误的假设
workBuffer[frame * channels + ch] = outputBuffer[ch * frameCount + frame];
//                                   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
//                                   假设数据在 outputBuffer 中是连续的
//                                   但实际上数据已经被覆盖了！
```

### 修复方案

**正确的缓冲区分配**：
```c
// 为每个声道分配独立的缓冲区
float **outputBuffers = (float **)calloc(channels, sizeof(float *));
for (NSUInteger ch = 0; ch < channels; ch++) {
    outputBuffers[ch] = (float *)calloc(frameCount, sizeof(float));
}

// AudioBufferList 指向独立的缓冲区
outABL->mBuffers[0].mData = outputBuffers[0];  // 声道 0
outABL->mBuffers[1].mData = outputBuffers[1];  // 声道 1
```

**正确的重新交织**：
```c
// 从独立的缓冲区读取数据
for (NSUInteger frame = 0; frame < frameCount; frame++) {
    for (NSUInteger ch = 0; ch < channels; ch++) {
        workBuffer[frame * channels + ch] = outputBuffers[ch][frame];
        //                                   ^^^^^^^^^^^^^^^^^^^^^^
        //                                   从独立的缓冲区读取
    }
}
```

## 问题 2: CLA-2A（单声道）加载失败 (-3000)

### 症状
```
状态：失败 - Audio Unit 宿主兼容错误（-3000）
```

### 根本原因

**Remote Bus 被硬编码为 2 channels**：
```swift
private func channelCount(for trackKey: String) -> UInt {
    if trackKey == "remoteBus" || trackKey.hasPrefix("remoteSession:") {
        return 2  // ← 强制立体声！
    }
    return 2
}
```

但 **CLA-2A mono 只支持 1 channel**，导致格式不匹配。

### 修复方案

**声道数回退策略**：
```swift
private func instantiateAudioUnitWithFallback(...) async -> String? {
    // 1. 先尝试 requiredChannels（通常是 2）
    if let error = await tryInstantiateWithChannels(..., channels: requiredChannels, ...) {
        // 2. 如果失败且 requiredChannels == 2，尝试 1 channel
        if requiredChannels == 2 {
            NSLog("MKAudio: Failed with 2 channels, trying 1 channel (mono)")
            return await tryInstantiateWithChannels(..., channels: 1, ...)
        }
        return error
    }
    return nil
}
```

**工作流程**：
1. Remote Bus 默认尝试 2 channels（立体声）
2. 如果插件不支持，自动回退到 1 channel（单声道）
3. 单声道插件成功加载
4. 运行时自动处理声道转换（mono → stereo）

## 测试步骤

### 1. 测试 Pro-Q 4（立体声，non-interleaved）

**操作**：
1. 重新构建 Mumble
2. 打开 Mixer
3. 选择 Remote Bus
4. 添加 Pro-Q 4
5. 连接服务器，听其他用户说话

**预期日志**：
```
MKAudio: Remote Bus - processing 1 AU(s), inputPeak=0.XXX
MKAudio: Processing AU 'Pro-Q 4', interleaved=0, channels=2
MKAudio: AU 'Pro-Q 4' rendered successfully, peak=0.XXX, channels=2, interleaved=0
                                              ^^^^^^^^ 应该有值！
MKAudio: Remote Bus - AU chain processed, outputPeak=0.XXX
                                          ^^^^^^^^ 应该有值！
```

**预期结果**：
- ✅ 能听到声音
- ✅ Pro-Q 4 界面显示音频输入
- ✅ 调整 EQ 参数有效果

### 2. 测试 CLA-2A（单声道）

**操作**：
1. 选择 Remote Bus
2. 添加 CLA-2A mono

**预期日志**：
```
MKAudio: Failed to load AU with 2 channels, trying 1 channel (mono)
MKAudio: AU loaded successfully with 1 channels (default)
```

**预期结果**：
- ✅ 插件成功加载（不再显示 -3000 错误）
- ✅ 能听到声音
- ✅ 压缩效果正常工作

### 3. 测试插件链

**操作**：
1. 在 Remote Bus 添加多个插件：
   - Pro-Q 4（立体声，non-interleaved）
   - CLA-2A（单声道）
   - AUReverb（立体声，interleaved）

**预期结果**：
- ✅ 所有插件都能加载
- ✅ 声音经过所有插件处理
- ✅ 没有音频阻断

## 技术细节

### Non-Interleaved 格式的正确处理

**内存布局**：
```
Interleaved (1 buffer):
[L0, R0, L1, R1, L2, R2, ...]

Non-Interleaved (2 buffers):
Buffer 0: [L0, L1, L2, ...]
Buffer 1: [R0, R1, R2, ...]
```

**缓冲区分配**：
```c
// Interleaved
float *buffer = calloc(frameCount * channels, sizeof(float));

// Non-Interleaved
float **buffers = calloc(channels, sizeof(float *));
for (ch = 0; ch < channels; ch++) {
    buffers[ch] = calloc(frameCount, sizeof(float));
}
```

### 声道数自适应

**策略**：
1. **优先立体声**：大多数现代插件支持立体声
2. **回退单声道**：某些老插件或专业插件只支持单声道
3. **自动转换**：运行时自动处理 mono ↔ stereo 转换

**转换逻辑**（在 MKAudioOutput::mixFrames 中）：
```c
// Mono → Stereo
if (sourceChannels == 1 && outputChannels == 2) {
    output[L] = input[0];
    output[R] = input[0];  // 复制到两个声道
}

// Stereo → Mono
if (sourceChannels == 2 && outputChannels == 1) {
    output[0] = (input[L] + input[R]) * 0.5f;  // 混合
}
```

## 性能影响

### Non-Interleaved 格式
- **内存使用**：增加（每个声道独立缓冲区）
- **CPU 使用**：略增（需要解交织/重新交织）
- **兼容性**：提升（支持更多插件）

### 声道数回退
- **加载时间**：略增（可能需要两次尝试）
- **运行时性能**：无影响（只在加载时检测）
- **兼容性**：大幅提升（支持单声道插件）

## 已知限制

1. **采样率**：固定 48kHz（Mumble 标准）
2. **声道数**：支持 1-2 channels
3. **格式检测**：基于 AU 的 inputBusses[0].format
4. **内存分配**：仍在实时线程中（待优化）

## 下一步优化

1. **预分配缓冲区池**：消除实时线程的内存分配
2. **SIMD 优化**：使用 vDSP 加速格式转换
3. **缓存 AU 格式**：避免每次读取 format 属性
4. **并行处理**：多个 Remote Track 可以并行处理

---

**修复日期**: 2026-03-16
**影响插件**: Pro-Q 4, CLA-2A, 以及所有 non-interleaved 和单声道插件
**状态**: ✅ 已修复，待用户测试
**文件**:
- `MumbleKit/src/MKAudio.m`
- `Source/Classes/SwiftUI/Preferences/PreferencesView.swift`
