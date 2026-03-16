# 🔍 Mumble Audio Mixer 诊断指南

## 问题：插件加载但没有效果

### 快速检查清单

#### 1. 检查插件状态
- [ ] 插件显示为 "Loaded"（不是 "Failed" 或 "Unloaded"）
- [ ] Bypass 开关是否关闭（绿色 = 激活，灰色 = bypass）
- [ ] 插件是否在正确的轨道上（Input/Remote Bus/Remote Session）

#### 2. 检查 DSP 状态面板
- [ ] Input Peak / Output Peak 是否有变化？
- [ ] AU Status 是否显示 "OK (noErr)"？
- [ ] 如果显示错误码，记录下来

#### 3. 检查 Console.app 日志

**打开 Console.app**：
1. 打开 `/Applications/Utilities/Console.app`
2. 在搜索框输入：`Mumble`
3. 开始录音或播放音频
4. 查找以下关键日志：

**成功的日志**：
```
MKAudio: Interleaved format succeeded for AU 'Plugin Name'
MKAudio: AU 'Plugin Name' rendered successfully, peak=0.XXX, channels=2, interleaved=1
```

**失败的日志**：
```
MKAudio: Interleaved format failed for AU 'Plugin Name', trying non-interleaved
MKAudio: Both formats failed for AU 'Plugin Name', skipping
MKAudio: AU 'Plugin Name' render failed, status=-3000
```

### 常见问题和解决方案

#### 问题 1: 插件显示 "Failed - Audio Unit 格式不支持错误（-3000）"

**原因**：插件不支持当前的音频格式

**解决方案**：
1. ✅ 已实现自动格式检测（interleaved → non-interleaved）
2. 检查 Console.app 是否显示 "Both formats failed"
3. 如果是，该插件可能不兼容 48kHz 采样率
4. 尝试其他插件

#### 问题 2: 插件加载成功但听不到效果

**可能原因**：

**A. 插件参数为默认值**
- 某些插件默认参数不会产生明显效果
- **解决**：调整插件参数，观察是否有变化

**B. 插件被 bypass 了**
- 检查插件行的 bypass 开关
- **解决**：点击 bypass 开关，确保插件激活

**C. 插件增益过低**
- 检查 Stage Gain 滑块
- **解决**：调整 Stage Gain 到 1.0 或更高

**D. 插件链没有被应用**
- 检查 "Live Preview" 开关是否打开
- **解决**：确保 "Live Preview" 开关打开

**E. 音频没有经过该轨道**
- Input Track: 需要你说话（麦克风输入）
- Remote Bus: 需要有远程用户说话
- Remote Session: 需要特定用户说话
- **解决**：确保有音频信号经过该轨道

#### 问题 3: 单声道插件弹出安全性警告

**警告内容**：
```
使用请求的音频单元需要降低"Mumble"的安全性设置。确定要继续吗？
```

**原因**：某些 AU 插件需要特殊权限（网络访问、文件访问等）

**解决方案**：
1. 点击"继续"允许插件加载
2. 如果仍然失败，打开"系统设置 → 隐私与安全性"
3. 查找 Mumble 相关的权限请求并允许
4. 重启 Mumble

#### 问题 4: 立体声插件有声音但无效果

**已修复**：数据流正确性
- 检查 Console.app 日志
- 应该看到 "AU 'Plugin Name' rendered successfully"
- 如果看到 "render failed"，记录错误码

### 详细诊断步骤

#### 步骤 1: 验证音频链路

**测试 Input Track**：
1. 打开 Mixer
2. 选择 Input Track
3. 添加一个明显的插件（如 Distortion 或 Pitch Shift）
4. 说话，听自己的声音（需要开启 Sidetone 或录音）
5. 应该能听到效果

**测试 Remote Bus**：
1. 连接到服务器，确保有其他用户在说话
2. 选择 Remote Bus
3. 添加一个明显的插件（如 Reverb）
4. 应该能听到所有用户的声音都有混响效果

**测试 Remote Session**：
1. 连接到服务器，确保有特定用户在说话
2. 选择该用户的 Remote Session 轨道
3. 添加插件
4. 应该只有该用户的声音有效果

#### 步骤 2: 检查插件参数

1. 选择已加载的插件
2. 点击 "Refresh Parameters"
3. 检查参数列表：
   - 如果显示 "No automatable parameters"，插件可能不支持参数自动化
   - 如果显示参数列表，尝试调整参数
   - 观察 DSP 状态面板的电平变化

#### 步骤 3: 测试插件链

1. 添加多个插件到同一轨道
2. 逐个 bypass/un-bypass
3. 观察效果变化
4. 检查 Console.app 日志，确认每个插件都成功渲染

#### 步骤 4: 性能检查

1. 打开 Activity Monitor
2. 查找 Mumble 进程
3. 检查 CPU 使用率：
   - 正常：5-15%（无插件）
   - 正常：15-30%（少量插件）
   - 异常：>50%（可能有问题）
4. 如果 CPU 过高，减少插件数量

### 收集诊断信息

如果问题仍然存在，请收集以下信息：

1. **插件信息**：
   - 插件名称和版本
   - 插件类型（AU/VST3）
   - 单声道还是立体声

2. **Console.app 日志**：
   ```bash
   # 在终端运行：
   log show --predicate 'process == "Mumble"' --last 5m | grep MKAudio
   ```

3. **DSP 状态**：
   - Input Peak / Output Peak 值
   - AU Status 错误码
   - Frame Count

4. **系统信息**：
   - macOS 版本
   - Mumble 版本
   - 音频设备（麦克风/扬声器）

### 已知限制

1. **采样率**：仅支持 48kHz（Mumble 标准）
2. **声道数**：支持单声道和立体声（1-2 channels）
3. **延迟**：每个插件增加 ~10ms 延迟
4. **CPU**：复杂插件可能消耗大量 CPU

### 性能优化建议

1. **减少插件数量**：每个轨道不超过 3-4 个插件
2. **使用轻量级插件**：避免使用复杂的混响或卷积插件
3. **关闭不需要的轨道**：Remote Session 轨道在用户不说话时自动禁用
4. **调整缓冲区大小**：在音频设置中增加缓冲区（如果可用）

### 报告问题

如果以上步骤都无法解决问题，请在 GitHub 提交 issue：

**Issue 模板**：
```markdown
### 问题描述
[描述问题]

### 插件信息
- 名称：[插件名称]
- 类型：AU / VST3
- 声道：单声道 / 立体声

### Console.app 日志
```
[粘贴相关日志]
```

### DSP 状态
- Input Peak: [值]
- Output Peak: [值]
- AU Status: [状态]

### 系统信息
- macOS: [版本]
- Mumble: [版本]
- 音频设备: [设备名称]
```

---

**最后更新**: 2026-03-16
**适用版本**: Mumble v4.5.0+
