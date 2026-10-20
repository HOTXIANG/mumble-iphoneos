# Current Project Status

Last updated: 2026-10-20

This document is the short, current source of truth for recent audio, network, UI-performance, and automation changes. Older investigation notes are kept for history, but this file should be checked first when deciding expected behavior.

## iOS Background Reconnect Identity (2026-10-20)

- Automatic socket replacement preserves the exact client identity chain selected for that connection request, including intentionally anonymous sessions. It no longer re-reads the keychain and silently falls back to a different certificate or anonymous authentication. Manual disconnect/server changes clear the cache.
- An unavailable configured certificate prevents a new transport from authenticating anonymously. While iOS protected data is unavailable, setup waits for protected-data availability/activation instead of sending credentials under another identity.
- For the selected iOS identity only, ordinary WhenUnlocked key/certificate items are prepared for AfterFirstUnlock background use. Device-only binding, passcode-only accessibility and explicit access-control restrictions are preserved. See [Apple's accessibility guidance](https://developer.apple.com/documentation/security/restricting-keychain-item-accessibility).
- A previously joined call retains audio ownership while its connection intent remains active, including retry backoff. Foreground/background lifecycle callbacks no longer stop the voice engine just because the replacement socket has not joined yet.
- Graph teardown for recovery and failed activation retries retain the requested iOS audio session instead of temporarily deactivating it or returning to Ambient. Explicit stop still deactivates/reset the session. Transient system-mute notifications from an unhealthy/rebuilding graph cannot replace the app's saved mute state.
- SwiftUI scene transitions now forward the call lifecycle to the existing application delegate, including the real background watchdog entry. Active/inactive forwarding is guarded by connection intent so idle launch and first-run VAD/local previews keep their existing behavior.
- The root connection-alert binding reads live state, so programmatically resolved certificate prompts do not remain visible during recovery.
- iOS Simulator and macOS Debug builds pass. Native certificate-policy tests under ASan/UBSan, transport tests, audio-health tests and the seven ConnectionAsync scenarios pass. A signed iOS Simulator test with a real loopback TLS server verifies stable client certificate fingerprints across an outage despite injected identity-read failures, unchanged voice mode/mixing/audio graph, and local failure for a fresh request whose identity cannot be read.
- With a separate looping AVAudioPlayer app, 56 playback samples contained 18 distinct playback positions and zero interruptions during background reconnect; three TLS attempts used one certificate and the call graph start count stayed at one. Evidence: `Tests/Artifacts/recovery-ios/background-reconnect/`. Interface notifications are injected and transport outages are real loopback failures; physical acceptance is recorded separately below.
- Physical iPhone 17 Pro Max / iOS 27.0.1 acceptance passed without debugger attachment or screen mirroring: music on 5G while locked for one minute, locked 5G-to-Wi-Fi for one minute, then locked Wi-Fi-to-5G for one minute, without foregrounding Mumble. The user confirmed normal music throughout. The 5m27s accepted window has 160 samples, two actual automatic rejoins, unchanged client identity/mute, no certificate/authentication errors or trust prompts, one graph start, continuous VoiceChat/PlayAndRecord with mixing and no ducking, and callback ages below 21 ms. Evidence: `Tests/Artifacts/recovery-ios/physical-background-reconnect/{unmirrored-session.jsonl,summary.json}`. Original Force TCP was preserved; this is not separate UDP, Bluetooth, other-OS or remote acoustic acceptance. Temporary mute/log settings were restored and the final signed build installed.
- Device Hub screen sharing introduced an Oneness/VirtualAudioDevice_Default route during preliminary runs, with playback/suspension interference. Those mirrored runs are excluded from physical acceptance. The native session-recovery regression compiles the production teardown method under ASan/UBSan and passes 200 rebuilds plus explicit-stop checks; final signed iOS-device and macOS Debug builds pass.
- The existing iOS heartbeat probe also passes: live downlink does not conceal missing replies (failure detected in 30.27 seconds), automatic recovery rejoins, and a second failure waits 16.17 seconds rather than bypassing the 15-second cooldown. Joined callback-stall recovery, unfinished TLS timeout, repeated setup cancellation and genuine authentication rejection remain functional.

## iOS Idle Launch and Background Music (2026-09-20)

- `MKAudio` presets `Ambient` / `Default` before constructing any audio racks. Initialization only sets the category; it neither activates the session nor requests microphone input. This removes the cold-launch window in which system-default `SoloAmbient` could interrupt another app if a framework implicitly activated audio.
- Ambient mixes implicitly, so idle configuration passes category options `0`. Apple only supports explicitly setting `MixWithOthers` for playback, play-and-record and multiroute categories: [Apple mixing rules](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/mixwithothers).
- Actual calls/local microphone tests still configure and activate the existing `PlayAndRecord` / `VoiceChat` session when requested. Stopping returns to the same noninterrupting idle category.
- Debug `audio.status` reports real engine/health state even when disconnected, plus iOS category, mode, mixing/ducking flags and other-audio presence. It no longer fabricates a stopped engine based on connection state.
- The idle probe validates its untouched launch snapshot before any cleanup can reset the category. Foreground/background probes also require Ambient/Default with mixing, no ducking and no pending audio-running request. Twelve fixture tests and the existing eleven-scenario probe self-test pass, as do iOS-device and macOS Debug builds.
- Physical iPhone playback continuity has not yet been verified. Persisted plugins use offline rendering, so their engine startup alone does not prove hardware activation. First-run VAD onboarding intentionally starts a microphone preview and remains a separate path from the ordinary idle welcome screen.

## Favourite Server Ping Lifetime (2026-09-19)

- The favourites page owns its ping models and stops all of them when it disappears, including rows retained by lazy lists. Refreshing an unchanged server reuses its existing model; deleting or changing an endpoint stops the previous model.
- DNS resolution creates an inactive pinger. Only the still-current page generation may register it and start sending packets; leaving during resolution cannot start background pinging later.
- Explicit, idempotent pinger shutdown removes the subscriber and closes the shared timer/sockets after the last subscriber. Registering the same address again must not recreate or orphan the shared timer.
- Late replies from a removed address/generation are rejected before their timestamp can become an invalid UI latency. Delegate callbacks stay on the main queue, and stopping inside a callback is supported.
- `run_server_pinger_tests.sh` passes 459 native checks under ASan/UBSan, including real IPv4/IPv6 loopback packets, 24 subscribers sharing an address, repeated starts/stops, weak delegates, background stop and stale replies. `run_server_ping_model_tests.sh` compiles the production Swift model and passes 7 delayed-DNS/cancellation/deinit scenarios. Both platform builds pass.
- Real macOS UI verification (`real_app_favourite_ping_probe.py`) passed three visits on September 19: each six-second visible window received 5 loopback probes and replies; each six-second window after dismissal received 0 packets. The test monitors page state throughout, removes only its temporary favourite, verifies existing favourites are unchanged, and restores the original screen. Evidence: `Tests/Artifacts/recovery-macos/favourite-ping-lifecycle.jsonl` (`passed=true`, no cleanup errors). iOS was build-checked; this page-level packet test ran on macOS.

## macOS VPIO Recovery Loop (2026-09-17)

- CoreAudio device-list notifications now trigger an effective-route comparison instead of unconditional audio reconstruction. VPIO's own aggregate-device events no longer create a rebuild loop.
- Healthy VPIO callbacks permit same-device format changes; real device/aliveness changes and HAL format changes still trigger recovery. Startup baselines preserve device changes that occur during initialization.
- Notification checks have their own generation and a bounded coalescing delay, so they cannot cancel genuine callback-stall recovery or postpone route checks indefinitely.
- Native policy tests (480 assertions under ASan/UBSan), callback/buffer tests, and both platform builds pass.
- On September 18, real built-in microphone/speaker testing passed three 60-second stages using `MKVoiceProcessingDevice`: initial join, recovery from an actual stopped AudioUnit, and rejoin. Graph starts remained at 1/2/3 respectively, with no recovery loop and both callback ages below 11 ms. The original input/output/system-output devices and settings were restored and subsequently verified. This proves callback recovery, not remote acoustic quality.

## Voice and Connection Recovery (2026-09-10)

See [VOICE_RECOVERY.md](VOICE_RECOVERY.md) for behavior, thresholds, reproducible tests, and remaining device validation.

- Completed input/output callbacks determine audio health; either direction stalling for 5 seconds triggers a visible recovery state and graph rebuild.
- Correlated heartbeat replies determine TCP/UDP round-trip health. Downlink traffic alone cannot hide an uplink failure; UDP falls back after 8 seconds and TCP reconnects after 30 seconds without valid replies.
- Default path/interface updates no longer tear down an existing connection: only actual I/O failure or missing heartbeats trigger replacement. This fixes the phone's immediate `network changed` reconnect loop.
- Offline waiting preserves retry capacity. Consecutive automatic failures wait at least 5/15/30/60/120/300 seconds; brief successful joins do not reset backoff, and path restoration cannot bypass cooldown. A session healthy for 60 seconds resets this failure streak on its next failure.
- Connection generations and model identity checks isolate cancellation, certificate prompts, deferred registration, listening-channel restoration, and old transport callbacks.
- Local test and call audio lifecycle actions share one serial queue; obsolete permission callbacks cannot reopen the microphone.
- iOS and macOS integration builds, native fault tests, and macOS loopback/device recovery tests pass. iOS lock-screen music plus actual 5G/Wi-Fi background reconnect acceptance passed on the device above; other hardware/OS matrices remain outstanding.

## Audio Lifecycle

The app must not enter iOS VoiceChat mode or open the microphone just because it is on the normal welcome screen or returns from the background.

Microphone and VoiceChat mode are intentionally active only in these cases:

- The first-run "Welcome to Mumble" VAD onboarding sheet is visible.
- Input Setting is visible.
- Audio Plugin Mixer is visible.
- A server connection is active or in progress and the audio engine is needed for the call.

Important lifecycle details:

- `MKAudio.sharedAudio` presets only the inactive Ambient/Default category during singleton creation, before rack initialization. It does not activate a session or enter recording/VoiceChat mode.
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
