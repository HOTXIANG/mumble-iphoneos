#import <Foundation/Foundation.h>
#import <os/lock.h>
#include <assert.h>

#undef TARGET_OS_IPHONE
#define TARGET_OS_IPHONE 1

@interface AudioSessionRecoveryFixture : NSObject {
    BOOL _audioRequested, _running, _lastNotify;
    NSUInteger _teardowns, _idleResets;
    os_unfair_lock _sidechainInputLock, _sidechainSidetoneLock, _inputMonitorLock;
    NSUInteger _sidechainInputReadPos, _sidechainInputWritePos, _sidechainInputBufferedFrames;
    NSUInteger _sidechainInputPPChannels, _sidechainInputPPSampleRate;
    NSUInteger _sidechainSidetoneReadPos, _sidechainSidetoneWritePos, _sidechainSidetoneBufferedFrames;
    NSUInteger _sidechainSidetonePPChannels, _sidechainSidetonePPSampleRate;
    NSUInteger _inputMonitorReadPos, _inputMonitorWritePos, _inputMonitorBufferedFrames;
    NSUInteger _inputMonitorPPChannels, _inputMonitorPPSampleRate;
}
- (void)stopAudioDeviceGraphLockedNotifyingOthers:(BOOL)notifyOthers;
- (void)run;
@end

@implementation AudioSessionRecoveryFixture
- (void)teardownAudioDeviceGraphLocked {
    ++_teardowns;
    _running = NO;
}
- (void)resetAudioSessionToIdleNotifyingOthers:(BOOL)notifyOthers {
    ++_idleResets;
    _lastNotify = notifyOthers;
}

// Compile the production teardown method; only hardware/session calls are mocked.
#include "MKAudioGraphStop.inc"

- (void)run {
    for (NSUInteger notify = 0; notify < 2; ++notify) {
        _audioRequested = YES;
        NSUInteger resetsBefore = _idleResets;
        for (NSUInteger restart = 0; restart < 100; ++restart) {
            _running = YES;
            _sidechainInputBufferedFrames = _sidechainSidetoneBufferedFrames = _inputMonitorBufferedFrames = 480;
            NSUInteger teardownsBefore = _teardowns;
            [self stopAudioDeviceGraphLockedNotifyingOthers:(BOOL)notify];
            assert(_teardowns == teardownsBefore + 1 && !_running);
            assert(_idleResets == resetsBefore);
            assert(!_sidechainInputBufferedFrames && !_sidechainSidetoneBufferedFrames && !_inputMonitorBufferedFrames);
        }
        _audioRequested = NO;
        [self stopAudioDeviceGraphLockedNotifyingOthers:(BOOL)notify];
        assert(_idleResets == resetsBefore + 1 && _lastNotify == (BOOL)notify);
    }
}
@end

int main(void) {
    @autoreleasepool {
        [[[AudioSessionRecoveryFixture alloc] init] run];
        puts("audio session recovery: PASS (200 graph rebuilds preserve session; explicit stops reset it)");
    }
    return 0;
}
