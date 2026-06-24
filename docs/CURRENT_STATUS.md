# Current Project Status

Last updated: 2026-06-22

This document is the short, current source of truth for recent audio, network, UI-performance, and automation changes. Older investigation notes are kept for history, but this file should be checked first when deciding expected behavior.

## Audio Lifecycle

The app must not enter iOS VoiceChat mode or open the microphone just because it is on the normal welcome screen or returns from the background.

Microphone and VoiceChat mode are intentionally active only in these cases:

- The first-run "Welcome to Mumble" VAD onboarding sheet is visible.
- Input Setting is visible.
- Audio Plugin Mixer is visible.
- A server connection is active or in progress and the audio engine is needed for the call.

Important lifecycle details:

- `MKAudio.sharedAudio` no longer configures `AVAudioSession` during singleton creation.
- When audio is stopped on iOS, the session is reset to `Ambient` / `Default` and deactivated.
- `MUApplicationDelegate` only restarts/stops background audio based on a real active server connection, not stale connection flags.
- `ServerModelManager.startAudioTest()` checks both logical local-test state and the real `MKAudio.isRunning()` state.
- Local audio test startup is guarded by `isLocalAudioTestStarting` so repeated UI retries do not repeatedly tear down and recreate Audio Units.
- When Input Setting opens the VAD onboarding sheet, the local audio test is preserved during the sheet transition. Closing Input Setting must not stop and then restart the microphone during that transition.
- A preservation timeout stops local audio if the onboarding sheet fails to appear.

## Audio Unit Startup Order

Audio devices are initialized and started in two steps:

1. `setupDevice()` creates/configures the AudioUnit and initializes it.
2. `startDevice()` starts the AudioUnit only after `MKAudioInput` and `MKAudioOutput` have bound their callbacks.

This prevents the previous failure mode where the app entered VoiceChat mode but the microphone input callback was not reliably running.

## Opus Defaults

Weak Network Mode has been removed. Network resilience now relies on Opus defaults and the existing Mumble transport/jitter behavior.

The Opus encoder defaults are:

- `OPUS_SET_VBR(1)`
- `OPUS_SET_VBR_CONSTRAINT(1)`
- `OPUS_SET_DTX(1)`
- `OPUS_SET_INBAND_FEC(1)`
- `OPUS_SET_PACKET_LOSS_PERC(10)`

`AudioOpusCodecForceCELTMode` defaults to `false` on iOS and macOS so Opus VOIP features such as DTX and FEC can work as intended.

## Connection Performance

Connection startup is staged so UI presentation is not blocked by expensive work:

- Initial `establishConnection` is delayed slightly after the connecting notification so the Liquid Glass connecting overlay can render smoothly.
- Audio engine startup is scheduled asynchronously after connection readiness work.
- Model rebuilds suppress per-user side effects during bulk updates.
- Avatar refresh, Live Activity, and Handoff updates are deferred until after the first connected UI frame.
- The root `WelcomeView` no longer applies a global animation to every `isConnecting` change.

## Channel UI Performance

Channel listener rows now filter talk-state and membership notifications before refreshing their speaker indicator. They keep a local session set for the channel, ignore unrelated talk-state changes, and scan the channel's raw user list instead of calling the sorted display list when only a boolean "someone is speaking" state is needed.

## macOS Window Stability

macOS uses a stable `NavigationSplitViewVisibility` initial value and preserves the launch window frame through the first split-layout pass. The sidebar reveal must not widen the restored window.

## Cancel Feedback

Cancel buttons in sheets, alerts, and the connecting overlay should use `InteractionFeedback.cancel()` before dismissing or triggering cancellation. Keep the feedback lightweight and avoid doing heavy cancellation work on the same frame as the button press.

## Removed Weak Network Mode

The old weak-network feature and its settings have been removed from:

- Advanced Audio settings UI
- WebSocket test commands
- MumbleKit weak-network state/statistics
- `MKAudioSettings` weak-network fields
- app default settings and restart signatures

Do not reintroduce UI or WebSocket commands named `setWeakNetworkMode`, `setWeakNetworkConfig`, or `weakNetworkStatus`.

## Verification Snapshot

Recent simulator verification:

- iOS `build_run_sim` succeeded for scheme `Mumble`.
- Prior authorized-microphone runs showed first-run VAD onboarding starting local audio, with `MKAudioInput: ... Opus (... constrained VBR, DTX, FEC)`, `MKVoiceProcessingDevice: AudioUnit started`, and `audio.status` reporting `localAudioTestRunning: true` plus `running: true`.
- Current real iOS Simulator run on 2026-06-22 has microphone permission denied for `cn.hotxiang.Mumble`; audio scenarios now fail fast with `audio.permission` reporting `microphone: denied` instead of timing out behind local audio waits.
- `mumble_real_app_probe.sh` now attempts `simctl privacy ... grant microphone ...` after installing iOS/iPadOS simulator builds and records the result in `run-manifest.json` plus `simctl-privacy.log/json` on real runs. In this sandbox, direct `simctl privacy` still fails at the CoreSimulatorService/simdiskimaged layer, so current audio verification remains permission-limited rather than product-confirmed.
- With microphone denied, `mixer-lifecycle` still proves the Preferences -> Advanced Audio Settings automation path before failing on permission, and `vad-onboarding` proves the onboarding sheet is presented before failing on permission.
- Current real iOS Simulator non-audio subset passed in `Tests/Artifacts/real-sim-current/non-audio-after-reset-retry/`: baseline, idle welcome, lifecycle idle audio, network settings, deterministic connect failure, auto-reconnect evidence, UDP degradation evidence, localized UDP toast throttling, and UI/model performance sampling.

Recent automation/probe verification:

- iOS simulator compile check succeeded with `build_sim` for scheme `Mumble` using `IPHONEOS_DEPLOYMENT_TARGET=17.0` and `CODE_SIGNING_ALLOWED=NO` after the channel listener-row performance change.
- `Scripts/mumble_automation_check.sh` covers the standard WebSocket probe suite, evidence analyzer, before/after trace comparer, observability gate, and build diagnostics self-test.
- The probe suite currently includes baseline, idle welcome, idle background/foreground lifecycle audio guard, audio plugin mixer lifecycle, VAD onboarding, network settings, deterministic connect failure, auto-reconnect evidence, UDP degradation evidence, UDP toast throttling, and UI/model performance sampling scenarios.
- `Tests/Baselines/performance_budgets.json` now includes UI/model performance sampling budgets: `ui-performance-sampling` scenario duration plus `app.refreshModel`, `performance.status`, `state.get`, `ui.get`, and `app.get` command latency thresholds.
- `network-udp-degraded` injects a Network warning marker and validates that `network.status` captures UDP transport degradation in timeline or transport metrics; analyzer reports expected UDP/packet-loss/latency issue clusters without mixing them with connection-failure scenarios.
- UDP transient status toasts are rate-limited so rapid `stalled` / `recovering` / `unavailable` transitions do not repeatedly replace the banner during network flapping. `network-udp-toast-throttle` verifies that immediate recovering toasts are suppressed while the restored success toast still appears.
- Real-app `network-udp-toast-throttle` accepts both English and Simplified Chinese UDP toast text while still requiring the expected toast type, so localized Simulator runs validate the same behavior.
- `lifecycle-idle-audio` simulates iOS background/foreground lifecycle callbacks on the disconnected welcome screen and verifies audio remains stopped while connection state stays idle.
- Scenario reset now cancels/disconnects outstanding connection attempts, clears custom alerts/toasts repeatedly until the UI is clean, and requires `currentScreen == welcome` to avoid stale sheet/alert state leaking between real-app scenarios.
- `Scripts/mumble_automation_consistency.py` checks that probe scenarios stay synchronized across the runner, real-app required scenarios, automation required scenarios, docs, UI/model sampling budgets, and the project file guard that prevents legacy `NeoMumble.icon in Resources` entries from returning. It runs inside `Scripts/mumble_automation_check.sh`.
- macOS real-app probe attempted with `Scripts/mumble_real_app_probe.sh --platform macos --scenario baseline`.
- Current macOS real-app probe evidence is in `Tests/Artifacts/real-app/macos-current-baseline/`: `run-manifest.json` failed at phase `build`, with diagnostics classification `swift_macro_plugin_environment` and `environmentLimited=true`.
- The previous macOS build blocker was `Resources/NeoMumble.icon` failing in `actool` with `The file “NeoMumble.icon” couldn’t be opened.` The app icon now has a standard `Assets.xcassets/NeoMumble.appiconset`, and the legacy `.icon` folder is no longer in the app or widget target Resources build phase.
- After the icon fix, macOS build gets past asset catalog compilation and currently stops in this environment on Xcode beta Swift macro plugin execution: `swift-plugin-server produced malformed response`, preceded by `sandbox-exec: sandbox_apply: Operation not permitted`.
- Real-app build failures now produce machine-readable diagnostics with `rootCauseSummary`, `environmentLimited`, `nextActions`, and build context. The current Swift macro plugin failure is classified as `swift_macro_plugin_environment` with `environmentLimited=true`.
- Treat the current macOS real-app probe as environment-limited until it is re-run outside this sandbox or with a stable Xcode toolchain.
- iOS simulator real-app preflight now auto-selects an available iPhone/iPad simulator instead of assuming a fixed device name. In the current sandbox, `simctl list devices available -j` fails before selection because CoreSimulatorService/simdiskimaged is unavailable; the failure is classified as `coresimulator_environment` with `environmentLimited=true` in `preflight-diagnostics.json`.
- Every real-app probe run now writes `run-manifest.json`, which records the final status, failed phase, summary, selected simulator, app path, diagnostics summary, and artifact paths. Use it as the first file when triaging real-app evidence.
- `Scripts/mumble_manifest_summarize.py` summarizes one or more `run-manifest.json` files into JSON or Markdown, including failed phase, diagnostic classification, and environment-limited counts. The automation check validates this path, and workflow-dispatched real-app probes write the Markdown summary to GitHub step summary even when the probe fails.
