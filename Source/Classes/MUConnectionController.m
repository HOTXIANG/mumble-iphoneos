// Copyright 2009-2011 The 'Mumble for iOS' Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import "MUConnectionController.h"
#import "MUConnectionRecoveryPolicy.h"
#import "MUCertificateController.h"
#import "MUCertificateChainBuilder.h"
#import "MUDatabase.h"
#import "Mumble-Swift.h"

#import <MumbleKit/MKAudio.h>
#import <MumbleKit/MKConnection.h>
#import <MumbleKit/MKServerModel.h>
#import <MumbleKit/MKCertificate.h>
#import <AVFoundation/AVFoundation.h>
#import <UserNotifications/UserNotifications.h>
#import <Network/Network.h>
#import <QuartzCore/QuartzCore.h>
#include <math.h>
#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#else
#import <AppKit/AppKit.h>
#endif
@import Security;

@interface MKAudio (MUMuteStateRestore)
- (void)setSelfMuted:(BOOL)selfMuted;
@end

NSString *MUConnectionOpenedNotification = @"MUConnectionOpenedNotification";
NSString *MUConnectionClosedNotification = @"MUConnectionClosedNotification";
NSString *MUConnectionConnectingNotification = @"MUConnectionConnectingNotification";
NSString *MUConnectionErrorNotification = @"MUConnectionErrorNotification";
NSString *MUCertificateTrustFailureNotification = @"MUCertificateTrustFailureNotification";

NSString *MUAppShowMessageNotification = @"MUAppShowMessageNotification";
NSString *MUConnectionUDPTransportStatusNotification = @"MUConnectionUDPTransportStatusNotification";

static NSString *MUUDPTransportStateName(NSInteger state) {
    switch (state) {
        case 1:
            return @"unavailable";
        case 2:
            return @"available";
        case 3:
            return @"stalled";
        case 4:
            return @"recovering";
        case 0:
        default:
            return @"unknown";
    }
}

static BOOL MUCertChainHasIdentity(NSArray *chain) {
    if (!chain || [chain count] == 0) return NO;
    id first = [chain objectAtIndex:0];
    return CFGetTypeID((__bridge CFTypeRef)first) == SecIdentityGetTypeID();
}

static NSArray *MUIdentityBackedChainForPersistentRef(NSData *ref, NSString *label) {
    if (!ref) return nil;

    NSData *normalizedRef = [MUCertificateController normalizedIdentityPersistentRefForPersistentRef:ref];
    if (normalizedRef && ![normalizedRef isEqualToData:ref]) {
        MULogDebug(Connection, @"Normalized %@ certificate ref (%lu -> %lu bytes).",
              label ?: @"",
              (unsigned long)[ref length],
              (unsigned long)[normalizedRef length]);
    }

    if (normalizedRef) {
        NSArray *normalizedChain = [MUCertificateChainBuilder buildChainFromPersistentRef:normalizedRef];
        if (MUCertChainHasIdentity(normalizedChain)) {
            return normalizedChain;
        }
    }

    NSArray *rawChain = [MUCertificateChainBuilder buildChainFromPersistentRef:ref];
    if (MUCertChainHasIdentity(rawChain)) {
        return rawChain;
    }

    if (rawChain && [rawChain count] > 0) {
        MULogWarning(Connection, @"%@ certificate ref resolved to cert-only chain (no private key identity). Ignoring it.",
              label ?: @"");
    }
    return nil;
}

static CFTimeInterval MUMonotonicNow(void) {
    return CACurrentMediaTime();
}

static BOOL MUErrorMatchesOSStatus(NSError *error, OSStatus status) {
    if (!error) return NO;
    NSInteger code = [error code];
    NSInteger target = (NSInteger)status;
    return code == target || labs(code) == labs(target);
}

@interface MUConnectionController () <MKConnectionDelegate, MKServerModelDelegate> {
    MKConnection               *_connection;
    MKServerModel              *_serverModel;
#if TARGET_OS_IOS
    UIViewController           *_parentViewController;
    UIAlertController          *_alertCtrl;
#endif
    NSTimer                    *_timer;
    int                        _numDots;

#if TARGET_OS_IOS
    UIAlertController          *_rejectAlertCtrl;
#endif
    MKRejectReason             _rejectReason;

    NSString                   *_hostname;
    NSUInteger                 _port;
    NSString                   *_username;
    NSString                   *_password;
    NSData                     *_certificateRef;
    NSString                   *_displayName;
    
    BOOL            _isUserInitiatedDisconnect;
    BOOL            _waitingForCertDecision;
    NSUInteger      _reconnectGeneration;
    NSUInteger      _connectionRequestGeneration;
    BOOL            _connectionDesired;
    BOOL            _connectionSetupInProgress;
    NSInteger       _retryCount; // 重试计数器
    NSDictionary    *_pendingReconnectFailureInfo;
    BOOL            _suppressReconnectForDisconnect;
    BOOL            _preserveAudioSessionForReconnect;
    CFTimeInterval  _connectFlowStartedAt;
    CFTimeInterval  _socketConnectedAt;
    BOOL            _connectFlowIsReconnect;
    NSInteger       _connectFlowAttempt;
    BOOL            _hasJoinedServerForCurrentSession;
    dispatch_queue_t _audioLifecycleQueue;
    dispatch_queue_t _connectionSetupQueue;
    NSUInteger       _audioLifecycleGeneration;
    NSUInteger       _connectionSetupGeneration;
    BOOL             _hasRestoredMuteState;
    BOOL             _restoredSelfMuted;
    BOOL             _restoredSelfDeafened;

#if TARGET_OS_IOS
    UIBackgroundTaskIdentifier _reconnectBackgroundTask;
#endif
    
    nw_path_monitor_t _pathMonitor;
    BOOL              _networkWasSatisfied;
    BOOL              _networkPathKnown;
    NSUInteger        _networkInterfaceMask;
    NSUInteger        _networkMonitorGeneration;
    uint32_t          _recoveryFailureStreak;
    CFTimeInterval    _lastJoinedAt;
    CFTimeInterval    _nextReconnectAllowedAt;
}
- (void) establishConnection;
- (void)handleNetworkPathSatisfied:(BOOL)satisfied interfaces:(NSUInteger)interfaces;
- (void) establishConnectionForGeneration:(NSUInteger)generation hostname:(NSString *)hostname port:(NSUInteger)port certificateRef:(NSData *)certificateRef;
- (BOOL) isCurrentConnectionSetupGeneration:(NSUInteger)generation;
- (void) teardownConnection;
- (void) teardownConnectionPostingClosed:(BOOL)postClosed;
- (void) applyNetworkForceTCPSetting;
- (void) applyNetworkQoSSetting;
- (void) showConnectingView;
- (void) hideConnectingView;
- (void) hideConnectingViewWithCompletion:(void(^)(void))completion;
- (void) scheduleReconnectAfterDelay:(NSTimeInterval)delay;
- (NSInteger) configuredReconnectMaxAttempts;
- (NSTimeInterval) configuredReconnectInterval;
- (NSTimeInterval) calculatedReconnectDelayForAttempt:(NSInteger)attempt baseInterval:(NSTimeInterval)baseInterval;
- (void) beginPerformanceConnectFlowIsReconnect:(BOOL)isReconnect attempt:(NSInteger)attempt reason:(NSString *)reason;
- (void) logPerformanceConnectFailureWithTitle:(NSString *)title message:(NSString *)message;
- (void) startAudioEngineAsyncForGeneration:(NSUInteger)generation;
- (void) stopAudioEngineAsyncForGeneration:(NSUInteger)generation;
- (void) loadSavedMuteStateForUsername:(NSString *)username;
- (void) applyCachedMuteStateToAudio;
- (BOOL) loadSavedBoolForKey:(NSString *)key value:(BOOL *)value;
- (void) postConnectionNotification:(NSString *)name userInfo:(NSDictionary *)info;
- (void) recoverConnectionAfterWake:(NSNotification *)notification;
- (void) discardCurrentTransport;
#if TARGET_OS_IOS
- (void) beginReconnectBackgroundTask;
- (void) endReconnectBackgroundTask;
#endif
@property (nonatomic, strong, readwrite) NSString *lastWelcomeMessage;
@end

@implementation MUConnectionController
@synthesize currentCertificateRef = _certificateRef; // 将内部变量 _certificateRef 暴露为只读属性

@synthesize connection = _connection;
@synthesize connectionRequestGeneration = _connectionRequestGeneration;

static MUConnectionController *sSharedConnectionController;

+ (MUConnectionController *) sharedController {
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        sSharedConnectionController = [[MUConnectionController alloc] init];
    });
    return sSharedConnectionController;
}

+ (MUConnectionController *) existingSharedController {
    return sSharedConnectionController;
}

- (id) init {
    if ((self = [super init])) {
        _retryCount = 0;
        _reconnectGeneration = 0;
        _pendingReconnectFailureInfo = nil;
        _suppressReconnectForDisconnect = NO;
        _preserveAudioSessionForReconnect = NO;
        _connectFlowStartedAt = 0;
        _socketConnectedAt = 0;
        _connectFlowIsReconnect = NO;
        _connectFlowAttempt = 0;
        _hasJoinedServerForCurrentSession = NO;
        _audioLifecycleQueue = dispatch_queue_create("cn.hotxiang.Mumble.audioLifecycle", DISPATCH_QUEUE_SERIAL);
        _connectionSetupQueue = dispatch_queue_create("cn.hotxiang.Mumble.connectionSetup", DISPATCH_QUEUE_SERIAL);
        _connectionSetupGeneration = 0;
        _hasRestoredMuteState = NO;
        _restoredSelfMuted = NO;
        _restoredSelfDeafened = NO;
        _audioLifecycleGeneration = 0;
    #if TARGET_OS_IOS
        _reconnectBackgroundTask = UIBackgroundTaskInvalid;
    #endif
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(defaultsDidChange:)
                                                     name:NSUserDefaultsDidChangeNotification
                                                   object:nil];
#if TARGET_OS_IOS
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(recoverConnectionAfterWake:)
                                                     name:UIApplicationDidBecomeActiveNotification object:nil];
#else
        [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self selector:@selector(recoverConnectionAfterWake:)
                                                                  name:NSWorkspaceDidWakeNotification object:nil];
#endif
    }
    return self;
}

- (void) defaultsDidChange:(NSNotification *)notification {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self defaultsDidChange:notification]; });
        return;
    }
    (void)notification;
    [self applyNetworkForceTCPSetting];
    [self applyNetworkQoSSetting];
    id autoReconnect = [[NSUserDefaults standardUserDefaults] objectForKey:@"NetworkAutoReconnect"];
    if (autoReconnect && ![autoReconnect boolValue] && _connectFlowIsReconnect && [_serverModel connectedUser] == nil) {
        [self disconnectFromServer];
    }
}

- (MKServerModel *)serverModel {
    return _serverModel;
}

- (void) connectToHostname:(NSString *)hostName
                     port:(NSUInteger)port
             withUsername:(NSString *)userName
              andPassword:(NSString *)password
           certificateRef:(NSData *)certRef
              displayName:(NSString *)displayName {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self connectToHostname:hostName port:port withUsername:userName andPassword:password certificateRef:certRef displayName:displayName];
        });
        return;
    }
    
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(establishConnection) object:nil];
    @synchronized (self) {
        _connectionSetupGeneration++;
    }
    
    BOOL wasConnected = (_connectionDesired || _connection != nil || _serverModel != nil);
    NSUInteger previousRequest = _connectionRequestGeneration;
    
    if (wasConnected) {
        MULogInfo(Connection, @"Switching servers: Force disconnecting previous session...");
        // 模拟用户点击断开：这会停止线程、发送 Bye 消息、清理状态
        [self disconnectFromServer];
        if (_connectionRequestGeneration != previousRequest) return;
    }
    
    _hostname = [hostName copy];
    _port = port;
    _username = [userName copy];
    _password = [password copy];
    _certificateRef = [certRef copy];
    _displayName = [displayName copy];
    _connectionRequestGeneration++;
    _connectionDesired = YES;
    _isUserInitiatedDisconnect = NO;
    _waitingForCertDecision = NO;
    _reconnectGeneration++;
    
    // 重置重试计数
    _retryCount = 0;
    _pendingReconnectFailureInfo = nil;
    _recoveryFailureStreak = 0;
    _lastJoinedAt = 0;
    _nextReconnectAllowedAt = 0;
    _suppressReconnectForDisconnect = NO;
    _preserveAudioSessionForReconnect = NO;
    _hasJoinedServerForCurrentSession = NO;
    [self beginPerformanceConnectFlowIsReconnect:NO attempt:0 reason:@"manual-connect"];
    
    [self postConnectionNotification:MUConnectionConnectingNotification userInfo:nil];
    if (_connectionRequestGeneration != previousRequest + 1 || !_connectionDesired) return;
    if (hostName.length == 0 || port == 0 || port > UINT16_MAX || userName.length == 0) {
        [self postErrorWithTitle:NSLocalizedString(@"Connection Failed", nil) message:NSLocalizedString(@"Invalid server address or username", nil)];
        return;
    }
    [self startNetworkMonitor];
    
    if (wasConnected) {
        MULogDebug(Connection, @"Waiting 0.5s for socket cleanup...");

        [self performSelector:@selector(establishConnection) withObject:nil afterDelay:0.5];
    } else {
        [self performSelector:@selector(establishConnection) withObject:nil afterDelay:0.12];
    }
}

- (BOOL) isConnected {
    return _connection != nil && [_serverModel connectedUser] != nil;
}

- (BOOL) hasConnectionIntent {
    return _connectionDesired;
}

- (dispatch_queue_t) audioLifecycleQueue {
    return _audioLifecycleQueue;
}

- (void) disconnectFromServer {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self disconnectFromServer]; });
        return;
    }
    MULogInfo(Connection, @"User initiated disconnect/cancel.");
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(establishConnection) object:nil];
    @synchronized (self) {
        _connectionSetupGeneration++;
    }
    _isUserInitiatedDisconnect = YES;
    _suppressReconnectForDisconnect = NO;
    _preserveAudioSessionForReconnect = NO;
    _reconnectGeneration++;
    
    if (_connection) {
        [_connection disconnect];
    }
    
    [self teardownConnection];
}

- (void) showConnectingView {
#if TARGET_OS_IOS
    NSString *title = [NSString stringWithFormat:@"%@...", NSLocalizedString(@"Connecting", nil)];
    NSString *msg = [NSString stringWithFormat:
                     NSLocalizedString(@"Connecting to %@:%lu", @"Connecting to hostname:port"),
                     _hostname, (unsigned long)_port];
    
    _alertCtrl = [UIAlertController alertControllerWithTitle:title
                                                     message:msg
                                              preferredStyle:UIAlertControllerStyleAlert];
    [_alertCtrl addAction: [UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil) style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
            [self disconnectFromServer];
    }]];
    
    if (_parentViewController) {
        [_parentViewController presentViewController:_alertCtrl animated:YES completion:nil];
    }
    
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.2f target:self selector:@selector(updateTitle) userInfo:nil repeats:YES];
#endif
}

- (void) updateTitle {
#if TARGET_OS_IOS
    if (_alertCtrl) {
        _numDots = (_numDots + 1) % 4;
        NSString *dots = @"";
        for (int i = 0; i < _numDots; i++) dots = [dots stringByAppendingString:@"."];
        _alertCtrl.title = [NSString stringWithFormat:@"%@%@", NSLocalizedString(@"Connecting", nil), dots];
    }
#endif
}

- (void) hideConnectingView {
    [self hideConnectingViewWithCompletion:nil];
}

- (void) hideConnectingViewWithCompletion:(void (^)(void))completion {
    [_timer invalidate];
    _timer = nil;

#if TARGET_OS_IOS
    if (_alertCtrl != nil && _parentViewController != nil) {
        [_parentViewController dismissViewControllerAnimated:YES completion:completion];
        _alertCtrl = nil;
    } else {
        if (completion) {
            completion();
        }
    }
#else
    if (completion) {
        completion();
    }
#endif
}

- (void) postConnectionNotification:(NSString *)name userInfo:(NSDictionary *)info {
    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithDictionary:info ?: @{}];
    payload[@"requestGeneration"] = @(_connectionRequestGeneration);
    [[NSNotificationCenter defaultCenter] postNotificationName:name object:self userInfo:payload];
}

- (void) startNetworkMonitor {
    if (_pathMonitor) return;
    _pathMonitor = nw_path_monitor_create();
    nw_path_monitor_set_queue(_pathMonitor, dispatch_get_main_queue());
    _networkPathKnown = NO;
    NSUInteger generation = ++_networkMonitorGeneration;
    __weak typeof(self) weakSelf = self;
    nw_path_monitor_set_update_handler(_pathMonitor, ^(nw_path_t path) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || generation != self->_networkMonitorGeneration || !self->_connectionDesired) return;
        BOOL satisfied = nw_path_get_status(path) == nw_path_status_satisfied;
        NSUInteger interfaces = (nw_path_uses_interface_type(path, nw_interface_type_wifi) ? 1 : 0)
            | (nw_path_uses_interface_type(path, nw_interface_type_cellular) ? 2 : 0)
            | (nw_path_uses_interface_type(path, nw_interface_type_wired) ? 4 : 0)
            | (nw_path_uses_interface_type(path, nw_interface_type_other) ? 8 : 0);
        [self handleNetworkPathSatisfied:satisfied interfaces:interfaces];
    });
    nw_path_monitor_start(_pathMonitor);
}

- (void)handleNetworkPathSatisfied:(BOOL)satisfied interfaces:(NSUInteger)interfaces {
    BOOL restored = _networkPathKnown && !_networkWasSatisfied && satisfied;
    BOOL changed = _networkPathKnown && (_networkWasSatisfied != satisfied || _networkInterfaceMask != interfaces);
    _networkPathKnown = YES;
    _networkWasSatisfied = satisfied;
    _networkInterfaceMask = interfaces;
    if (!_connectionDesired || _waitingForCertDecision) return;
    if (_connection) {
        // The default route is advisory, not the state of this TLS socket.
        // Keep even an "unsatisfied" path's existing connection until socket I/O
        // or correlated heartbeats prove failure. Probing already runs every 5s.
        if (changed) MULogInfo(Connection, @"Network path changed (satisfied=%@ interfaces=%lu); retaining transport pending I/O health.",
            satisfied ? @"yes" : @"no", (unsigned long)interfaces);
        return;
    }
    if (restored && !_connectionSetupInProgress) {
        MULogInfo(Connection, @"Network restored; resuming pending connection within retry cooldown.");
        [self scheduleReconnectAfterDelay:0.25];
    }
}

#if DEBUG
- (void)simulateNetworkPathSatisfied:(BOOL)satisfied interfaces:(NSUInteger)interfaces {
    BOOL known = _networkPathKnown, wasSatisfied = _networkWasSatisfied;
    NSUInteger previousInterfaces = _networkInterfaceMask;
    [self handleNetworkPathSatisfied:satisfied interfaces:interfaces];
    // Do not leave synthetic reachability in place after a local test.
    _networkPathKnown = known;
    _networkWasSatisfied = wasSatisfied;
    _networkInterfaceMask = previousInterfaces;
}
#endif

- (void) stopNetworkMonitor {
    _networkMonitorGeneration++;
    _networkPathKnown = NO;
    if (_pathMonitor) {
        nw_path_monitor_cancel(_pathMonitor);
        _pathMonitor = nil;
    }
}

- (void) recoverConnectionAfterWake:(NSNotification *)notification {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self recoverConnectionAfterWake:notification]; });
        return;
    }
    if (!_connectionDesired || _waitingForCertDecision) return;
    // A resumed run loop runs the transport watchdog. Do not destroy a healthy call merely on activation.
    if (!_connection && !_connectionSetupInProgress) {
        [self scheduleReconnectAfterDelay:0.25];
    }
}

- (void) establishConnection {
    if (!_connectionDesired || _isUserInitiatedDisconnect || _waitingForCertDecision
        || _connection || _connectionSetupInProgress) return;
    if (_networkPathKnown && !_networkWasSatisfied) {
        MULogInfo(Connection, @"Waiting for a usable network path without consuming a retry.");
        return;
    }
    _connectionSetupInProgress = YES;
    NSUInteger setupGeneration;
    @synchronized (self) {
        setupGeneration = ++_connectionSetupGeneration;
    }
    NSString *hostname = [_hostname copy];
    NSData *certificateRef = [_certificateRef copy];
    NSUInteger port = _port;
    dispatch_async(_connectionSetupQueue, ^{
        [self establishConnectionForGeneration:setupGeneration hostname:hostname port:port certificateRef:certificateRef];
    });
}

- (BOOL) isCurrentConnectionSetupGeneration:(NSUInteger)generation {
    @synchronized (self) {
        return generation == _connectionSetupGeneration;
    }
}

- (void) establishConnectionForGeneration:(NSUInteger)generation hostname:(NSString *)hostname port:(NSUInteger)port certificateRef:(NSData *)certificateRef {
    @autoreleasepool {
        if (![self isCurrentConnectionSetupGeneration:generation]) return;
        // Prepare expensive keychain material in isolation. Publish the pair atomically on the main queue.
        MKConnection *connection = [[MKConnection alloc] init];
        [connection setIgnoreSSLVerification:NO];
        if (certificateRef != nil) {
            NSArray *certChain = MUIdentityBackedChainForPersistentRef(certificateRef, @"server-specific");
            if (certChain && certChain.count > 0) {
                [connection setCertificateChain:certChain];
                MULogInfo(Connection, @"Using server-specific certificate for connection. (chain length: %lu)", (unsigned long)certChain.count);
            } else {
                MULogWarning(Connection, @"Failed to resolve server-specific cert identity (%lu bytes). Falling back...", (unsigned long)certificateRef.length);
                NSData *globalCert = [[NSUserDefaults standardUserDefaults] objectForKey:@"DefaultCertificate"];
                if (globalCert) {
                    NSArray *fallbackChain = MUIdentityBackedChainForPersistentRef(globalCert, @"global-default");
                    if (fallbackChain && fallbackChain.count > 0) {
                        [connection setCertificateChain:fallbackChain];
                        MULogInfo(Connection, @"Fell back to global default certificate.");
                    } else {
                        MULogWarning(Connection, @"Global default certificate is unusable for client auth. Connecting anonymously.");
                    }
                } else {
                    MULogInfo(Connection, @"No fallback certificate available. Connecting anonymously.");
                }
            }
        } else {
            NSData *globalCert = [[NSUserDefaults standardUserDefaults] objectForKey:@"DefaultCertificate"];
            if (globalCert) {
                NSArray *certChain = MUIdentityBackedChainForPersistentRef(globalCert, @"global-default");
                if (certChain && certChain.count > 0) {
                    [connection setCertificateChain:certChain];
                    MULogInfo(Connection, @"Using global default certificate.");
                } else {
                    MULogWarning(Connection, @"Global default certificate is unusable for client auth. Connecting anonymously.");
                }
            } else {
                MULogInfo(Connection, @"Connecting anonymously (No certificate).");
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self isCurrentConnectionSetupGeneration:generation] || !self->_connectionDesired
                || self->_isUserInitiatedDisconnect) return;
            self->_connectionSetupInProgress = NO;
            if (self->_networkPathKnown && !self->_networkWasSatisfied) return;
            @synchronized (self) { self->_connection = connection; }
            self->_serverModel = [[MKServerModel alloc] initWithConnection:connection];
            [self->_serverModel addDelegate:self];
            [connection setDelegate:self];
            [self applyNetworkForceTCPSetting];
            [self applyNetworkQoSSetting];
            [self loadSavedMuteStateForUsername:self->_username];
            [self applyCachedMuteStateToAudio];
            [connection connectToHost:hostname port:port];
            NSUInteger audioGeneration;
            @synchronized (self) {
                audioGeneration = ++self->_audioLifecycleGeneration;
            }
            [self startAudioEngineAsyncForGeneration:audioGeneration];
        });
    }
}

- (void) startAudioEngineAsyncForGeneration:(NSUInteger)generation {
    BOOL preserveAudio = _preserveAudioSessionForReconnect;
    _preserveAudioSessionForReconnect = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(250 * NSEC_PER_MSEC)), _audioLifecycleQueue, ^{
        BOOL shouldStart = NO;
        NSUInteger currentGeneration = 0;
        @synchronized (self) {
            currentGeneration = self->_audioLifecycleGeneration;
            shouldStart = (generation == currentGeneration && self->_connection != nil);
        }

        if (!shouldStart) {
            MULogDebug(Connection, @"Skipping stale Audio Engine start. generation=%lu current=%lu",
                  (unsigned long)generation,
                  (unsigned long)currentGeneration);
            return;
        }

        CFTimeInterval startedAt = MUMonotonicNow();
        MKAudio *audio = [MKAudio sharedAudio];
        BOOL shouldPreserveRunningAudio = preserveAudio && [audio isRunning];
        if (shouldPreserveRunningAudio) {
            MULogInfo(Connection, @"[Async] Preserving Audio Engine for reconnect; keeping voice audio session active.");
        } else {
            MULogInfo(Connection, @"[Async] Starting Audio Engine...");
            [audio restart];
        }
#if TARGET_OS_IOS
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_audioLifecycleGeneration || !self->_connection) return;
            if (self->_hasRestoredMuteState) {
            BOOL targetMuted = self->_restoredSelfMuted || self->_restoredSelfDeafened;
            NSString *reason = shouldPreserveRunningAudio ? @"audio_engine_preserved_restore_state" : @"audio_engine_started_restore_state";
            [MUSystemInputMuteBridge applyRestoredMute:targetMuted reason:reason];
            }
        });
#endif
        CFTimeInterval elapsedMs = (MUMonotonicNow() - startedAt) * 1000.0;
        MULogDebug(Connection, @"PERF audio_engine_start_async elapsed_ms=%.2f generation=%lu",
              elapsedMs,
              (unsigned long)generation);
    });
}

- (void) stopAudioEngineAsyncForGeneration:(NSUInteger)generation {
    dispatch_async(_audioLifecycleQueue, ^{
        NSUInteger currentGeneration = 0;
        @synchronized (self) {
            currentGeneration = self->_audioLifecycleGeneration;
        }
        if (generation != currentGeneration) {
            MULogDebug(Connection, @"Skipping stale Audio Engine stop. generation=%lu current=%lu",
                  (unsigned long)generation,
                  (unsigned long)currentGeneration);
            return;
        }

        CFTimeInterval startedAt = MUMonotonicNow();
        MULogInfo(Connection, @"[Async] Stopping Audio Engine (Release Mic)...");
        [[MKAudio sharedAudio] stop];
        
        // MKAudio owns session deactivation on its serialized graph queue.
        CFTimeInterval elapsedMs = (MUMonotonicNow() - startedAt) * 1000.0;
        MULogDebug(Connection, @"PERF audio_engine_stop_async elapsed_ms=%.2f generation=%lu",
              elapsedMs,
              (unsigned long)generation);
    });
}

- (void) applyNetworkForceTCPSetting {
    BOOL shouldForceTCP = [[NSUserDefaults standardUserDefaults] boolForKey:@"NetworkForceTCP"];
    if (_connection) {
        [_connection setForceTCP:shouldForceTCP];
    }
}

- (void) applyNetworkQoSSetting {
    BOOL shouldEnableQoS = [[NSUserDefaults standardUserDefaults] boolForKey:@"NetworkQoS"];
    if (_connection) {
        [_connection setQoSEnabled:shouldEnableQoS];
    }
}

- (void) discardCurrentTransport {
    @synchronized (self) {
        _connectionSetupGeneration++;
        _connectionSetupInProgress = NO;
        _audioLifecycleGeneration++;
    }
    [_serverModel removeDelegate:self];
    _serverModel = nil;
    [_connection setDelegate:nil];
    [_connection disconnect];
    @synchronized (self) { _connection = nil; }
}

- (void) teardownConnection {
    [self teardownConnectionPostingClosed:YES];
}

- (void) teardownConnectionPostingClosed:(BOOL)postClosed {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(establishConnection) object:nil];
    _connectionDesired = NO;
    _waitingForCertDecision = NO;
    [self stopNetworkMonitor];
    _preserveAudioSessionForReconnect = NO;
    _hasJoinedServerForCurrentSession = NO;
    _reconnectGeneration++;
    _pendingReconnectFailureInfo = nil;
#if TARGET_OS_IOS
    [self endReconnectBackgroundTask];
#endif
    [self discardCurrentTransport];
    [self hideConnectingView];
#if TARGET_OS_IOS
    [[UNUserNotificationCenter currentNotificationCenter] setBadgeCount:0 withCompletionHandler:nil];
#endif
    // Enqueue the stop before notifying observers, which may immediately start a new request.
    [self stopAudioEngineAsyncForGeneration:_audioLifecycleGeneration];
    if (postClosed) [self postConnectionNotification:MUConnectionClosedNotification userInfo:nil];
}

- (void) postErrorWithTitle:(NSString *)title message:(NSString *)message {
    [self logPerformanceConnectFailureWithTitle:title message:message];
    NSUInteger request = _connectionRequestGeneration;
    // Finish the old request before observer code can initiate another one.
    NSDictionary *info = @{ @"title": title ?: @"", @"message": message ?: @"", @"requestGeneration": @(request) };
    [self teardownConnectionPostingClosed:NO];
    [[NSNotificationCenter defaultCenter] postNotificationName:MUConnectionErrorNotification object:self userInfo:info];
    if (request == _connectionRequestGeneration && !_connectionDesired) {
        [self postConnectionNotification:MUConnectionClosedNotification userInfo:nil];
    }
}

- (void) postMessage:(NSString *)message type:(NSString *)type {
    if (!message) return;
    NSDictionary *userInfo = @{ @"message": message, @"type": type ?: @"info" };
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:MUAppShowMessageNotification object:nil userInfo:userInfo];
    });
}

// ... Key helper methods (unchanged) ...
- (NSString *) stateKeyWithPrefix:(NSString *)prefix username:(NSString *)username {
    NSString *safeUsername = (username && [username length] > 0) ? username : @"";
    return [NSString stringWithFormat:@"%@_%@_%lu_%@", prefix, _hostname, (unsigned long)_port, safeUsername];
}
- (NSString *) lastChannelKey { return [self stateKeyWithPrefix:@"LastChannel" username:_username]; }
- (NSString *) muteStateKey { return [self stateKeyWithPrefix:@"State_Mute" username:_username]; }
- (NSString *) deafStateKey { return [self stateKeyWithPrefix:@"State_Deaf" username:_username]; }
- (NSString *) muteStateKeyForUsername:(NSString *)username { return [self stateKeyWithPrefix:@"State_Mute" username:username]; }
- (NSString *) deafStateKeyForUsername:(NSString *)username { return [self stateKeyWithPrefix:@"State_Deaf" username:username]; }

- (BOOL) loadSavedBoolForKey:(NSString *)key value:(BOOL *)value {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    if (stored == nil) {
        return NO;
    }
    if (value != NULL) {
        *value = [stored boolValue];
    }
    return YES;
}

- (void) loadSavedMuteStateForUsername:(NSString *)username {
    BOOL savedMute = NO;
    BOOL savedDeaf = NO;
    BOOL hasMute = [self loadSavedBoolForKey:[self muteStateKeyForUsername:username] value:&savedMute];
    BOOL hasDeaf = [self loadSavedBoolForKey:[self deafStateKeyForUsername:username] value:&savedDeaf];

    _hasRestoredMuteState = (hasMute || hasDeaf);
    _restoredSelfMuted = savedMute || savedDeaf;
    _restoredSelfDeafened = savedDeaf;
}

- (void) applyCachedMuteStateToAudio {
    if (!_hasRestoredMuteState) {
        return;
    }

    BOOL targetMuted = _restoredSelfMuted || _restoredSelfDeafened;
    [[MKAudio sharedAudio] setSelfMuted:targetMuted];
#if TARGET_OS_IOS
    [MUSystemInputMuteBridge applyRestoredMute:targetMuted reason:@"connection_restore_cached_state"];
#endif
}

#pragma mark - MKConnectionDelegate

- (void) connectionOpened:(MKConnection *)conn {
    if (conn != _connection || !_connectionDesired) return;
    _socketConnectedAt = MUMonotonicNow();
    if (_connectFlowStartedAt > 0) {
        CFTimeInterval handshakeMs = (_socketConnectedAt - _connectFlowStartedAt) * 1000.0;
        MULogDebug(Connection, @"PERF connect_opened reconnect=%@ attempt=%ld handshake_ms=%.2f host=%@:%lu",
              _connectFlowIsReconnect ? @"yes" : @"no",
              (long)_connectFlowAttempt,
              handshakeMs,
              _hostname ?: @"",
              (unsigned long)_port);
    }

    MKConnection *connection = conn;
    NSString *hostname = [[conn hostname] copy];
    NSUInteger port = [conn port];
    NSString *username = [_username copy];
    NSString *password = [_password copy];
    NSString *displayName = [_displayName copy];
    dispatch_async(_connectionSetupQueue, ^{
        @autoreleasepool {
            NSArray *tokens = [MUDatabase accessTokensForServerWithHostname:hostname port:port];
            BOOL shouldAuthenticate = NO;
            @synchronized (self) {
                shouldAuthenticate = (self->_connection == connection && !self->_isUserInitiatedDisconnect);
            }

            if (shouldAuthenticate) {
                [connection authenticateWithUsername:username password:password accessTokens:tokens];
            }

            NSString *nameToSave = (displayName && [displayName length] > 0) ? displayName : hostname;
            dispatch_async(dispatch_get_main_queue(), ^{
                @synchronized (self) {
                    if (self->_connection != connection || self->_isUserInitiatedDisconnect) {
                        return;
                    }
                }
                [[RecentServerManager shared] addRecentWithHostname:hostname
                                                               port:port
                                                           username:username
                                                        displayName:nameToSave];
            });

        }
    });
}

- (void) connection:(MKConnection *)conn closedWithError:(NSError *)err {
    if (conn != _connection || !_connectionDesired) return;
    [self hideConnectingView];
    if (_isUserInitiatedDisconnect || _suppressReconnectForDisconnect) {
        [self teardownConnection];
        return;
    }
    if (_waitingForCertDecision) return;
    NSString *title = NSLocalizedString(@"Connection Failed", nil);
    NSString *message = [err localizedFailureReason] ?: [err localizedDescription] ?: NSLocalizedString(@"The connection was closed.", nil);
    if (MUErrorMatchesOSStatus(err, errSSLClosedAbort)) {
        MULogWarning(Connection, @"TLS peer closed connection. domain=%@ code=%ld", err.domain, (long)err.code);
    }
    id autoReconnect = [[NSUserDefaults standardUserDefaults] objectForKey:@"NetworkAutoReconnect"];
    if (autoReconnect && ![autoReconnect boolValue]) {
        [self postErrorWithTitle:title message:message];
        return;
    }
    _pendingReconnectFailureInfo = @{ @"title": title, @"message": message };
    NSInteger maxAttempts = [self configuredReconnectMaxAttempts];
    BOOL offline = _networkPathKnown && !_networkWasSatisfied;
    if (!offline && !_hasJoinedServerForCurrentSession && _retryCount >= maxAttempts) {
        [self postErrorWithTitle:title message:message];
        return;
    }
    _preserveAudioSessionForReconnect = YES;
    _connectFlowIsReconnect = YES;
    CFTimeInterval failureAt = MUMonotonicNow();
    _recoveryFailureStreak = MURecoveryFailureCount(_recoveryFailureStreak, _lastJoinedAt, failureAt);
    _lastJoinedAt = 0;
    [self discardCurrentTransport];
    // The configured count limits the fast retry burst. Established calls continue at a bounded rate.
    NSTimeInterval delay = _retryCount >= maxAttempts ? 30.0
        : [self calculatedReconnectDelayForAttempt:_retryCount + 1 baseInterval:[self configuredReconnectInterval]];
    delay = MAX(delay, MURecoveryMinimumDelay(_recoveryFailureStreak));
    _nextReconnectAllowedAt = failureAt + delay;
    NSUInteger request = _connectionRequestGeneration;
    [self postConnectionNotification:MUConnectionConnectingNotification userInfo:@{
        @"isReconnecting": @YES, @"reconnectAttempt": @(MIN(_retryCount + 1, maxAttempts)),
        @"reconnectMaxAttempts": @(maxAttempts), @"reconnectDelay": @(offline ? 0 : delay),
        @"reconnectReason": message
    }];
    if (request != _connectionRequestGeneration || !_connectionDesired) return;
    if (!offline) [self scheduleReconnectAfterDelay:delay];
    else MULogInfo(Connection, @"Connection suspended until network returns; retry budget preserved.");
}

- (void) performReconnect {
    if (!_connectionDesired || _isUserInitiatedDisconnect || _waitingForCertDecision
        || _connection || _connectionSetupInProgress || (_networkPathKnown && !_networkWasSatisfied)) return;
    id autoReconnect = [[NSUserDefaults standardUserDefaults] objectForKey:@"NetworkAutoReconnect"];
    if (autoReconnect && ![autoReconnect boolValue]) {
        [self teardownConnection];
        return;
    }
    NSInteger maxAttempts = [self configuredReconnectMaxAttempts];
    _retryCount = MIN(_retryCount + 1, maxAttempts);
    [self beginPerformanceConnectFlowIsReconnect:YES attempt:_retryCount reason:@"automatic-recovery"];
    NSUInteger request = _connectionRequestGeneration;
    [self postConnectionNotification:MUConnectionConnectingNotification userInfo:@{
        @"isReconnecting": @YES, @"reconnectAttempt": @(_retryCount), @"reconnectMaxAttempts": @(maxAttempts),
        @"reconnectReason": _pendingReconnectFailureInfo[@"message"] ?: NSLocalizedString(@"Network changed or temporarily unavailable", nil)
    }];
    if (request != _connectionRequestGeneration || !_connectionDesired) return;
    [self establishConnection];
}

- (void) connection:(MKConnection*)conn unableToConnectWithError:(NSError *)err {
    [self connection:conn closedWithError:err];
}

- (void) scheduleReconnectAfterDelay:(NSTimeInterval)delay {
    if (!_connectionDesired || _waitingForCertDecision || _connection || _connectionSetupInProgress) return;
    delay = MURecoveryScheduledDelay(delay, _nextReconnectAllowedAt, MUMonotonicNow());
    NSUInteger generation = ++_reconnectGeneration;
#if TARGET_OS_IOS
    [self beginReconnectBackgroundTask];
#endif
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != self->_reconnectGeneration) return;
        [self performReconnect];
    });
}

- (NSInteger) configuredReconnectMaxAttempts {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:@"NetworkReconnectMaxAttempts"];
    NSInteger attempts = value ? [value integerValue] : 10;
    if (attempts < 1) attempts = 1;
    if (attempts > 30) attempts = 30;
    return attempts;
}

- (NSTimeInterval) configuredReconnectInterval {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:@"NetworkReconnectInterval"];
    NSTimeInterval interval = value ? [value doubleValue] : 1.0;
    if (!isfinite(interval)) interval = 1.0;
    if (interval < 0.5) interval = 0.5;
    if (interval > 10.0) interval = 10.0;
    return interval;
}

- (NSTimeInterval) calculatedReconnectDelayForAttempt:(NSInteger)attempt baseInterval:(NSTimeInterval)baseInterval {
    // 轻量退避：前几次快速恢复，后续逐步拉长，降低抖动网络下的重连风暴。
    double growthFactor = 1.0 + (0.25 * (double)MAX(attempt - 1, 0));
    if (growthFactor > 3.0) {
        growthFactor = 3.0;
    }

    NSTimeInterval delayed = baseInterval * growthFactor;
    double jitter = ((double)arc4random_uniform(31) - 15.0) / 100.0; // [-15%, +15%]
    delayed = delayed * (1.0 + jitter);

    if (delayed < 0.5) {
        delayed = 0.5;
    }
    if (delayed > 20.0) {
        delayed = 20.0;
    }
    return delayed;
}

- (void) beginPerformanceConnectFlowIsReconnect:(BOOL)isReconnect attempt:(NSInteger)attempt reason:(NSString *)reason {
    _connectFlowStartedAt = MUMonotonicNow();
    _socketConnectedAt = 0;
    _connectFlowIsReconnect = isReconnect;
    _connectFlowAttempt = attempt;

    MULogDebug(Connection, @"PERF connect_begin reconnect=%@ attempt=%ld reason=%@ host=%@:%lu",
          isReconnect ? @"yes" : @"no",
          (long)attempt,
          reason ?: @"",
          _hostname ?: @"",
          (unsigned long)_port);
}

- (void) logPerformanceConnectFailureWithTitle:(NSString *)title message:(NSString *)message {
    if (_connectFlowStartedAt <= 0) {
        return;
    }

    CFTimeInterval now = MUMonotonicNow();
    CFTimeInterval totalMs = (now - _connectFlowStartedAt) * 1000.0;
    MULogDebug(Connection, @"PERF connect_failed reconnect=%@ attempt=%ld total_ms=%.2f title=%@ message=%@",
          _connectFlowIsReconnect ? @"yes" : @"no",
          (long)_connectFlowAttempt,
          totalMs,
          title ?: @"",
          message ?: @"");
}

#if TARGET_OS_IOS
- (void) beginReconnectBackgroundTask {
    if (_reconnectBackgroundTask != UIBackgroundTaskInvalid) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    _reconnectBackgroundTask = [[UIApplication sharedApplication] beginBackgroundTaskWithName:@"mumble-reconnect"
                                                                             expirationHandler:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        MULogWarning(Connection, @"Reconnect background task expired.");
        [strongSelf endReconnectBackgroundTask];
    }];
}

- (void) endReconnectBackgroundTask {
    if (_reconnectBackgroundTask == UIBackgroundTaskInvalid) {
        return;
    }

    [[UIApplication sharedApplication] endBackgroundTask:_reconnectBackgroundTask];
    _reconnectBackgroundTask = UIBackgroundTaskInvalid;
}
#endif

- (void) connection:(MKConnection *)conn udpTransportStateChanged:(MKUDPTransportState)state {
    if (conn != _connection || !_connectionDesired) return;

    NSDictionary *info = @{
        @"state": @(state),
        @"stateName": MUUDPTransportStateName(state)
    };

    dispatch_async(dispatch_get_main_queue(), ^{
        if (conn != self->_connection || !self->_connectionDesired) return;
        [[NSNotificationCenter defaultCenter] postNotificationName:MUConnectionUDPTransportStatusNotification
                                                            object:nil
                                                          userInfo:info];
    });
}

// ... (Rest of methods: trustFailure, rejected, serverModel delegates... ALL UNCHANGED) ...
// 请保持剩余代码与之前一致
- (void) connection:(MKConnection *)conn trustFailureInCertificateChain:(NSArray *)chain {
    if (conn != _connection || !_connectionDesired) return;
    MKCertificate *cert = [[conn peerCertificates] firstObject];
    NSString *serverDigest = [cert hexDigest];
    NSString *storedDigest = [MUDatabase digestForServerWithHostname:[conn hostname]
                                                                port:(NSInteger)[conn port]];

    if (storedDigest && [storedDigest isEqualToString:serverDigest]) {
        MULogInfo(Connection, @"Certificate matches stored digest — auto-trusting.");
        [conn setIgnoreSSLVerification:YES];
        [conn reconnect];
        return;
    }

    MULogWarning(Connection, @"Certificate trust failure — prompting user (changed=%@).", storedDigest ? @"YES" : @"NO");
    _waitingForCertDecision = YES;

    NSString *subjectName = [cert subjectName] ?: NSLocalizedString(@"Unknown", nil);
    NSString *issuerName  = [cert issuerName]  ?: NSLocalizedString(@"Unknown", nil);
    NSString *fingerprint = serverDigest       ?: NSLocalizedString(@"Unknown", nil);

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    [df setDateStyle:NSDateFormatterMediumStyle];
    [df setTimeStyle:NSDateFormatterShortStyle];
    NSString *notBefore = [cert notBefore] ? [df stringFromDate:[cert notBefore]] : @"—";
    NSString *notAfter  = [cert notAfter]  ? [df stringFromDate:[cert notAfter]]  : @"—";

    NSDictionary *info = @{
        @"requestGeneration": @(_connectionRequestGeneration),
        @"connection": conn,
        @"hostname":    [conn hostname] ?: @"",
        @"port":        @([conn port]),
        @"subjectName": subjectName,
        @"issuerName":  issuerName,
        @"fingerprint": fingerprint,
        @"notBefore":   notBefore,
        @"notAfter":    notAfter,
        @"isChanged":   @(storedDigest != nil),
    };

    [CertTrustBridge handleTrustFailure:info];
}

- (void) acceptCertificateTrust {
    if (!_waitingForCertDecision || !_connectionDesired || !_connection) return;
    _waitingForCertDecision = NO;

    MKCertificate *cert = [_connection peerCertificates].firstObject;
    NSString *digest = [cert hexDigest];
    if (digest) {
        [MUDatabase storeDigest:digest forServerWithHostname:_hostname port:(NSInteger)_port];
        MULogInfo(Connection, @"User accepted certificate trust — digest stored.");
    }

    [self discardCurrentTransport];
    [self establishConnection];
}

- (void) rejectCertificateTrust {
    if (!_waitingForCertDecision || !_connectionDesired) return;
    _waitingForCertDecision = NO;
    MULogInfo(Connection, @"User rejected certificate trust.");
    [self postErrorWithTitle:NSLocalizedString(@"Connection Rejected", nil)
                     message:NSLocalizedString(@"The server's certificate was not trusted.", nil)];
}

- (void) connection:(MKConnection *)conn rejectedWithReason:(MKRejectReason)reason explanation:(NSString *)explanation {
    if (conn != _connection || !_connectionDesired) return;
    NSString *title = NSLocalizedString(@"Connection Rejected", nil);
    NSString *msg = @"Unknown reason";
    
    switch (reason) {
        case MKRejectReasonNone: msg = NSLocalizedString(@"No reason", nil); break;
        case MKRejectReasonWrongVersion: msg = @"Client/server version mismatch"; break;
        case MKRejectReasonInvalidUsername: msg = NSLocalizedString(@"Invalid username", nil); break;
        case MKRejectReasonWrongUserPassword: msg = NSLocalizedString(@"Wrong User Password", nil); break;
        case MKRejectReasonWrongServerPassword: msg = NSLocalizedString(@"Wrong Server Password", nil); break;
        case MKRejectReasonUsernameInUse: msg = NSLocalizedString(@"Username already in use", nil); break;
        case MKRejectReasonServerIsFull: msg = NSLocalizedString(@"Server is full", nil); break;
        case MKRejectReasonNoCertificate: msg = NSLocalizedString(@"A certificate is needed", nil); break;
    }
    // A previous anonymous session may survive a broken socket until the server's timeout.
    if (_hasJoinedServerForCurrentSession && (reason == MKRejectReasonUsernameInUse || reason == MKRejectReasonServerIsFull)) {
        NSError *error = [NSError errorWithDomain:@"MumbleServerTemporarilyUnavailable" code:reason
                                        userInfo:@{NSLocalizedDescriptionKey: msg}];
        [self connection:conn closedWithError:error];
        return;
    }
    
    if (reason == MKRejectReasonUsernameInUse) {
        title = NSLocalizedString(@"Username Already in Use", nil);
        msg = NSLocalizedString(@"Your username is still active from a previous session.\nSince you are not registered, you cannot disconnect the old session immediately.\n\nTip: If you are seeing this from reconnecting, register your user on the server to allow instant reconnection in the future.", nil);

        MULogWarning(Connection, @"Username in use. Showing registration guidance and skipping reconnect.");
        _pendingReconnectFailureInfo = nil;
        _retryCount = 0;
        [self postErrorWithTitle:title message:msg];
        return;
    }
    
    if (explanation && explanation.length > 0 && ![explanation isEqualToString:msg]) {
        msg = [NSString stringWithFormat:@"%@\n\n%@", msg, explanation];
    }
    
    [self postErrorWithTitle:title message:msg];
}

- (void) serverModel:(MKServerModel *)model joinedServerAsUser:(MKUser *)user withWelcomeMessage:(MKTextMessage *)welcomeMessage {
    if (model != _serverModel || !_connectionDesired) return;
    if (!user) {
        [self postErrorWithTitle:NSLocalizedString(@"Connection Failed", nil)
                        message:NSLocalizedString(@"The server did not complete authentication in time.", nil)];
        return;
    }
    _hasJoinedServerForCurrentSession = YES;
    _lastJoinedAt = MUMonotonicNow();
    _retryCount = 0;
    _pendingReconnectFailureInfo = nil;
    _reconnectGeneration++;
#if TARGET_OS_IOS
    [self endReconnectBackgroundTask];
#endif

    if (_connectFlowStartedAt > 0) {
        CFTimeInterval now = MUMonotonicNow();
        CFTimeInterval totalMs = (now - _connectFlowStartedAt) * 1000.0;
        CFTimeInterval authJoinMs = (_socketConnectedAt > 0) ? ((now - _socketConnectedAt) * 1000.0) : -1;
        MULogDebug(Connection, @"PERF connect_ready reconnect=%@ attempt=%ld total_ms=%.2f auth_join_ms=%.2f host=%@:%lu",
              _connectFlowIsReconnect ? @"yes" : @"no",
              (long)_connectFlowAttempt,
              totalMs,
              authJoinMs,
              _hostname ?: @"",
              (unsigned long)_port);
    }

    // 1. 存储用户名
    [MUDatabase storeUsername:[user userName] forServerWithHostname:[model hostname] port:[model port]];
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSInteger lastChannelId = [defaults integerForKey:[self lastChannelKey]];
    NSString *confirmedUsername = [user userName] ?: _username;
    BOOL shouldMute = NO;
    BOOL shouldDeaf = NO;
    BOOL hasMute = [self loadSavedBoolForKey:[self muteStateKeyForUsername:confirmedUsername] value:&shouldMute];
    BOOL hasDeaf = [self loadSavedBoolForKey:[self deafStateKeyForUsername:confirmedUsername] value:&shouldDeaf];

    if (!hasMute && !hasDeaf && ![confirmedUsername isEqualToString:_username]) {
        hasMute = [self loadSavedBoolForKey:[self muteStateKey] value:&shouldMute];
        hasDeaf = [self loadSavedBoolForKey:[self deafStateKey] value:&shouldDeaf];
    }

    BOOL hasSavedMuteState = (hasMute || hasDeaf);
    if (shouldDeaf) {
        shouldMute = YES;
    }
    
    // 2. 恢复同一服务器、同一用户名上次保存的闭麦/不听状态
    if (hasSavedMuteState) {
        _hasRestoredMuteState = YES;
        _restoredSelfMuted = shouldMute;
        _restoredSelfDeafened = shouldDeaf;
        [model setSelfMuted:shouldMute andSelfDeafened:shouldDeaf];
        [defaults setBool:shouldMute forKey:[self muteStateKeyForUsername:confirmedUsername]];
        [defaults setBool:shouldDeaf forKey:[self deafStateKeyForUsername:confirmedUsername]];
        [defaults synchronize];
        [self applyCachedMuteStateToAudio];
    }
    
    // 3. 恢复上次频道
    if (lastChannelId > 0) {
        MKChannel *targetChannel = [model channelWithId:lastChannelId];
        if (targetChannel) {
            [model joinChannel:targetChannel];
        }
    }
    
    // 4. 隐藏连接界面并通知 SwiftUI
    [self hideConnectingViewWithCompletion:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (model != self->_serverModel || !self->_connectionDesired) return;
            NSString *displayTitle = self->_displayName;
            if (!displayTitle || [displayTitle length] == 0) {
                displayTitle = self->_hostname;
            }
            
            NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
            userInfo[@"requestGeneration"] = @(self->_connectionRequestGeneration);
            if (self->_connection) userInfo[@"connection"] = self->_connection;
            if (displayTitle) {
                userInfo[@"displayName"] = displayTitle;
            }
            
            // ✅ 新增：将欢迎消息放入 userInfo 传给 Swift
            if (welcomeMessage) {
                NSString *msgContent = [welcomeMessage plainTextString];
                if (!msgContent) {
                    if ([welcomeMessage respondsToSelector:@selector(message)]) {
                        msgContent = [welcomeMessage performSelector:@selector(message)];
                    }
                }
                self.lastWelcomeMessage = msgContent; // 存起来！
            } else {
                self.lastWelcomeMessage = nil;
            }
            
            [[NSNotificationCenter defaultCenter] postNotificationName:@"MUConnectionReadyForSwiftUI"
                                                                object:self
                                                              userInfo:userInfo];
            if (model != self->_serverModel || !self->_connectionDesired) return;
            [[NSNotificationCenter defaultCenter] postNotificationName:MUConnectionOpenedNotification
                                                                object:self
                                                              userInfo:userInfo];
        });
    }];
}

// ... (Copy remaining serverModel delegates from previous answer) ...
- (void) serverModel:(MKServerModel *)model userMoved:(MKUser *)user toChannel:(MKChannel *)chan fromChannel:(MKChannel *)prevChan byUser:(MKUser *)mover {
    if (model != _serverModel || !_connectionDesired) return;
    if (user == [model connectedUser]) {
        [[NSUserDefaults standardUserDefaults] setInteger:[chan channelId] forKey:[self lastChannelKey]];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
}
- (void) serverModel:(MKServerModel *)model userSelfMuteDeafenStateChanged:(MKUser *)user {
    if (model != _serverModel || !_connectionDesired) return;
    if (user == [model connectedUser]) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setBool:[user isSelfMuted] forKey:[self muteStateKey]];
        [defaults setBool:[user isSelfDeafened] forKey:[self deafStateKey]];
        [defaults synchronize];
    }
}
- (void) serverModel:(MKServerModel *)model userKicked:(MKUser *)user byUser:(MKUser *)actor forReason:(NSString *)reason {
    if (model != _serverModel || !_connectionDesired) return;
    if (user == [model connectedUser]) {
        _suppressReconnectForDisconnect = YES;
        NSString *msg = [NSString stringWithFormat:NSLocalizedString(@"Kicked by %@: %@", nil), [actor userName], reason ?: @""];
        [self postErrorWithTitle:NSLocalizedString(@"You were kicked", nil) message:msg];
    }
}
- (void) serverModel:(MKServerModel *)model userBanned:(MKUser *)user byUser:(MKUser *)actor forReason:(NSString *)reason {
    if (model != _serverModel || !_connectionDesired) return;
    if (user == [model connectedUser]) {
        _suppressReconnectForDisconnect = YES;
        NSString *msg = [NSString stringWithFormat:NSLocalizedString(@"Banned by %@: %@", nil), [actor userName], reason ?: @""];
        [self postErrorWithTitle:NSLocalizedString(@"You were banned", nil) message:msg];
    }
}
- (void) serverModel:(MKServerModel *)model userJoined:(MKUser *)user {}
- (void) serverModel:(MKServerModel *)model userDisconnected:(MKUser *)user {}
- (void) serverModel:(MKServerModel *)model userLeft:(MKUser *)user {}
- (void) serverModel:(MKServerModel *)model userTalkStateChanged:(MKUser *)user {}
- (void) serverModel:(MKServerModel *)model permissionDenied:(MKPermission)perm forUser:(MKUser *)user inChannel:(MKChannel *)channel {
    if (model != _serverModel || !_connectionDesired) return;
    [self postMessage:NSLocalizedString(@"Permission denied", nil) type:@"error"];
}
- (void) serverModel:(MKServerModel *)model permissionDeniedForReason:(NSString *)reason {
    if (model != _serverModel || !_connectionDesired) return;
    NSString *msg = reason ?: NSLocalizedString(@"Permission denied", nil);
    [self postMessage:msg type:@"error"];
}
- (void) serverModelInvalidChannelNameError:(MKServerModel *)model {
    if (model != _serverModel || !_connectionDesired) return;
    [self postMessage:NSLocalizedString(@"Invalid channel name", nil) type:@"error"];
}
- (void) serverModelModifySuperUserError:(MKServerModel *)model {
    if (model != _serverModel || !_connectionDesired) return;
    [self postMessage:NSLocalizedString(@"Cannot modify SuperUser", nil) type:@"error"];
}
- (void) serverModelTextMessageTooLongError:(MKServerModel *)model {
    if (model != _serverModel || !_connectionDesired) return;
    [self postMessage:NSLocalizedString(@"Message too long", nil) type:@"error"];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"MUMessageSendFailed"
                                                        object:nil
                                                      userInfo:@{@"reason": @"permissionDenied"}];
}
- (void) serverModelTemporaryChannelError:(MKServerModel *)model {
    if (model != _serverModel || !_connectionDesired) return;
    [self postMessage:NSLocalizedString(@"Not permitted in temporary channel", nil) type:@"error"];
}
- (void) serverModel:(MKServerModel *)model missingCertificateErrorForUser:(MKUser *)user {
    if (model != _serverModel || !_connectionDesired) return;
    [self postMessage:NSLocalizedString(@"Missing certificate", nil) type:@"error"];
}
- (void) serverModel:(MKServerModel *)model invalidUsernameErrorForName:(NSString *)name {
    if (model != _serverModel || !_connectionDesired) return;
    NSString *msg = [NSString stringWithFormat:@"Invalid username: %@", name ?: @""];
    [self postMessage:msg type:@"error"];
}
- (void) serverModelChannelFullError:(MKServerModel *)model {
    if (model != _serverModel || !_connectionDesired) return;
    [self postMessage:NSLocalizedString(@"Channel is full", nil) type:@"error"];
}
@end
