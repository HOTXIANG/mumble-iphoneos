# Sidechain Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add DAW-style per-plugin sidechain input routing so AU plugins with a sidechain bus (`inputBusses[1]`) can receive pre-fader audio from any other track.

**Architecture:** Pre-allocated C buffers in MKAudioOutput capture per-user and bus signals each `mixFrames` cycle. An atomic ping-pong buffer in MKAudio shares input-track audio across threads. Each `StageHost` in the three Rack classes gains an optional second `AVAudioSourceNode` connected to the AU's bus 1. Sidechain source keys are persisted per plugin slot.

**Tech Stack:** Objective-C MRC (MumbleKit), Swift 5.9 (Racks + UI), AVAudioEngine manual offline rendering, SwiftUI

**Spec:** `docs/superpowers/specs/2026-03-23-sidechain-routing-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `MumbleKit/src/MKAudioOutput.h` | Modify | Add sidechain buffer pool API |
| `MumbleKit/src/MKAudioOutput.m` | Modify | Populate sidechain buffers in mixFrames, expose lookup |
| `MumbleKit/src/MKAudioInput.m` | Modify | Capture pre-AU mic signal into ping-pong buffer |
| `MumbleKit/src/MumbleKit/MKAudio.h` | Modify | Expose sidechain buffer access, input ping-pong API |
| `MumbleKit/src/MKAudio.m` | Modify | Wire sidechain providers to bridges, manage ping-pong buffer |
| `MumbleKit/src/MKAudioRemoteTrackRack.swift` | Modify | StageHost sidechain AVAudioSourceNode + bus 1 wiring |
| `MumbleKit/src/MKAudioRemoteBusRack.swift` | Modify | StageHost sidechain AVAudioSourceNode + bus 1 wiring |
| `MumbleKit/src/MKAudioInputRack.swift` | Modify | StageHost sidechain AVAudioSourceNode + bus 1 wiring |
| `MumbleKit/src/MKAudioRemoteTrackRackBridge.h` | Modify | Add setSidechainProvider method |
| `MumbleKit/src/MKAudioRemoteTrackRackBridge.m` | Modify | Forward sidechain provider to Swift rack |
| `MumbleKit/src/MKAudioRemoteBusRackBridge.h` | Modify | Add setSidechainProvider method |
| `MumbleKit/src/MKAudioRemoteBusRackBridge.m` | Modify | Forward sidechain provider to Swift rack |
| `MumbleKit/src/MKAudioInputRackBridge.h` | Modify | Add setSidechainProvider method |
| `MumbleKit/src/MKAudioInputRackBridge.m` | Modify | Forward sidechain provider to Swift rack |
| `Source/Classes/SwiftUI/Preferences/AudioPluginMixerView.swift` | Modify | Sidechain source picker UI per plugin slot |
| `Source/Classes/SwiftUI/Preferences/AudioPluginRackManager.swift` | Modify | Persist sidechain keys, pass through chain sync |
| `Source/Classes/SwiftUI/Core/MUTestCommandRouter.swift` | Modify | plugin.setSidechain / plugin.getSidechain commands |

---

## Task 1: Sidechain Buffer Pool in MKAudioOutput

Add pre-allocated C buffers to MKAudioOutput and populate them each `mixFrames` cycle.

**Files:**
- Modify: `MumbleKit/src/MKAudioOutput.h`
- Modify: `MumbleKit/src/MKAudioOutput.m`

- [ ] **Step 1: Add sidechain buffer struct and ivars to MKAudioOutput.h**

Add after the existing `@interface` declaration:

```objc
// In MKAudioOutput.h — add before @interface

#define MK_SIDECHAIN_MAX_SESSIONS 64
#define MK_SIDECHAIN_MAX_FRAMES   4096

struct MKSidechainSlot {
    float    buffer[MK_SIDECHAIN_MAX_FRAMES * 2];  // max stereo
    NSUInteger session;
    BOOL     valid;
};
```

Add new methods to the `@interface`:

```objc
/// Get pre-fader sidechain buffer for a source key. Returns NULL if source not available this cycle.
- (const float *) sidechainBufferForSourceKey:(NSString *)key
                                   frameCount:(NSUInteger *)outFrameCount
                                     channels:(NSUInteger *)outChannels;

/// Set the input track sidechain buffer pointer (set by MKAudio from input thread ping-pong)
- (void) setSidechainInputBuffer:(const float *)buffer frameCount:(NSUInteger)frameCount channels:(NSUInteger)channels;
```

- [ ] **Step 2: Add sidechain ivars to MKAudioOutput.m private interface**

In the `@interface MKAudioOutput()` or ivar block in MKAudioOutput.m, add:

```objc
struct MKSidechainSlot _sidechainUserSlots[MK_SIDECHAIN_MAX_SESSIONS];
float    _sidechainMasterBus1[MK_SIDECHAIN_MAX_FRAMES * 2];
float    _sidechainMasterBus2[MK_SIDECHAIN_MAX_FRAMES * 2];
BOOL     _sidechainMasterBus1Valid;
BOOL     _sidechainMasterBus2Valid;
const float *_sidechainInputBuffer;
NSUInteger   _sidechainInputFrameCount;
NSUInteger   _sidechainInputChannels;
NSUInteger   _sidechainFrameCount;
NSUInteger   _sidechainChannels;
```

- [ ] **Step 3: Populate sidechain buffers in mixFrames:amount:**

In `mixFrames:amount:`, add capture points:

**At the top of the mix loop** (after `nsamp` and `_numChannels` are known):
```objc
// Reset sidechain validity flags
for (int si = 0; si < MK_SIDECHAIN_MAX_SESSIONS; si++) {
    _sidechainUserSlots[si].valid = NO;
}
_sidechainMasterBus1Valid = NO;
_sidechainMasterBus2Valid = NO;
_sidechainFrameCount = nsamp;
_sidechainChannels = _numChannels;
```

**Per-user, before trackProcessor call** (after `float *userBuffer = [ou buffer];`):
```objc
// Capture pre-fader sidechain snapshot
if (nsamp <= MK_SIDECHAIN_MAX_FRAMES) {
    for (int si = 0; si < MK_SIDECHAIN_MAX_SESSIONS; si++) {
        if (_sidechainUserSlots[si].session == sessionID || !_sidechainUserSlots[si].valid) {
            _sidechainUserSlots[si].session = sessionID;
            _sidechainUserSlots[si].valid = YES;
            memcpy(_sidechainUserSlots[si].buffer, userBuffer, sizeof(float) * nsamp * sourceChannels);
            break;
        }
    }
}
```

**After mixBuffer1/mixBuffer2 accumulation, before bus processors**:
```objc
if (nsamp <= MK_SIDECHAIN_MAX_FRAMES) {
    memcpy(_sidechainMasterBus1, mixBuffer1, bufferBytes);
    _sidechainMasterBus1Valid = YES;
    memcpy(_sidechainMasterBus2, mixBuffer2, bufferBytes);
    _sidechainMasterBus2Valid = YES;
}
```

- [ ] **Step 4: Implement sidechainBufferForSourceKey: and setSidechainInputBuffer:**

```objc
- (const float *) sidechainBufferForSourceKey:(NSString *)key
                                   frameCount:(NSUInteger *)outFrameCount
                                     channels:(NSUInteger *)outChannels {
    if (key == nil) return NULL;

    if ([key isEqualToString:@"input"]) {
        if (_sidechainInputBuffer != NULL && _sidechainInputFrameCount > 0) {
            *outFrameCount = _sidechainInputFrameCount;
            *outChannels = _sidechainInputChannels;
            return _sidechainInputBuffer;
        }
        return NULL;
    }

    if ([key isEqualToString:@"masterBus1"]) {
        if (_sidechainMasterBus1Valid) {
            *outFrameCount = _sidechainFrameCount;
            *outChannels = _sidechainChannels;
            return _sidechainMasterBus1;
        }
        return NULL;
    }

    if ([key isEqualToString:@"masterBus2"]) {
        if (_sidechainMasterBus2Valid) {
            *outFrameCount = _sidechainFrameCount;
            *outChannels = _sidechainChannels;
            return _sidechainMasterBus2;
        }
        return NULL;
    }

    // "session:NNN"
    if ([key hasPrefix:@"session:"]) {
        NSUInteger session = [[key substringFromIndex:8] integerValue];
        for (int si = 0; si < MK_SIDECHAIN_MAX_SESSIONS; si++) {
            if (_sidechainUserSlots[si].valid && _sidechainUserSlots[si].session == session) {
                *outFrameCount = _sidechainFrameCount;
                *outChannels = _sidechainChannels;
                return _sidechainUserSlots[si].buffer;
            }
        }
    }

    return NULL;
}

- (void) setSidechainInputBuffer:(const float *)buffer frameCount:(NSUInteger)frameCount channels:(NSUInteger)channels {
    _sidechainInputBuffer = buffer;
    _sidechainInputFrameCount = frameCount;
    _sidechainInputChannels = channels;
}
```

- [ ] **Step 5: Build MumbleKit and verify**

Run: `xcodebuild -scheme "MumbleKit (Mac)" -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add MumbleKit/src/MKAudioOutput.h MumbleKit/src/MKAudioOutput.m
git commit -m "feat: sidechain buffer pool in MKAudioOutput"
```

---

## Task 2: Input Track Ping-Pong Buffer in MKAudio

Capture the mic signal on the input thread and share it to the output thread via atomic double-buffering.

**Files:**
- Modify: `MumbleKit/src/MumbleKit/MKAudio.h`
- Modify: `MumbleKit/src/MKAudio.m`
- Modify: `MumbleKit/src/MKAudioInput.m`

- [ ] **Step 1: Add ping-pong buffer to MKAudio.m ivars**

```objc
// Input sidechain ping-pong buffer (written by input thread, read by output thread)
float    *_sidechainInputPingPong[2];  // two pre-allocated buffers
volatile int32_t _sidechainInputWriteIndex;  // 0 or 1, atomically swapped
NSUInteger _sidechainInputPPFrameCount;
NSUInteger _sidechainInputPPChannels;
NSUInteger _sidechainInputPPSampleRate;
```

- [ ] **Step 2: Allocate and free ping-pong buffers in MKAudio init/dealloc**

In `init` (or `_setupAudio`):
```objc
_sidechainInputPingPong[0] = calloc(MK_SIDECHAIN_MAX_FRAMES * 2, sizeof(float));
_sidechainInputPingPong[1] = calloc(MK_SIDECHAIN_MAX_FRAMES * 2, sizeof(float));
_sidechainInputWriteIndex = 0;
```

In `dealloc`:
```objc
free(_sidechainInputPingPong[0]);
free(_sidechainInputPingPong[1]);
```

- [ ] **Step 3: Add public API to MKAudio.h**

```objc
/// Called by MKAudioInput on input thread to write mic signal for sidechain use
- (void) writeSidechainInputSamples:(const float *)samples frameCount:(NSUInteger)frameCount channels:(NSUInteger)channels;

/// Called by MKAudioOutput on output thread to get the latest input sidechain buffer
- (const float *) readSidechainInputBufferWithFrameCount:(NSUInteger *)outFrameCount channels:(NSUInteger *)outChannels;
```

- [ ] **Step 4: Implement ping-pong read/write in MKAudio.m**

```objc
- (void) writeSidechainInputSamples:(const float *)samples frameCount:(NSUInteger)frameCount channels:(NSUInteger)channels {
    if (samples == NULL || frameCount == 0 || frameCount > MK_SIDECHAIN_MAX_FRAMES) return;
    int32_t writeIdx = _sidechainInputWriteIndex;
    memcpy(_sidechainInputPingPong[writeIdx], samples, frameCount * channels * sizeof(float));
    _sidechainInputPPFrameCount = frameCount;
    _sidechainInputPPChannels = channels;
    // Atomic swap: readers now see the freshly written buffer
    OSAtomicCompareAndSwap32(writeIdx, 1 - writeIdx, &_sidechainInputWriteIndex);
}

- (const float *) readSidechainInputBufferWithFrameCount:(NSUInteger *)outFrameCount channels:(NSUInteger *)outChannels {
    if (_sidechainInputPPFrameCount == 0) return NULL;
    // Read from the buffer NOT currently being written to
    int32_t readIdx = 1 - _sidechainInputWriteIndex;
    *outFrameCount = _sidechainInputPPFrameCount;
    *outChannels = _sidechainInputPPChannels;
    return _sidechainInputPingPong[readIdx];
}
```

- [ ] **Step 5: Capture mic signal in MKAudioInput.m**

In `processAndEncodeAudioFrame`, after the Int16 frame is ready (after Speex/gain, before `_inputTrackProcessor`), add:

```objc
// Capture pre-AU mic signal for sidechain (convert Int16 → Float)
{
    MKAudio *audio = [MKAudio sharedAudio];
    if (audio != nil) {
        float scBuf[MK_SIDECHAIN_MAX_FRAMES * 2];
        NSUInteger scCount = MIN((NSUInteger)frameSize, (NSUInteger)MK_SIDECHAIN_MAX_FRAMES);
        for (NSUInteger si = 0; si < scCount * encodeChannels; si++) {
            scBuf[si] = (float)frame[si] / 32768.0f;
        }
        [audio writeSidechainInputSamples:scBuf frameCount:scCount channels:encodeChannels];
    }
}
```

- [ ] **Step 6: Feed input sidechain to MKAudioOutput each mixFrames cycle**

In MKAudio.m, in the audio output callback path (or at the start of `mixFrames`), add a step where `MKAudioOutput` reads the ping-pong buffer. Best approach: in `mixFrames:amount:` of MKAudioOutput, at the top:

```objc
// Update input sidechain from ping-pong buffer
{
    MKAudio *audio = [MKAudio sharedAudio];
    if (audio != nil) {
        NSUInteger scFrames = 0, scChannels = 0;
        const float *scBuf = [audio readSidechainInputBufferWithFrameCount:&scFrames channels:&scChannels];
        [self setSidechainInputBuffer:scBuf frameCount:scFrames channels:scChannels];
    }
}
```

- [ ] **Step 7: Build and verify**

Run: `xcodebuild -scheme "MumbleKit (Mac)" -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 8: Commit**

```bash
git add MumbleKit/src/MumbleKit/MKAudio.h MumbleKit/src/MKAudio.m MumbleKit/src/MKAudioInput.m MumbleKit/src/MKAudioOutput.m
git commit -m "feat: input track ping-pong buffer for cross-thread sidechain"
```

---

## Task 3: StageHost Sidechain Wiring in All Three Racks

Extend `StageHost` in `MKAudioRemoteTrackRack.swift`, `MKAudioRemoteBusRack.swift`, and `MKAudioInputRack.swift` to support an optional sidechain AVAudioSourceNode connected to AU bus 1.

All three files use the identical `StageHost` pattern. The changes are the same for each.

**Files:**
- Modify: `MumbleKit/src/MKAudioRemoteTrackRack.swift`
- Modify: `MumbleKit/src/MKAudioRemoteBusRack.swift`
- Modify: `MumbleKit/src/MKAudioInputRack.swift`

- [ ] **Step 1: Add sidechain callback type and properties to StageHost**

In each file's `StageHost` class, add:

```swift
// New properties
var sidechainSourceKey: String?
var sidechainProvider: ((_ key: String) -> (UnsafePointer<Float>, Int, Int)?)?
private var sidechainSourceNode: AVAudioSourceNode?
private var sidechainBuffer: AVAudioPCMBuffer?
private var sidechainPullOffset: Int = 0
```

- [ ] **Step 2: Extend StageHost init to accept sidechain parameters**

Add `sidechainSourceKey` and `sidechainProvider` parameters to `StageHost.init()`:

```swift
init(audioUnit: AVAudioUnit, wetDryMix: Float, preferredChannels: AVAudioChannelCount,
     sampleRate: Double, hostBufferFrames: Int,
     sidechainSourceKey: String? = nil,
     sidechainProvider: ((_ key: String) -> (UnsafePointer<Float>, Int, Int)?)? = nil) throws {
    // ... existing init code ...
    self.sidechainSourceKey = sidechainSourceKey
    self.sidechainProvider = sidechainProvider
    // ... rest of init ...
}
```

- [ ] **Step 3: Extend configureEngine() with sidechain bus 1 wiring**

After `engine.connect(sourceNode, to: audioUnit, format: configuredInputFormat)`, add:

```swift
// Sidechain path: connect second source to AU bus 1 if AU supports it and source is configured
if let scKey = sidechainSourceKey, !scKey.isEmpty, auAudioUnit.inputBusses.count > 1 {
    let scBus = auAudioUnit.inputBusses[1]
    // Try to set sidechain format (same as main input, fallback to mono)
    let scFormat: AVAudioFormat
    do {
        try scBus.setFormat(configuredInputFormat)
        scFormat = scBus.format
    } catch {
        let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: configuredInputFormat.sampleRate,
                                        channels: 1, interleaved: true)!
        do {
            try scBus.setFormat(monoFormat)
            scFormat = scBus.format
        } catch {
            scFormat = scBus.format // use whatever the AU defaults to
        }
    }

    if let scInputBuf = AVAudioPCMBuffer(pcmFormat: scFormat, frameCapacity: maximumFramesToRender) {
        sidechainBuffer = scInputBuf

        sidechainSourceNode = AVAudioSourceNode { [unowned self] _, _, frameCount, audioBufferList -> OSStatus in
            self.pullSidechainData(frameCount: Int(frameCount), into: audioBufferList)
            return noErr
        }
        engine.attach(sidechainSourceNode!)
        engine.connect(sidechainSourceNode!, to: audioUnit, fromBus: 0, toBus: 1, format: scFormat)
    }
}
```

- [ ] **Step 4: Add pullSidechainData helper method to StageHost**

```swift
private func pullSidechainData(frameCount: Int, into audioBufferList: UnsafeMutablePointer<AudioBufferList>) {
    let targetBuffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
    guard let scKey = sidechainSourceKey,
          let provider = sidechainProvider,
          let (srcPtr, srcFrames, srcChannels) = provider(scKey) else {
        // No source available — fill with silence
        for bufIdx in 0..<targetBuffers.count {
            guard let data = targetBuffers[bufIdx].mData else { continue }
            memset(data, 0, Int(targetBuffers[bufIdx].mDataByteSize))
        }
        return
    }

    // Copy source data into sidechain buffer, handling channel mismatch
    guard let scBuf = sidechainBuffer else {
        for bufIdx in 0..<targetBuffers.count {
            guard let data = targetBuffers[bufIdx].mData else { continue }
            memset(data, 0, Int(targetBuffers[bufIdx].mDataByteSize))
        }
        return
    }

    let framesToCopy = min(frameCount, srcFrames)
    let scChannels = Int(scBuf.format.channelCount)
    let bytesPerFrame = MemoryLayout<Float>.size

    if scBuf.format.isInterleaved {
        guard let targetData = targetBuffers[0].mData else { return }
        let dst = targetData.assumingMemoryBound(to: Float.self)
        for f in 0..<framesToCopy {
            for c in 0..<scChannels {
                let srcCh = min(c, srcChannels - 1)
                dst[f * scChannels + c] = srcPtr[f * srcChannels + srcCh]
            }
        }
        // Zero remaining
        if framesToCopy < frameCount {
            memset(targetData.advanced(by: framesToCopy * scChannels * bytesPerFrame), 0,
                   (frameCount - framesToCopy) * scChannels * bytesPerFrame)
        }
        targetBuffers[0].mDataByteSize = UInt32(frameCount * scChannels * bytesPerFrame)
    } else {
        for bufIdx in 0..<targetBuffers.count {
            guard let data = targetBuffers[bufIdx].mData else { continue }
            let dst = data.assumingMemoryBound(to: Float.self)
            let srcCh = min(bufIdx, srcChannels - 1)
            for f in 0..<framesToCopy {
                dst[f] = srcPtr[f * srcChannels + srcCh]
            }
            if framesToCopy < frameCount {
                memset(data.advanced(by: framesToCopy * bytesPerFrame), 0,
                       (frameCount - framesToCopy) * bytesPerFrame)
            }
            targetBuffers[bufIdx].mDataByteSize = UInt32(frameCount * bytesPerFrame)
        }
    }
}
```

- [ ] **Step 5: Update deinit to detach sidechain node**

In `StageHost.deinit`, before `engine.stop()`:
```swift
// (engine.stop() will handle detaching, but clear references)
sidechainSourceNode = nil
sidechainBuffer = nil
```

- [ ] **Step 6: Update probeSummary to include sidechain info**

```swift
var probeSummary: String {
    let inLayout = configuredInputFormat.isInterleaved ? "i" : "ni"
    let outLayout = configuredOutputFormat.isInterleaved ? "i" : "ni"
    let manualFormat = engine.manualRenderingFormat
    let manualLayout = manualFormat.isInterleaved ? "i" : "ni"
    let scInfo = sidechainSourceKey.map { " sc=\($0)" } ?? ""
    return "in=\(configuredInputFormat.channelCount)ch@\(Int(configuredInputFormat.sampleRate))/\(inLayout) out=\(configuredOutputFormat.channelCount)ch@\(Int(configuredOutputFormat.sampleRate))/\(outLayout) manual=\(manualFormat.channelCount)ch@\(Int(manualFormat.sampleRate))/\(manualLayout) max=\(maximumFramesToRender)\(scInfo)"
}
```

- [ ] **Step 7: Update StageConfiguration to include sidechain key**

In each file's `StageConfiguration` struct:
```swift
private struct StageConfiguration {
    let processor: StageProcessor
    let wetDryMix: Float
    let sidechainSourceKey: String?  // NEW
}
```

- [ ] **Step 8: Update normalizeStages to extract sidechain key from NSDictionary**

In the dictionary parsing branch of `normalizeStages`:
```swift
let sidechainSource = dictionary["sidechainSource"] as? String
// ... use in StageConfiguration init
normalized.append(StageConfiguration(processor: .audioUnit(audioUnit),
                                      wetDryMix: ...,
                                      sidechainSourceKey: sidechainSource))
```

For bare AVAudioUnit (not dict), use `sidechainSourceKey: nil`.

- [ ] **Step 9: Update buildStageHosts to pass sidechain params**

In `buildStageHosts`, pass through:
```swift
case .audioUnit(let audioUnit):
    let host = try StageHost(audioUnit: audioUnit,
                              wetDryMix: configuration.wetDryMix,
                              preferredChannels: 2,
                              sampleRate: sampleRate,
                              hostBufferFrames: hostBufferFrames,
                              sidechainSourceKey: configuration.sidechainSourceKey,
                              sidechainProvider: sidechainProvider)
```

Where `sidechainProvider` is a new instance property on the Rack class:
```swift
var sidechainProvider: ((_ key: String) -> (UnsafePointer<Float>, Int, Int)?)? = nil
```

- [ ] **Step 10: Apply all changes to all three Rack files**

Repeat steps 1-9 for:
1. `MKAudioRemoteTrackRack.swift`
2. `MKAudioRemoteBusRack.swift`
3. `MKAudioInputRack.swift`

The `MKAudioInputRack.swift` StageHost uses Int16 input, but sidechain is always Float — the sidechain wiring is identical.

- [ ] **Step 11: Build and verify**

Run: `xcodebuild -scheme "MumbleKit (Mac)" -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 12: Commit**

```bash
git add MumbleKit/src/MKAudioRemoteTrackRack.swift MumbleKit/src/MKAudioRemoteBusRack.swift MumbleKit/src/MKAudioInputRack.swift
git commit -m "feat: StageHost sidechain AVAudioSourceNode wiring in all three racks"
```

---

## Task 4: Bridge Layer Sidechain Provider

Extend all three Bridge classes to accept and forward a sidechain provider.

**Files:**
- Modify: `MumbleKit/src/MKAudioRemoteTrackRackBridge.h`
- Modify: `MumbleKit/src/MKAudioRemoteTrackRackBridge.m`
- Modify: `MumbleKit/src/MKAudioRemoteBusRackBridge.h`
- Modify: `MumbleKit/src/MKAudioRemoteBusRackBridge.m`
- Modify: `MumbleKit/src/MKAudioInputRackBridge.h`
- Modify: `MumbleKit/src/MKAudioInputRackBridge.m`

- [ ] **Step 1: Add sidechain provider property to Bridge headers**

In each Bridge `.h`, add:

```objc
/// Set the MKAudioOutput reference for sidechain buffer lookup.
/// Called by MKAudio before each processing cycle.
@property (nonatomic, assign) MKAudioOutput *sidechainAudioOutput;
```

- [ ] **Step 2: Add setSidechainAudioOutput: to Bridge protocol**

In each Bridge `.m`, extend the protocol:
```objc
@protocol MKAudioRemoteTrackRackExports <NSObject>
// ... existing ...
- (void)setSidechainProvider:(id)provider;
@end
```

- [ ] **Step 3: Implement forwarding in Bridge .m**

When `sidechainAudioOutput` is set, create a wrapper block and forward to the Swift rack:

```objc
- (void)setSidechainAudioOutput:(MKAudioOutput *)output {
    _sidechainAudioOutput = output;
    if (output == nil) {
        [_rack setSidechainProvider:nil];
        return;
    }
    // The block captures the raw output pointer (no retain in MRC audio path)
    id provider = [^(NSString *key) -> NSDictionary * {
        NSUInteger frameCount = 0, channels = 0;
        const float *buf = [output sidechainBufferForSourceKey:key frameCount:&frameCount channels:&channels];
        if (buf == NULL) return nil;
        return @{
            @"ptr": [NSValue valueWithPointer:buf],
            @"frames": @(frameCount),
            @"channels": @(channels)
        };
    } copy];
    [_rack setSidechainProvider:provider];
    [provider release];
}
```

- [ ] **Step 4: In Swift Rack, add setSidechainProvider method**

In each Rack Swift class, add:

```swift
func setSidechainProvider(_ provider: Any?) {
    guard let block = provider as? (String) -> NSDictionary? else {
        sidechainProvider = nil
        return
    }
    sidechainProvider = { key in
        guard let dict = block(key),
              let ptrValue = dict["ptr"] as? NSValue,
              let frames = dict["frames"] as? Int,
              let channels = dict["channels"] as? Int else {
            return nil
        }
        let ptr = ptrValue.pointerValue!.assumingMemoryBound(to: Float.self)
        return (UnsafePointer(ptr), frames, channels)
    }
}
```

- [ ] **Step 5: Build and verify**

Run: `xcodebuild -scheme "MumbleKit (Mac)" -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add MumbleKit/src/MKAudio*RackBridge.h MumbleKit/src/MKAudio*RackBridge.m MumbleKit/src/MKAudio*Rack.swift
git commit -m "feat: bridge layer sidechain provider forwarding"
```

---

## Task 5: MKAudio Orchestration

Wire the sidechain buffer pool from MKAudioOutput to all bridges.

**Files:**
- Modify: `MumbleKit/src/MKAudio.m`

- [ ] **Step 1: Set sidechainAudioOutput on all bridges when audio starts**

In MKAudio.m `_startAudio` or equivalent, after `_audioOutput` is created:

```objc
// Wire sidechain providers
[_inputTrackRackBridge setSidechainAudioOutput:_audioOutput];
[_remoteBusRackBridge setSidechainAudioOutput:_audioOutput];
[_remoteBusRackBridge2 setSidechainAudioOutput:_audioOutput];
```

In `rebindRemoteTrackProcessorsToOutputLocked`, for each bridge:
```objc
[bridge setSidechainAudioOutput:_audioOutput];
```

- [ ] **Step 2: Clear sidechain references when audio stops**

In `_teardownAudio` or equivalent:
```objc
[_inputTrackRackBridge setSidechainAudioOutput:nil];
[_remoteBusRackBridge setSidechainAudioOutput:nil];
[_remoteBusRackBridge2 setSidechainAudioOutput:nil];
for (NSNumber *sessionKey in _remoteTrackRackBridges) {
    MKAudioRemoteTrackRackBridge *bridge = [_remoteTrackRackBridges objectForKey:sessionKey];
    [bridge setSidechainAudioOutput:nil];
}
```

- [ ] **Step 3: Build and verify**

Run: `xcodebuild -scheme "MumbleKit (Mac)" -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add MumbleKit/src/MKAudio.m
git commit -m "feat: wire sidechain buffer pool to all rack bridges"
```

---

## Task 6: Chain API — Pass Sidechain Keys Through

Extend `updateAudioUnitChain` to carry sidechain source keys per stage, and extend `AudioPluginRackManager` + `TrackPlugin` to persist them.

**Files:**
- Modify: `Source/Classes/SwiftUI/Preferences/AudioPluginMixerView.swift` (TrackPlugin struct)
- Modify: `Source/Classes/SwiftUI/Preferences/AudioPluginRackManager.swift`

- [ ] **Step 1: Add `sidechainSourceKey` to TrackPlugin**

In `AudioPluginMixerView.swift`, extend `TrackPlugin`:

```swift
struct TrackPlugin: Identifiable, Codable, Hashable {
    // ... existing fields ...
    var sidechainSourceKey: String?  // NEW — nil means no sidechain

    enum CodingKeys: String, CodingKey {
        // ... existing cases ...
        case sidechainSourceKey
    }
}
```

Update `init` to include `sidechainSourceKey: String? = nil` parameter with default.

- [ ] **Step 2: Pass sidechain keys in activeProcessorChain**

In `AudioPluginRackManager.swift`, modify `activeProcessorChain(for:)`:

```swift
private func activeProcessorChain(for key: String) -> [NSDictionary] {
    let chain = pluginChainByTrack[key] ?? []
    return chain
        .filter { !$0.bypassed }
        .compactMap { plugin in
            let loadedKey = loadedAudioUnitKey(trackKey: key, pluginID: plugin.id)
            let mix = NSNumber(value: min(max(plugin.stageGain, 0.0), 1.0))

            if let audioUnit = loadedAudioUnits[loadedKey] {
                var dict: [String: Any] = ["audioUnit": audioUnit, "mix": mix]
                if let sc = plugin.sidechainSourceKey, !sc.isEmpty {
                    dict["sidechainSource"] = sc
                }
                return dict as NSDictionary
            } else if let vst3Host = loadedVST3Hosts[loadedKey] {
                return ["vst3Host": vst3Host, "mix": mix] as NSDictionary
                // VST3 sidechain not supported yet
            }
            return nil
        }
}
```

- [ ] **Step 3: Add setSidechainSource method to AudioPluginRackManager**

```swift
func setSidechainSource(_ sourceKey: String?, forPluginID pluginID: String, inTrack trackKey: String) {
    guard var chain = pluginChainByTrack[trackKey],
          let index = chain.firstIndex(where: { $0.id == pluginID }) else { return }
    chain[index].sidechainSourceKey = sourceKey
    pluginChainByTrack[trackKey] = chain
    savePluginChainState()
    syncDSPChain(for: trackKey)
}
```

- [ ] **Step 4: Build full app and verify**

Run: `xcodebuild -target Mumble -destination 'platform=macOS' build ARCHS=arm64 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Source/Classes/SwiftUI/Preferences/AudioPluginMixerView.swift Source/Classes/SwiftUI/Preferences/AudioPluginRackManager.swift
git commit -m "feat: sidechain source key persistence and chain sync"
```

---

## Task 7: Sidechain Source Picker UI

Add a sidechain source selector to each plugin row in the mixer.

**Files:**
- Modify: `Source/Classes/SwiftUI/Preferences/AudioPluginMixerView.swift`

- [ ] **Step 1: Add helper to detect if AU has sidechain bus**

```swift
private func auHasSidechainInput(plugin: TrackPlugin, trackKey: String) -> Bool {
    let loadedKey = rackManager.loadedAudioUnitKey(trackKey: trackKey, pluginID: plugin.id)
    guard let au = rackManager.loadedAudioUnits[loadedKey] else { return false }
    return au.auAudioUnit.inputBusses.count > 1
}
```

- [ ] **Step 2: Build available sidechain sources list**

```swift
private func availableSidechainSources() -> [(key: String, label: String)] {
    var sources: [(key: String, label: String)] = [("", "None")]
    sources.append(("input", "Input (Mic)"))

    // Active users from ServerModelManager
    if let manager = ServerModelManager.shared {
        for item in manager.modelItems {
            if case .user(let user) = item.content {
                let name = manager.displayName(for: user)
                sources.append(("session:\(user.session())", name))
            }
        }
    }

    sources.append(("masterBus1", "Master Bus 1"))
    sources.append(("masterBus2", "Master Bus 2"))
    return sources
}
```

- [ ] **Step 3: Add sidechain picker to plugin row**

In the plugin row view (where bypass/gain controls are), add:

```swift
if auHasSidechainInput(plugin: plugin, trackKey: trackKey) {
    HStack(spacing: 4) {
        Text("SC")
            .font(.caption2)
            .foregroundStyle(plugin.sidechainSourceKey != nil && !plugin.sidechainSourceKey!.isEmpty ? .orange : .secondary)
        Picker("", selection: sidechainBinding(for: plugin, trackKey: trackKey)) {
            ForEach(availableSidechainSources(), id: \.key) { source in
                Text(source.label).tag(source.key)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 120)
    }
}
```

- [ ] **Step 4: Add binding helper**

```swift
private func sidechainBinding(for plugin: TrackPlugin, trackKey: String) -> Binding<String> {
    Binding<String>(
        get: { plugin.sidechainSourceKey ?? "" },
        set: { newValue in
            let key = newValue.isEmpty ? nil : newValue
            rackManager.setSidechainSource(key, forPluginID: plugin.id, inTrack: trackKey)
        }
    )
}
```

- [ ] **Step 5: Build and verify both platforms**

Run:
```bash
xcodebuild -target Mumble -destination 'platform=macOS' build ARCHS=arm64 2>&1 | tail -5
xcodebuild -target Mumble -destination 'generic/platform=iOS' build ARCHS=arm64 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED (both)

- [ ] **Step 6: Commit**

```bash
git add Source/Classes/SwiftUI/Preferences/AudioPluginMixerView.swift
git commit -m "feat: sidechain source picker UI per plugin slot"
```

---

## Task 8: WebSocket Test Commands

Add `plugin.setSidechain` and `plugin.getSidechain` commands.

**Files:**
- Modify: `Source/Classes/SwiftUI/Core/MUTestCommandRouter.swift`

- [ ] **Step 1: Add setSidechain command handler**

In the `handlePlugin` switch, add:

```swift
case "setSidechain":
    guard let trackKey = resolvedTrackKey else { throw TestCommandError("Missing 'trackKey' or 'session'") }
    guard let source = params["source"] as? String else { throw TestCommandError("Missing 'source'") }
    let pluginID = try resolvePluginID(params: params, trackKey: trackKey)
    let sourceKey = source == "none" ? nil : source
    await AudioPluginRackManager.shared.setSidechainSource(sourceKey, forPluginID: pluginID, inTrack: trackKey)
    return ["trackKey": trackKey, "pluginID": pluginID, "sidechainSource": source]

case "getSidechain":
    guard let trackKey = resolvedTrackKey else { throw TestCommandError("Missing 'trackKey' or 'session'") }
    let pluginID = try resolvePluginID(params: params, trackKey: trackKey)
    let chain = AudioPluginRackManager.shared.pluginChainByTrack[trackKey] ?? []
    guard let plugin = chain.first(where: { $0.id == pluginID }) else {
        throw TestCommandError("Plugin not found")
    }
    return ["trackKey": trackKey, "pluginID": pluginID, "sidechainSource": plugin.sidechainSourceKey ?? "none"]
```

- [ ] **Step 2: Update help.actions to include new commands**

In `handleHelp`, add to the plugin section:
```swift
"plugin.setSidechain — Set sidechain source for a plugin slot (params: trackKey/session, pluginID/index, source)",
"plugin.getSidechain — Get sidechain source for a plugin slot (params: trackKey/session, pluginID/index)",
```

- [ ] **Step 3: Include sidechainSource in plugin.listTracks and plugin.get responses**

In the existing `plugin.listTracks` / `plugin.get` response building, add `"sidechainSource"` to each plugin dict.

- [ ] **Step 4: Build and verify**

Run: `xcodebuild -target Mumble -destination 'platform=macOS' build ARCHS=arm64 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Source/Classes/SwiftUI/Core/MUTestCommandRouter.swift
git commit -m "feat: WebSocket plugin.setSidechain/getSidechain commands"
```

---

## Task 9: Integration Test via WebSocket

Connect via WebSocket and verify sidechain routing works end-to-end.

- [ ] **Step 1: Run the app in Debug mode via Xcode**

- [ ] **Step 2: Connect via websocat**

```bash
websocat ws://localhost:54296
```

- [ ] **Step 3: Enable log streaming for Audio and Plugin categories**

```json
{"action": "log.stream", "params": {"enabled": true, "categories": ["Audio", "Plugin"], "minimumLevel": "debug"}}
```

- [ ] **Step 4: Connect to a server with other users**

```json
{"action": "connection.connect", "params": {"host": "YOUR_SERVER", "port": 64738, "username": "TestUser"}}
```

- [ ] **Step 5: Add a sidechain-capable AU to Master Bus 1**

```json
{"action": "plugin.add", "params": {"trackKey": "masterBus1", "identifier": "YOUR_COMPRESSOR_AU_ID"}}
```

- [ ] **Step 6: Set sidechain source to a specific user**

```json
{"action": "plugin.setSidechain", "params": {"trackKey": "masterBus1", "index": 0, "source": "session:5"}}
```

- [ ] **Step 7: Verify in logs**

Look for log entries showing:
- StageHost configured with `sc=session:5` in probeSummary
- AU inputBusses[1] format set successfully
- Sidechain data being pulled during render

- [ ] **Step 8: Verify getSidechain command**

```json
{"action": "plugin.getSidechain", "params": {"trackKey": "masterBus1", "index": 0}}
```

Expected response: `{"success": true, "data": {"sidechainSource": "session:5"}}`

---

## Task 10: Update Documentation

- [ ] **Step 1: Update MIXER_ARCHITECTURE.md**

Add a "Sidechain Routing" section describing the buffer pool, per-plugin sidechain sources, and supported source types.

- [ ] **Step 2: Update docs/TESTING.md**

Add `plugin.setSidechain` and `plugin.getSidechain` to the command reference.

- [ ] **Step 3: Update CLAUDE.md**

Add sidechain routing to the "已实现" feature list and the DAW / AU 插件专项说明 section.

- [ ] **Step 4: Commit**

```bash
git add MIXER_ARCHITECTURE.md docs/TESTING.md CLAUDE.md
git commit -m "docs: sidechain routing documentation"
```
