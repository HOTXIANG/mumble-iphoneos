# DAW-Style Sidechain Routing — Design Spec

## Overview

Add per-plugin sidechain input routing to the Mumble mixer, enabling AU plugins with a sidechain bus (`inputBusses[1]`) to receive audio from any other track as a control signal. This enables ducking compressors, gates, dynamic EQ, and other sidechain-dependent effects in the DAW-style mixer.

## Signal Model

**Pre-fader capture**: Sidechain source signals are captured **before** the track's own AU chain processes them (raw decoded audio). When the source is silent (user not talking), the sidechain feeds zeros.

**Per-plugin granularity**: Each plugin slot independently selects its sidechain source. Two plugins on the same track can have different sidechain sources.

## Available Sidechain Sources

| Source Key | Description |
|------------|-------------|
| `none` | No sidechain (default) — AU sidechain bus receives silence |
| `input` | Local microphone signal (Int16→Float converted, pre-AU) |
| `session:<N>` | Remote user session N's decoded audio (pre-AU, pre-mix) |
| `masterBus1` | Master Bus 1 mixed signal (post-user-mix, pre-bus-AU) |
| `masterBus2` | Master Bus 2 mixed signal (post-user-mix, pre-bus-AU) |

## Architecture

### Layer 1: Sidechain Buffer Pool (MKAudioOutput.m)

A set of pre-allocated float buffers, populated during each `mixFrames:amount:` call. Uses C-level storage to avoid ObjC allocations on the real-time audio thread.

```objc
// MKAudioOutput private ivars
#define MK_SIDECHAIN_MAX_SESSIONS 64
#define MK_SIDECHAIN_MAX_FRAMES   4096

struct MKSidechainSlot {
    float    buffer[MK_SIDECHAIN_MAX_FRAMES * 2];  // max stereo
    NSUInteger session;     // 0 = unused
    BOOL     valid;         // set to YES when populated this cycle
};

@interface MKAudioOutput () {
    struct MKSidechainSlot _sidechainUserSlots[MK_SIDECHAIN_MAX_SESSIONS];
    float    _sidechainMasterBus1[MK_SIDECHAIN_MAX_FRAMES * 2];
    float    _sidechainMasterBus2[MK_SIDECHAIN_MAX_FRAMES * 2];
    BOOL     _sidechainMasterBus1Valid;
    BOOL     _sidechainMasterBus2Valid;
    float   *_sidechainInputBuffer;         // atomic pointer from MKAudio (input thread → output thread)
    NSUInteger _sidechainInputFrameCount;
    NSUInteger _sidechainInputChannels;
    NSUInteger _sidechainFrameCount;
    NSUInteger _sidechainChannels;
}
```

**Capture points in `mixFrames:amount:`**:

1. **Per-user pre-fader**: After `[ou buffer]` is ready, before `trackProcessor()` call → `memcpy` to the slot matching this session.
2. **Master Bus 1 pre-fader**: After `mixBuffer1` accumulation completes, before `_remoteBusProcessor()` → `memcpy` to `_sidechainMasterBus1`.
3. **Master Bus 2 pre-fader**: After `mixBuffer2` accumulation completes, before `_remoteBus2Processor()` → `memcpy` to `_sidechainMasterBus2`.
4. **Cycle start**: Mark all slots `valid = NO`. Only populated slots are readable.

**Input track capture** (cross-thread):
- `MKAudioInput` runs on the input audio thread. In `processAndEncodeAudioFrame`, after Speex/gain but before `_inputTrackProcessor`, convert Int16→Float into a pre-allocated double-buffer in `MKAudio`.
- `MKAudio` uses two pre-allocated float buffers (A/B ping-pong). Input thread writes to one, output thread reads from the other. An atomic index swap after write completion ensures the output thread always reads a complete frame.
- The output thread copies the current read buffer into `_sidechainInputBuffer` at the start of `mixFrames`.

**Thread safety**: Output-side captures (user/masterBus) and reads all happen on the same audio callback thread within `mixFrames` — no locking needed. Input signal crosses threads via the atomic ping-pong buffer in MKAudio.

**Public API on MKAudioOutput** (called by Rack bridges on the same audio thread):

```objc
/// Get pre-fader sidechain buffer for a source key. Returns NULL if not available this cycle.
/// outFrameCount and outChannels are set on success.
- (const float *) sidechainBufferForSourceKey:(NSString *)key
                                   frameCount:(NSUInteger *)outFrameCount
                                     channels:(NSUInteger *)outChannels;
```

### Layer 2: Sidechain Provider Protocol (Rack Swift Layer)

A protocol + callback that the `StageHost` uses to pull sidechain data during rendering.

```swift
/// Callback type: given a source key, returns the pre-fader float buffer (or nil for silence)
typealias SidechainBufferProvider = (_ sourceKey: String) -> (UnsafePointer<Float>, Int, Int)?
// Returns: (buffer pointer, frameCount, channels) or nil
```

Each `StageHost` receives:
- `sidechainSourceKey: String?` — which source this plugin slot wants (nil = none)
- `sidechainProvider: SidechainBufferProvider?` — closure to fetch the buffer

### Layer 3: StageHost AVAudioEngine Sidechain Wiring (*Rack.swift)

When configuring the AU engine graph, `StageHost.configureEngine()` checks if the AU has a sidechain input bus:

```swift
private func configureEngine() throws {
    // Main signal path (existing)
    sourceNode = AVAudioSourceNode { ... pull from inputBuffer ... }
    engine.attach(sourceNode)
    engine.attach(audioUnit)
    engine.connect(sourceNode, to: audioUnit, format: configuredInputFormat)

    // Sidechain path (NEW)
    if sidechainSourceKey != nil && auAudioUnit.inputBusses.count > 1 {
        let sidechainBus = auAudioUnit.inputBusses[1]
        let scFormat = try configureSidechainFormat(sidechainBus)

        sidechainSourceNode = AVAudioSourceNode { [unowned self] _, _, frameCount, abl -> OSStatus in
            self.pullSidechainData(frameCount: Int(frameCount), into: abl)
            return noErr
        }
        engine.attach(sidechainSourceNode!)
        engine.connect(sidechainSourceNode!, to: audioUnit, fromBus: 0, toBus: 1, format: scFormat)
    }

    // Output path (existing)
    engine.connect(audioUnit, to: engine.mainMixerNode, format: configuredOutputFormat)
    try engine.enableManualRenderingMode(.offline, format: configuredOutputFormat, maximumFrameCount: maximumFramesToRender)
    engine.prepare()
    try engine.start()
}
```

The `pullSidechainData` method calls the `sidechainProvider` closure with `sidechainSourceKey` and copies the returned buffer into the AU's sidechain bus buffer. If the provider returns nil (source not available/silent), it fills with zeros.

**Sidechain format negotiation**: Try the main input format first. If the AU rejects it for bus 1, try mono, then stereo. The sidechain bus format can differ from the main input format.

### Layer 4: Routing Configuration & Persistence (AudioPluginRackManager)

**Data model** — extend `PluginSlotConfiguration`:

```swift
struct PluginSlotConfiguration {
    // ... existing fields ...
    var sidechainSourceKey: String?  // nil = no sidechain
}
```

**Persistence** — stored alongside the plugin chain in UserDefaults. Each slot's dictionary gains a `"sidechainSource"` key:

```swift
["audioUnit": audioUnit, "mix": 1.0, "sidechainSource": "session:5"] as NSDictionary
```

**Sync flow**: When the user changes a sidechain source for a plugin slot, `AudioPluginRackManager` rebuilds the DSP chain with the new sidechain assignment. The chain rebuild passes sidechain keys down through the Bridge → Rack → StageHost.

### Layer 5: Bridge Layer Extensions

**MKAudioRemoteTrackRackBridge protocol** — add sidechain buffer provider:

```objc
@protocol MKAudioRemoteTrackRackExports <NSObject>
// ... existing methods ...
- (void)setSidechainBufferProvider:(id)provider;  // Swift closure wrapper
@end
```

**MKAudio orchestration** — `MKAudio.m` passes a sidechain provider to each bridge that reads from `MKAudioOutput._sidechainBuffers`. Since both run on the audio thread during `mixFrames`, no locking needed.

Alternative (simpler): Instead of a callback, MKAudio copies the sidechain buffer dictionary pointer to each bridge before processing. The bridge/rack reads from it during `processSamples`.

**Chosen approach**: Direct pointer passing. MKAudioOutput exposes `_sidechainBuffers` as a readonly property. MKAudio passes a reference to each bridge. The bridge stores it and the Swift Rack reads from it during rendering. This avoids closure overhead on the audio thread.

### Layer 6: UI (AudioPluginMixerView.swift)

Each plugin row in the mixer gains a sidechain source picker:

- **Visibility**: Only shown when the AU's `inputBusses.count > 1` (has sidechain capability)
- **Picker options**: "None" + available sources (Input, active users by display name, Master Bus 1, Master Bus 2)
- **Active user list**: Driven by `ServerModelManager.shared` hearable users (same channel + listening channels)
- **Indicator**: Small "SC" badge on the plugin row when sidechain is active
- **Persistence**: Selection stored per plugin slot in the chain configuration

### Layer 7: WebSocket Test Commands

Extend the `plugin` domain:

- `plugin.setSidechain` — **params**: `trackKey`/`session`, `pluginID`/`index`, `source` (string: source key or "none")
- `plugin.getSidechain` — **params**: `trackKey`/`session`, `pluginID`/`index` → returns current sidechain source

Existing `plugin.listTracks` and `plugin.get` responses include `sidechainSource` per plugin slot.

## Data Flow Diagram

```
                    ┌─────────────────────────────────────────┐
                    │          Sidechain Buffer Pool           │
                    │  (populated each mixFrames cycle)        │
                    │                                         │
                    │  "input"      → [float*] mic pre-AU     │
                    │  "session:5"  → [float*] user5 pre-AU   │
                    │  "session:12" → [float*] user12 pre-AU  │
                    │  "masterBus1" → [float*] bus1 pre-AU    │
                    │  "masterBus2" → [float*] bus2 pre-AU    │
                    └──────────┬──────────────────────────────┘
                               │ read by AU sidechain bus
    ┌──────────────────────────┼──────────────────────────┐
    │                          ▼                          │
    │  User 5 Track                                       │
    │  ┌─────────┐   ┌──────────────────┐   ┌─────────┐ │
    │  │ Decoded  │──▶│ Compressor (AU)  │──▶│ Mix to  │ │
    │  │ Audio    │   │ SC: "session:12" │   │ Bus 1   │ │
    │  └─────────┘   │ bus0: user5 audio │   └─────────┘ │
    │                 │ bus1: user12 audio│                │
    │                 └──────────────────┘                │
    │                                                     │
    │  Master Bus 1                                       │
    │  ┌─────────┐   ┌──────────────────┐   ┌─────────┐ │
    │  │ Mixed   │──▶│ Gate (AU)        │──▶│ Output  │ │
    │  │ Bus 1   │   │ SC: "input"      │   │         │ │
    │  └─────────┘   │ bus0: mixed audio │   └─────────┘ │
    │                 │ bus1: mic audio   │                │
    │                 └──────────────────┘                │
    └─────────────────────────────────────────────────────┘
```

## Implementation Order

1. **Sidechain Buffer Pool** — MKAudioOutput.m: add `_sidechainBuffers` dict, populate in `mixFrames:amount:`
2. **Input signal capture** — MKAudioInput.m / MKAudio.m: capture mic signal for cross-thread sharing
3. **StageHost sidechain wiring** — MKAudioRemoteTrackRack.swift + MKAudioRemoteBusRack.swift + MKAudioInputRack.swift: extend `StageHost` with sidechain AVAudioSourceNode
4. **Bridge extensions** — MKAudioRemoteTrackRackBridge / MKAudioRemoteBusRackBridge: pass sidechain provider
5. **MKAudio orchestration** — Wire sidechain buffers from output to all bridges
6. **Rack public API** — `updateAudioUnitChain` accepts sidechain keys per stage
7. **AudioPluginRackManager** — Persist sidechain assignments, pass through chain sync
8. **AudioPluginMixerView** — Sidechain source picker per plugin slot
9. **WebSocket commands** — `plugin.setSidechain` / `plugin.getSidechain`
10. **Testing** — Verify with a sidechain-capable AU (e.g., compressor with SC input)

## Edge Cases

- **AU without sidechain bus**: `inputBusses.count <= 1` → sidechain UI hidden, no extra wiring
- **Source user disconnects**: Source key becomes stale → provider returns nil → sidechain feeds silence (graceful)
- **Source user stops talking (VAD)**: Buffer not populated → provider returns nil → silence (correct behavior)
- **Self-referential sidechain**: User selects own track as sidechain source → allowed, pre-fader signal feeds back (no infinite loop since it's pre-AU)
- **Input track sidechain on output side**: Crosses input→output thread boundary → atomic pointer swap for the float buffer in MKAudio
- **Chain rebuild**: Changing sidechain source triggers full StageHost rebuild (engine stop → reconfigure → restart)
- **Plugin without sidechain gets assigned one via persistence**: Ignored at StageHost level (inputBusses check)

## Files Modified

| File | Changes |
|------|---------|
| `MumbleKit/src/MKAudioOutput.h` | Add sidechain buffer pool API |
| `MumbleKit/src/MKAudioOutput.m` | Populate sidechain buffers in mixFrames |
| `MumbleKit/src/MKAudioInput.m` | Capture pre-AU mic signal |
| `MumbleKit/src/MKAudio.h` | Expose sidechain buffer access, input signal sharing |
| `MumbleKit/src/MKAudio.m` | Wire sidechain providers to bridges |
| `MumbleKit/src/MKAudioRemoteTrackRack.swift` | StageHost sidechain AVAudioSourceNode |
| `MumbleKit/src/MKAudioRemoteBusRack.swift` | StageHost sidechain AVAudioSourceNode |
| `MumbleKit/src/MKAudioInputRack.swift` | StageHost sidechain AVAudioSourceNode |
| `MumbleKit/src/MKAudioRemoteTrackRackBridge.h/m` | Sidechain provider passthrough |
| `MumbleKit/src/MKAudioRemoteBusRackBridge.h/m` | Sidechain provider passthrough |
| `MumbleKit/src/MKAudioInputRackBridge.h/m` | Sidechain provider passthrough |
| `Source/Classes/SwiftUI/Preferences/AudioPluginRackManager.swift` | Persist sidechain keys |
| `Source/Classes/SwiftUI/Preferences/AudioPluginMixerView.swift` | Sidechain source picker UI |
| `Source/Classes/SwiftUI/Core/MUTestCommandRouter.swift` | setSidechain/getSidechain commands |
