# Mumble WebSocket 自动化测试服务器

## 概述

Mumble 内嵌了一个 WebSocket 测试服务器（`MUTestServer`），仅在 `DEBUG` 构建中编译。AI agent 或自动化脚本可通过 WebSocket 连接到运行中的 App，远程执行所有功能并验证结果。

## 当前测试重点（2026-04-25）

弱网模式已经删除，不再存在 `audio.setWeakNetworkMode`、`audio.setWeakNetworkConfig`、`audio.weakNetworkStatus` 命令。网络/语音体验现在通过 Opus 默认配置优化：constrained VBR、DTX、in-band FEC 和默认 `OPUS_SET_PACKET_LOSS_PERC(10)`。

当前需要重点覆盖这些回归路径：

1. **普通欢迎页空闲**
   - 完全启动 App，停留在普通主界面。
   - 预期：不进入 VoiceChat 模式，不调用麦克风。
   - `audio.status` 在没有本地测试/连接时应返回 `running: false`。
2. **首次 VAD 欢迎引导**
   - 清除 `HasCompletedVADOnboarding` 后重启 App。
   - 预期：VAD onboarding 显示后进入 VoiceChat 模式并调用麦克风。
   - 预期日志包含 `Starting Local Audio for Settings/Testing`、`MKAudioInput: ... constrained VBR, DTX, FEC`、`AudioUnit started`。
3. **Input Setting -> VAD 欢迎引导**
   - 打开 Input Setting，确认本地音频测试已运行。
   - 点击 `Show VAD Tutorial Again`。
   - 预期：设置页 dismiss 到欢迎引导 sheet 的转场中不出现 `Stopping Local Audio (Settings closed)`；欢迎引导关闭后才停止本地音频测试。
4. **Mixer 生命周期**
   - 打开 Audio Plugin Mixer，预期本地音频测试运行。
   - 关闭 Mixer，若未连接服务器，预期停止本地音频测试并释放 session。
5. **连接性能**
   - 收藏服务器连接时观察 connecting overlay 动画和日志。
   - 预期：`connect_ready`、音频启动、模型重建日志存在；UI 不应因音频启动阻塞掉帧。
6. **确定性连接失败路径**
   - 关闭自动重连后连接本地不可达端口。
   - 预期：连接失败后回到非连接/非连接中状态，不启动音频，并留下 `PERF connect_failed`、`connection.error` 或 `network.status.timeline` 证据。
7. **自动重连路径**
   - 打开自动重连并连接本地不可达端口。
   - 预期：`network.status` 暴露 `isReconnecting`、`reconnectAttempt` 或 reconnect timeline，音频不启动，重连设置在场景结束后恢复。

清除首次引导标记示例：

```json
{"id":"reset-vad","action":"settings.remove","params":{"key":"HasCompletedVADOnboarding"}}
```

## Agent 上手速览

如果你是第一次接手这个项目，按下面顺序做，不要直接盲点 UI：

0. **先跑真实 App smoke/probe 脚本**
   - 本机 Simulator 可用时，直接让脚本构建 Debug App、安装启动、等待 `MUTestServer`，并运行完整 suite：
     ```bash
     Scripts/mumble_real_app_probe.sh --platform ios-simulator --scenario all --repeat 2
     ```
   - iPadOS 和 macOS 也走同一套 probe/analyzer 证据格式：
     ```bash
     Scripts/mumble_real_app_probe.sh --platform ipados-simulator --simulator "<available iPad simulator>" --scenario all --repeat 2
     Scripts/mumble_real_app_probe.sh --platform macos --scenario all --repeat 2
     ```
   - 证据会写入 `Tests/Artifacts/real-app/<timestamp>/`，先看 `run-manifest.json`，再按其中的 artifact path 打开 `xcodebuild.log`、probe JSONL、suite index 和 `report.md`。
   - 当前本机已有 Debug App 并且已经启动时，可跳过构建和启动：
     ```bash
     Scripts/mumble_real_app_probe.sh --skip-build --skip-launch --scenario baseline
     ```
   - Xcode beta 或本机 Simulator 环境异常时，先用 `--dry-run` 检查命令，再记录 CoreSimulator/Xcode 的具体失败，不要把环境失败当作产品回归。
1. **已手动启动 App 时跑标准 smoke/probe 脚本**
   - Debug App 启动并出现 `TestServer: listening on ws://localhost:54296` 后，运行：
     ```bash
     python3 Scripts/mumble_agent_probe.py --scenario baseline
     ```
   - 普通欢迎页空闲回归使用更严格的断言：
     ```bash
     python3 Scripts/mumble_agent_probe.py --scenario idle-welcome
     ```
   - 每次运行都会写入 `Tests/Artifacts/*.jsonl`，包含 `log.marker`、请求、响应、推送事件和断言结果，作为可追溯证据。
2. **先确认是 Debug App**
   - `MUTestServer` 只在 `DEBUG` 构建存在。
   - App 启动后控制台必须出现 `TestServer: listening on ws://localhost:54296`。
3. **使用“长连接”而不是一次性请求**
   - `log.stream`、`ui.changed`、`connection.*` 等事件都是**推送式**。
   - `websocat -n1` 只适合一次性 query，不适合调试流程。
4. **先开日志，再做复现**
   - 先调用 `log.marker` 标记本轮调试开始。
   - 再用 `log.stream` 打开相关分类的实时日志。
5. **先读状态，再发动作**
   - 调试前至少执行一次：`state.get`、`ui.get`。
   - 如果是连接态问题，再加 `connection.status`。
   - 如果是插件/混音器问题，再加 `plugin.listTracks`、`plugin.available`。
6. **优先走语义命令，UI 命令只做导航**
   - 例如：插件链操作优先 `plugin.add/remove/load/unload/...`
   - 页面打开/关闭优先 `ui.open` / `ui.dismiss`
   - 不要把“能直接语义操作”的事情退化成模拟点击。
7. **每次改代码后重放同一组命令**
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
- `performance.status`
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

仓库内置了一个无第三方依赖的标准 smoke/probe runner：

```bash
# 运行 CI 同款自动化门禁：脚本自测、suite 证据分析、日志规范检查
sh Scripts/mumble_automation_check.sh

# 成功时也保留 Tests/Artifacts，便于人工检查 JSONL 证据
MUMBLE_KEEP_ARTIFACTS=1 sh Scripts/mumble_automation_check.sh

# 不连接 App，仅验证脚本自身断言和证据写入逻辑
python3 Scripts/mumble_agent_probe.py --self-test

# 检查 probe 场景、required scenario、文档表和预算是否同步
python3 Scripts/mumble_automation_consistency.py

# 连接已运行的 Debug App，采集基础可观测性证据
python3 Scripts/mumble_agent_probe.py --scenario baseline

# 验证普通欢迎页空闲时没有连接、没有麦克风/本地音频测试
python3 Scripts/mumble_agent_probe.py --scenario idle-welcome

# 验证未连接欢迎页经历后台/前台生命周期后仍不启动音频
python3 Scripts/mumble_agent_probe.py --scenario lifecycle-idle-audio

# 验证 Audio Plugin Mixer 打开时启动本地音频测试，关闭后停止
python3 Scripts/mumble_agent_probe.py --scenario mixer-lifecycle

# 验证 VAD onboarding 打开时进入本地音频测试
python3 Scripts/mumble_agent_probe.py --scenario vad-onboarding

# 验证网络稳定性相关设置会写入并出现在 network.status 诊断中
python3 Scripts/mumble_agent_probe.py --scenario network-settings

# 验证本地不可达端口的连接失败路径可观测且不会留下连接/音频残留
python3 Scripts/mumble_agent_probe.py --scenario network-connect-failure

# 验证自动重连路径会留下可追溯的重连状态/attempt/timeline 证据
python3 Scripts/mumble_agent_probe.py --scenario network-auto-reconnect

# 验证 UDP transport 退化、延迟或丢包类网络证据可被采集和归因
python3 Scripts/mumble_agent_probe.py --scenario network-udp-degraded

# 验证 UDP 状态抖动不会连续替换 transient toast，但恢复提示仍会出现
python3 Scripts/mumble_agent_probe.py --scenario network-udp-toast-throttle

# 验证基础 UI/model 刷新采样不会新增主线程 stall
python3 Scripts/mumble_agent_probe.py --scenario ui-performance-sampling

# 依次运行所有内置 smoke/probe 场景，输出到一个 suite 目录
python3 Scripts/mumble_agent_probe.py --scenario all

# 重复运行整套场景，用于抓间歇性失败和稳定性抖动
python3 Scripts/mumble_agent_probe.py --scenario all --repeat 5
```

真正跑 App 的闭环使用 `mumble_real_app_probe.sh`：

```bash
# 构建 Debug iOS simulator App、安装、启动、等待 MUTestServer，再运行完整 suite
Scripts/mumble_real_app_probe.sh --platform ios-simulator --scenario all --repeat 2

# 使用可用的 iPad simulator 跑同一套 suite
Scripts/mumble_real_app_probe.sh --platform ipados-simulator --simulator "<available iPad simulator>" --scenario all --repeat 2

# 构建并启动 macOS App，再运行同一套 suite
Scripts/mumble_real_app_probe.sh --platform macos --scenario all --repeat 2

# 只验证脚本会执行哪些命令，不访问 Xcode/CoreSimulator
Scripts/mumble_real_app_probe.sh --dry-run --scenario all --repeat 2

# 只解析 Xcode/CoreSimulator 环境并写 preflight.json，不构建、不启动 App
Scripts/mumble_real_app_probe.sh --preflight-only --platform ios-simulator

# 使用已启动的 Debug App，只采集单场景证据
Scripts/mumble_real_app_probe.sh --skip-build --skip-launch --scenario idle-welcome
```

`mumble_real_app_probe.sh` 默认使用 `Mumble` scheme、`Debug` 配置、`ios-simulator` 平台、自动选择当前可用的 iPhone simulator、`cn.hotxiang.Mumble` bundle id，并把证据写入 `Tests/Artifacts/real-app/<timestamp>/`。可用 `--platform ios-simulator|ipados-simulator|macos`、`--simulator`、`--simulator-id`、`--derived-data`、`--artifacts`、`--url` 调整环境；`ipados-simulator` 会自动选择可用 iPad simulator，显式 `--simulator-id` 会绕过名称选择。Xcode beta 环境需要临时覆盖 simulator deployment target 时，使用 `MUMBLE_SIM_DEPLOYMENT_TARGET=17.0`。iOS/iPadOS 路径会通过 `simctl` 安装和启动 App，并在安装后尝试执行 `simctl privacy <simulator> grant microphone <bundle id>`，真实运行时把授权结果写入 `simctl-privacy.log` 和 `simctl-privacy.json`；`--dry-run` 只在 manifest 中记录 `privacy.microphone.status=planned`，安装前失败会记录 `not-attempted`。如果该授权失败，音频场景会优先通过 `audio.permission` 暴露 `denied`/`restricted` 等状态，避免把权限问题误判成音频引擎超时。macOS 路径会构建 `platform=macOS`，读取 `.app/Contents/Info.plist` 中的 `CFBundleExecutable`，直接启动 `.app/Contents/MacOS/<executable>`，并把麦克风 privacy 状态记录为 `not-applicable`。该脚本启动 App 时会注入 `MUMBLE_LOG_LEVEL=debug`、`MUMBLE_LOG_VERBOSE=Connection,Network,Audio,Plugin,UI,Model` 和 `MUMBLE_LOG_FILE=1`，让 probe 证据和 App 日志能互相对齐。

真实 App probe 每次运行都会写 `run-manifest.json`，作为该 run 的统一入口。manifest 包含 `status`、`phase`、`summary`、`dryRun`、`preflightOnly`、平台配置、simulator 选择、App path、麦克风授权状态、诊断摘要和所有关键 artifact path；常见 `phase` 包括 `simulator-preflight`、`preflight`、`build`、`app-lookup`、`launch`、`test-server-wait`、`probe`、`analyze`、`dry-run` 和 `complete`。真实 App probe 开始时还会写 `preflight.json`，记录平台、scheme、destination、Xcode developer dir、Xcode 版本、deployment target，以及最终选择的 simulator name/id/runtime。如果 simulator preflight 失败，脚本会保留 `simctl-list.log`，并生成 `preflight-diagnostics.md` 与 `preflight-diagnostics.json`。如果真实 App 构建失败，脚本会保留完整 `xcodebuild.log`，并生成 `build-diagnostics.md` 与 `build-diagnostics.json`。诊断器会把常见阻断归类为 asset catalog、Swift macro plugin/sandbox、编译、链接、签名或 CoreSimulator 环境问题；同时写入 `rootCauseSummary`、`environmentLimited`、`nextActions` 和上下文（phase、platform、scheme、configuration、destination、DerivedData、Xcode developer dir、deployment target）。其中 `environmentLimited=true` 表示当前证据更像工具链、签名或模拟器环境阻断，不能当作产品运行时验证结果；仍需要重新跑到 App 启动并采集 MUTestServer JSONL 后，才算真实 App probe 通过。需要单独重跑诊断时使用：

多个 real-app run 可以直接汇总：

```bash
# 输出 JSON 汇总，适合脚本消费
python3 Scripts/mumble_manifest_summarize.py Tests/Artifacts/real-app

# 输出 Markdown，适合 CI summary、issue 或 PR
python3 Scripts/mumble_manifest_summarize.py Tests/Artifacts/real-app --markdown
```

manifest 汇总会统计 passed/failed、失败 phase、诊断 classification、`environmentLimited` 数量和麦克风授权状态，并列出每个 run 的 manifest 路径。CI 手动触发 real-app probe 时，即使 probe 失败，也会把该 Markdown 汇总写入 GitHub step summary。

```bash
python3 Scripts/mumble_build_diagnostics.py Tests/Artifacts/real-app/<run>/xcodebuild.log \
  --context platform=macos \
  --context scheme=Mumble \
  --markdown Tests/Artifacts/real-app/<run>/build-diagnostics.md \
  --json Tests/Artifacts/real-app/<run>/build-diagnostics.json
```

在 GitHub Actions 中，`Scripts/mumble_automation_check.sh` 会默认保留 `Tests/Artifacts`，并把 `Tests/Artifacts/self-test-suite/report.md` 写入 job summary。workflow 同时会把整个 `Tests/Artifacts` 目录上传为 `mumble-automation-evidence` artifact；如果自动化门禁失败，仍优先下载这个 artifact 查看 JSONL、suite index、Markdown 报告和失败时的 `diagnostic.snapshot`。

需要在 CI 上跑真实 Debug App 时，手动触发 `Build` workflow，打开 `real_app_probe` 输入，并用 `real_app_probe_platform` 选择 `ios-simulator`、`ipados-simulator` 或 `macos`。该路径会执行 `Scripts/mumble_real_app_probe.sh --platform <selected> --scenario all --repeat 2`，生成的真实 App probe 证据同样会进入 `mumble-automation-evidence` artifact。默认 push/PR 仍只跑工具链自测和构建，避免把临时 CoreSimulator 环境故障误报成每个 PR 的产品回归。

输出的 JSONL 证据文件默认位于 `Tests/Artifacts/`。单场景会生成一个 `<timestamp>-<scenario>.jsonl`；`--scenario all` 会生成 `<timestamp>-suite/`，其中包含每个场景的 JSONL 和 `suite-index.jsonl`。使用 `--repeat N` 时，同一个场景会输出 `<scenario>-<iteration>.jsonl`，`suite-index.jsonl` 会记录每次迭代的 `iteration`、`repeat`、状态、耗时和输出路径。每个 `run.start` / `suite.start` 都会写入 `provenance`，记录 probe 版本、Python/平台信息、仓库 HEAD 与 dirty 状态，方便把日志证据追溯到具体代码状态。后续修复卡顿、掉帧、崩溃或音频生命周期问题时，优先把最小复现命令固化为该 runner 的新 scenario，并保留修复前后的 JSONL 文件用于对比。新增 scenario 后必须同步 `Scripts/mumble_real_app_probe.sh`、`Scripts/mumble_automation_check.sh`、本文档场景表和必要预算；`Scripts/mumble_automation_consistency.py` 会在自动化门禁中检查这些入口是否同步，并阻止 `NeoMumble.icon in Resources` 这类会让 macOS asset catalog 编译失败的旧资源配置回归。

内置场景覆盖：

| 场景 | 断言 |
|------|------|
| `baseline` | WebSocket 基础域、日志分类、`state.get`、`ui.get` 可用 |
| `idle-welcome` | 未连接普通欢迎页不启动麦克风或本地音频测试 |
| `lifecycle-idle-audio` | 未连接欢迎页模拟后台/前台生命周期，确认音频仍停止且连接状态保持 idle |
| `mixer-lifecycle` | 打开 `audioPluginMixer` 后本地音频测试运行，关闭后在未连接状态停止 |
| `vad-onboarding` | 打开 `vadOnboarding` 后 sheet 可见且本地音频测试运行 |
| `network-settings` | 临时切换 Force TCP、Auto Reconnect、QoS、重连次数和间隔，确认 `network.status` 反映设置并恢复原值 |
| `network-connect-failure` | 关闭自动重连后连接本地不可达端口，确认失败可观测、连接回到 idle、音频未启动、设置已恢复 |
| `network-auto-reconnect` | 打开自动重连后连接本地不可达端口，确认重连状态、attempt 或 timeline 可观测，音频未启动，设置已恢复 |
| `network-udp-degraded` | 注入 Network 类别 UDP transport 退化 marker，确认 `network.status` timeline 或 transport 指标可观测，分析器能把问题归入 UDP/丢包/延迟问题簇 |
| `network-udp-toast-throttle` | 快速注入 `stalled`、`recovering`、`available` UDP 状态，确认 transient UDP toast 被限流且恢复成功 toast 仍会出现 |
| `ui-performance-sampling` | 无连接状态下反复 `app.refreshModel`、`state.get`、`ui.get`、`app.get` 和 `performance.status`，确认采样期间不新增主线程 stall，并把每轮 performance snapshot 写入 JSONL |

JSONL 证据可以直接汇总为断言和性能指标：

```bash
# 汇总命令、事件、断言失败和 PERF 指标
python3 Scripts/mumble_trace_analyze.py Tests/Artifacts/*.jsonl

# 使用仓库内的版本化性能预算，超过阈值时返回非 0
python3 Scripts/mumble_trace_analyze.py Tests/Artifacts/*.jsonl \
  --budget-file Tests/Baselines/performance_budgets.json

# 分析 suite 目录内的所有场景证据
python3 Scripts/mumble_trace_analyze.py Tests/Artifacts/*-suite/*.jsonl \
  --budget-file Tests/Baselines/performance_budgets.json \
  --require-suite-index \
  --require-provenance \
  --require-scenario baseline \
  --require-scenario idle-welcome \
  --require-scenario lifecycle-idle-audio \
  --require-scenario mixer-lifecycle \
  --require-scenario vad-onboarding \
  --require-scenario network-settings \
  --require-scenario network-connect-failure \
  --require-scenario network-auto-reconnect \
  --require-scenario network-udp-degraded \
  --require-scenario network-udp-toast-throttle \
  --require-scenario ui-performance-sampling \
  --require-event log.entry \
  --require-command log.stream \
  --require-command log.marker \
  --require-command log.recent \
  --require-command network.status \
  --require-command network.injectUDPStatus \
  --require-command app.refreshModel \
  --require-command app.simulateLifecycle \
  --require-network-snapshot \
  --require-command performance.reset \
  --require-command performance.status \
  --require-perf-marker agent_probe.marker \
  --require-perf-marker ui_performance_sampling.samples \
  --max-performance-stalls 0 \
  --max-performance-lag-ms 0

# 生成可贴到 issue / PR 的 Markdown 证据报告
python3 Scripts/mumble_trace_analyze.py Tests/Artifacts/*-suite/*.jsonl \
  --markdown \
  --budget-file Tests/Baselines/performance_budgets.json \
  --require-suite-index \
  --require-provenance

# 临时实验阈值仍可用，适合修复单个问题时收紧某个指标
python3 Scripts/mumble_trace_analyze.py Tests/Artifacts/*.jsonl \
  --max connect_ready.total_ms=1500 \
  --max-scenario-ms '*=30000' \
  --max-wait-ms '*=8000' \
  --max-command-ms '*=5000' \
  --max audio_callback.p95_us=2500 \
  --max rebuild_model_array.elapsed_ms=50 \
  --max-network-timeline-warnings 0 \
  --max-network-timeline-errors 0 \
  --max-network-issues 0

# 对比修复前 / 修复后的证据，生成性能变化报告
python3 Scripts/mumble_trace_compare.py \
  --before Tests/Artifacts/before/*.jsonl \
  --after Tests/Artifacts/after/*.jsonl \
  --metric rebuild_model_array.elapsed_ms \
  --metric message_render_blocks.elapsed_ms \
  --markdown
```

分析器会读取 `log.entry` 事件和 `log.recent` 响应中的 `PERF ... key=value` 日志，输出每个指标的 count/min/p50/p95/max。它会汇总 `suite.scenario` 为 Scenario Outcomes，显示每个场景的运行次数、通过次数、失败次数、成功率和失败迭代，用于 `--repeat` 场景下定位间歇性失败。它会匹配 `run.start` 和 `run.end`，汇总每个 probe scenario 的端到端 duration，报告最慢场景、p95 和 max；`--max-scenario-ms scenario=ms` 可以收紧单个场景，`--max-scenario-ms '*=ms'` 可以设置全局上限。它会汇总 `wait` 记录，报告每个语义等待的耗时、尝试次数和失败数量；`--max-wait-ms description=ms` 可以收紧某个 UI/audio wait，`--max-wait-ms '*=ms'` 可以设置全局上限，用来发现“最终通过但等到很久才稳定”的卡顿或竞态。它也会匹配 `command.send` 和 `command.response`，汇总每个 MUTestServer action 的 round-trip latency，报告最慢命令、p95 和 max；`--max-command-ms action=ms` 可以收紧单个 action，`--max-command-ms '*=ms'` 可以设置全局上限。它也会汇总 `performance.snapshot`，输出主线程 stall monitor 的快照数量、最大 `stallCount`、最大 `maxLagMs`、最大 stall 上下文、最近一次 stall 上下文和最近去重上下文；`--max-performance-stalls` 与 `--max-performance-lag-ms` 可以把这些快照变成硬门禁。`network.status` 会被汇总为 network snapshots，包含连接/重连状态、UDP transport state、UDP ping 样本、包统计、最近 Network 日志，以及由 Connection/Network/Certificate 日志归一化出的 `timeline`；`--require-network-snapshot`、`--max-network-udp-ping-ms`、`--max-network-packet-loss-percent`、`--max-network-timeline-warnings`、`--max-network-timeline-errors` 可以把网络证据和阈值纳入失败条件。probe 失败时会自动写入 `diagnostic.snapshot`，包含失败列表以及 `state.get`、`ui.get`、`app.get`、`connection.status`、`network.status`、`audio.status`、`performance.status`、`log.recent` 的现场快照。`--markdown` 会输出包含摘要、场景、scenario outcomes、scenario duration、wait latency、命令、command latency、PERF 指标、performance snapshot、stall contexts、network snapshots、network timeline、failure diagnostics、incident timeline 和 provenance 的可读报告；incident timeline 会把失败、慢等待、慢命令、主线程 stall、网络 warning/error 和 diagnostic snapshot 按时间合并，优先作为下载 CI artifact 后的第一眼排查入口。`MUMBLE_KEEP_ARTIFACTS=1 sh Scripts/mumble_automation_check.sh` 会把 suite 报告保存在 `Tests/Artifacts/self-test-suite/report.md`。`mumble_trace_compare.py` 用于同一场景修复前/修复后的 JSONL 对比，输出每个指标的 before max、after max、delta、delta percent，并同时比较 scenario duration、command latency、主线程 stall 汇总、最大 stall 上下文、UDP ping、丢包率、UDP state 分布和 network timeline warning/error/kind 分布。probe `error`、失败的 `run.end`、失败的 `suite.scenario` / `suite.end` 会被视为整体失败，避免只看断言时漏掉启动、连接或场景执行错误。对 suite 证据同时使用 `--require-suite-index`、`--require-provenance` 和 `--require-scenario`，确保分析的是同一个 suite 的完整场景集，并且每个 run/suite 起点都能追到 probe 版本、Python/平台、仓库 HEAD 与 dirty 状态，而不是误把零散 JSONL 当作全量回归。`--require-event`、`--require-command`、`--require-network-snapshot` 和 `--require-perf-marker` 用来证明日志流、命令响应、网络快照和结构化 marker 确实被采集；其中 `performance.reset` 证明每个场景开始前隔离了计数，`performance.status` 证明 Debug App 的主线程 stall monitor 在线，`network.status` 证明连接/网络状态已随场景证据采集，`app.refreshModel` 与 `ui_performance_sampling.samples` 证明 UI/model 性能采样路径在线。每个场景都会写入 `PERF agent_probe marker=1 ...` 作为探针覆盖标记。新增性能日志时保持 `PERF marker_name key=value` 格式，才能被自动汇总和阈值化。长期阈值放在 `Tests/Baselines/performance_budgets.json`；`budgets` 管 PERF 指标，`scenarioBudgets` 管 probe 场景总耗时，`waitBudgets` 管语义等待耗时，`commandBudgets` 管 MUTestServer 命令耗时，`networkBudgets` 管 `maxUdpPingMeanMs`、`maxPacketLossPercent`、`timelineWarningCount` 和 `timelineErrorCount`。其中 `ui-performance-sampling` 有单独场景耗时预算，`app.refreshModel`、`performance.status`、`state.get`、`ui.get` 和 `app.get` 有单独命令延迟预算。默认 `required=false` 表示“如果该场景采集到了这个指标就必须过线”，完整 suite 覆盖性仍由 `--require-scenario`、`--require-command` 和 `--require-perf-marker` 证明。

网络报告还会生成 `networkHealth.status`、`networkHealth.rootCauseHint`、`networkIssueCount` 和 `networkIssueKinds`。这些字段把 `isReconnecting`、UDP problem state、packet loss、高 UDP ping、timeline warning/error 归一成健康摘要；`rootCauseHint` 会优先指向 certificate/TLS、connection failure、reconnect loop、UDP transport、packet loss 或 latency，方便先定位问题簇，再回到原始 timeline 和 diagnostic snapshot。Markdown 报告的 `Network By Scenario` 会按场景拆分这些字段，并把 `network-connect-failure` 中的 `connection_failure`、`network-auto-reconnect` 中的 `connection_failure/reconnect_loop` 标成预期根因，避免把预期失败路径和非预期网络退化混在一起。需要把网络健康摘要变成门禁时，可使用 `--max-network-issues`，或在 `networkBudgets` 中加入 `networkIssueCount`、`packetLossObservedCount`、`reconnectingCount`、`udpProblemStateCount`。

`mumble_trace_compare.py` 的 Network Health 区块会同时对比 `networkIssueCount`、health status、root cause hint、UDP states、timeline kinds 和 issue kinds。修网络问题时保留 before/after JSONL 后再跑对比，可以直接看问题簇是否从 `connection_failure`、`reconnect_loop` 或 `udp_transport` 收敛到 `none`，避免只比较单个 ping 或丢包数字。

静态日志规范也有 CI 门禁：

```bash
# 检查是否新增了 print、裸 NSLog，或不可解析的 PERF 日志
python3 Scripts/mumble_observability_check.py \
  --baseline Tests/Baselines/observability_allowlist.json \
  --require-perf-marker connect_begin \
  --require-perf-marker connect_opened \
  --require-perf-marker connect_ready \
  --require-perf-marker connect_failed \
  --require-perf-marker rebuild_model_array \
  --require-perf-marker message_render_blocks \
  --require-perf-marker audio_callback \
  --require-perf-marker main_thread_stall

# 只在主动接受/清理既有日志债后更新 baseline
python3 Scripts/mumble_observability_check.py \
  --update-baseline Tests/Baselines/observability_allowlist.json \
  --baseline Tests/Baselines/observability_allowlist.json
```

当前 baseline 只用于记录既有债务；新代码仍应使用 `MumbleLogger`、`MULog*` 或 `MKLog*`，不要新增 `print` 或裸 `NSLog`。清理旧日志时如果检查器报告 `resolved baseline entries`，同步更新 baseline，让 CI 继续保持“不得新增违规”的 ratchet。`--require-perf-marker` 是静态探针保留门禁，防止连接、模型重建、消息渲染、音频 callback 或主线程卡顿的关键 `PERF` 日志被后续重构删掉；动态场景没触发某条热路径时，静态门禁仍能证明探针还在源码中。

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
5. `network.status`
6. 如失败，`log.export`

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
| `network.status` | `logLimit`(20) | 获取连接/重连状态、UDP transport、UDP ping、包统计、最近 Network 日志和 Connection/Network/Certificate timeline |
| `network.injectUDPStatus` | `state`(必需) | Debug 自动化用：投递 `unknown` / `unavailable` / `available` / `stalled` / `recovering` UDP 状态通知，用于验证状态 UI、toast 和事件流 |

```bash
# 连接服务器
{"action": "connection.connect", "params": {"hostname": "mumble.example.com", "port": 64738, "username": "TestBot"}}

# 断开
{"action": "connection.disconnect"}

# 查看状态
{"action": "connection.status"}
```

### audio — 音频控制

`audio.startTest` / `audio.stopTest` 用于本地音频测试场景（Input Setting、Audio Plugin Mixer、VAD onboarding）。普通欢迎页不应主动启动本地音频测试。`audio.restart` 只用于已连接服务器的通话音频引擎。

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
| `audio.permission` | 无 | 获取麦克风授权状态；音频场景失败时优先用它区分权限问题和音频引擎问题 |
| `audio.restart` | 无 | 重启音频引擎 |
| `audio.forceTransmit` | `enabled`(必需) | 设置 Push-to-Talk 强制发话 |
| `audio.status` | 无 | 获取音频状态 |

```bash
{"action": "audio.mute"}
{"action": "audio.status"}
# → {"success": true, "data": {"running": true, "selfMuted": true, "selfDeafened": false}}
```

VAD onboarding 验证示例：

```bash
{"action": "settings.remove", "params": {"key": "HasCompletedVADOnboarding"}}
# 重启 App 后等待 onboarding 出现
{"action": "audio.status"}
# 预期：localAudioTestRunning=true, running=true
```

已删除命令：

- `audio.setWeakNetworkMode`
- `audio.setWeakNetworkConfig`
- `audio.weakNetworkStatus`

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
| `app.simulateLifecycle` | `phase`(必需, `willResignActive`/`didBecomeActive`) | Debug 自动化用：模拟 App 进入后台/回到前台的生命周期回调，用于验证未连接状态不会意外启动音频 |

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
| `performance.status` | 无 | 读取 Debug 主线程 stall monitor 的运行状态、累计 stall、最近一次上下文和最大 stall 上下文 |
| `performance.reset` | 无 | 清零 stall monitor 计数，适合在复现动作前调用 |

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
