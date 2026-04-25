# 2026-03-15 Performance Optimization Plan

## Goals

- Reduce end-to-end voice latency by 20%+.
- Reduce reconnect-to-ready time by 30%+.
- Reduce peak CPU usage on audio path by 25%+.
- Reduce UI frame drops in large channels by 50%+.
- Reduce 30-minute call energy usage by 10%+.

## Success Metrics

- `connect_begin -> connect_ready` total latency (ms)
- `connect_begin -> connect_opened` handshake latency (ms)
- `connect_opened -> connect_ready` auth/join latency (ms)
- reconnect success rate and average recovery time
- audio callback p95/p99 duration
- frame drop ratio in channel/message views

## Execution Phases

### Phase 1: Baseline Instrumentation (in progress)

- [x] Add connection/reconnect performance markers in `MUConnectionController`.
- [x] Add audio callback timing markers in MumbleKit audio path.
- [x] Add model rebuild timing in `ServerModelManager+ModelState`.
- [x] Add message render timing in `MessagesView`.

### Phase 2: Hot Path Fixes

- [ ] Eliminate remaining allocations on real-time audio callback path.
- [x] Coalesce high-frequency notifications to reduce main-thread churn.
- [x] Reduce full channel tree rebuild frequency (incremental updates).
- [x] Tune reconnect strategy for jittery network transitions.
- [x] Defer heavy post-connection work so the connecting overlay can render smoothly.
- [x] Move AudioUnit start after input/output callback binding to avoid VoiceChat-without-mic state.

### Phase 3: Validation and Rollout

- [ ] Run iPhone + iPad + macOS baseline/after comparison.
- [ ] Validate packet-loss / latency scenarios with Opus defaults, bluetooth route change, and background reconnect scenarios.
- [ ] Keep debug telemetry behind low-overhead logs and verify no regressions.

## Work Started in This Iteration

- Added baseline logs in `MUConnectionController.m`:
  - `PERF connect_begin`
  - `PERF connect_opened`
  - `PERF connect_ready`
  - `PERF connect_failed`
- These logs include reconnect flag, attempt number, and key durations in milliseconds.

## Progress Update (2026-03-15, Round 2)

- Completed model rebuild optimization in `ServerModelManager`:
  - Added `requestModelRebuild(reason:debounce:)` to coalesce high-frequency refresh triggers.
  - Moved remaining direct `rebuildModelArray()` call sites to scheduler-based entry.
  - Added `PERF rebuild_model_array` timing log.
- Completed audio callback instrumentation in MumbleKit:
  - Added lightweight sampled stats helper: `MumbleKit/src/MKAudioPerfStats.h`.
  - Instrumented callback timing in:
    - `MKiOSAudioDevice` (RemoteIO)
    - `MKVoiceProcessingDevice` (VPIO)
    - `MKMacAudioDevice` (HAL)
  - Added teardown summary logs:
    - `PERF audio_callback ... avg_us p95_us p99_us max_us`
  - Sampling strategy is 1/8 callbacks to keep runtime overhead low.

## Progress Update (2026-03-15, Round 3)

- Completed message rendering instrumentation and burst smoothing in `MessagesView`:
  - Added `PERF message_render_blocks` timing log with message/block counts.
  - Switched message render block computation to message-change driven caching to avoid redundant recomputation on unrelated UI state updates.
  - Added short coalescing window for auto-scroll-to-bottom during message bursts to reduce main-thread animation churn.
- Completed reconnect strategy tuning in `MUConnectionController`:
  - Added bounded retry backoff with jitter based on reconnect attempt.
  - Added reconnect delay to UI notification payload (`reconnectDelay`) and reconnect scheduling logs.
- Validation:
  - `xcodebuild -scheme Mumble -destination 'platform=macOS,arch=arm64' build` succeeded.
  - `xcodebuild -scheme Mumble -destination 'generic/platform=iOS' build` succeeded.

## Immediate Next Tasks (Updated)

1. Run real-device baseline capture and export before/after metrics for connect/reconnect, model rebuild, audio callbacks, and message rendering.
2. Use callback/message p95-p99 data to remove remaining hot-path allocations (audio callback + attributed text/image heavy message rows).
3. Validate packet-loss and background-reconnect scenarios with Opus constrained VBR / DTX / in-band FEC defaults.

## Progress Update (2026-04-25)

- Removed the old Weak Network Mode feature and its settings/test commands. Network resilience now relies on Opus encoder defaults plus normal Mumble transport behavior.
- Enabled Opus constrained VBR, DTX, in-band FEC, and a default packet-loss expectation in `MKAudioInput`.
- Changed default `AudioOpusCodecForceCELTMode` to false so Opus VOIP features are not bypassed.
- Fixed iOS audio session lifecycle so the normal welcome screen and foreground return do not enter VoiceChat mode or open the microphone.
- Ensured the first-run VAD onboarding, Input Setting, and Mixer explicitly start local audio testing.
- Preserved the local audio test when transitioning from Input Setting to VAD onboarding, avoiding a stop/start race.
- Split AudioUnit setup/start so `startDevice()` runs after `MKAudioInput` and `MKAudioOutput` bind callbacks.
- Optimized connection UI smoothness by delaying initial connection work slightly, deferring audio startup, suppressing bulk model side effects, and moving Live Activity/Handoff/avatar work after the first connected UI frame.

Validation captured on iOS Simulator:

- `build_run_sim` succeeded.
- VAD onboarding starts local audio and reports `audio.status` with `localAudioTestRunning=true` and `running=true`.
- Audio logs include `MKAudioInput: ... constrained VBR, DTX, FEC` and `MKVoiceProcessingDevice: AudioUnit started`.
