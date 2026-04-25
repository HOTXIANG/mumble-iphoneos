# Current Project Status

Last updated: 2026-04-25

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
- First-run VAD onboarding shows and starts local audio.
- Logs show `MKAudioInput: ... Opus (... constrained VBR, DTX, FEC)`.
- Logs show `MKVoiceProcessingDevice: AudioUnit started` followed by input buffer allocation.
- `audio.status` reports `localAudioTestRunning: true` and `running: true` during onboarding.

