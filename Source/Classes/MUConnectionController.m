// Copyright 2009-2011 The 'Mumble for iOS' Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import "MUConnectionController.h"
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
@import Security;

NSString *MUConnectionOpenedNotification = @"MUConnectionOpenedNotification";
NSString *MUConnectionClosedNotification = @"MUConnectionClosedNotification";
NSString *MUConnectionConnectingNotification = @"MUConnectionConnectingNotification";
NSString *MUConnectionErrorNotification = @"MUConnectionErrorNotification";

NSString *MUAppShowMessageNotification = @"MUAppShowMessageNotification";

static BOOL MUCertChainHasIdentity(NSArray *chain) {
    if (!chain || [chain count] == 0) return NO;
    id first = [chain objectAtIndex:0];
    return CFGetTypeID((__bridge CFTypeRef)first) == SecIdentityGetTypeID();
}

static NSArray *MUIdentityBackedChainForPersistentRef(NSData *ref, NSString *label) {
    if (!ref) return nil;

    NSData *normalizedRef = [MUCertificateController normalizedIdentityPersistentRefForPersistentRef:ref];
    if (normalizedRef && ![normalizedRef isEqualToData:ref]) {
        NSLog(@"🔧 Normalized %@ certificate ref (%lu -> %lu bytes).",
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
        NSLog(@"⚠️ %@ certificate ref resolved to cert-only chain (no private key identity). Ignoring it.",
              label ?: @"");
    }
    return nil;
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
    NSTimer         *_reconnectTimer;
    NSInteger       _retryCount; // 重试计数器
    
    nw_path_monitor_t _pathMonitor;
    BOOL              _networkWasSatisfied;
}
- (void) establishConnection;
- (void) teardownConnection;
- (void) showConnectingView;
- (void) hideConnectingView;
- (void) hideConnectingViewWithCompletion:(void(^)(void))completion;
@property (nonatomic, strong, readwrite) NSString *lastWelcomeMessage;
@end

@implementation MUConnectionController
@synthesize currentCertificateRef = _certificateRef; // 将内部变量 _certificateRef 暴露为只读属性

@synthesize connection = _connection;

+ (MUConnectionController *) sharedController {
    static MUConnectionController *nc;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        nc = [[MUConnectionController alloc] init];
    });
    return nc;
}

- (id) init {
    if ((self = [super init])) {
        _retryCount = 0;
        [[MKAudio sharedAudio] stop];
    }
    return self;
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
    
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(establishConnection) object:nil];
    
    BOOL wasConnected = (_connection != nil || _serverModel != nil);
    
    if (wasConnected) {
        NSLog(@"🔄 Switching servers: Force disconnecting previous session...");
        // 模拟用户点击断开：这会停止线程、发送 Bye 消息、清理状态
        [self disconnectFromServer];
    }
    
    _hostname = [hostName copy];
    _port = port;
    _username = [userName copy];
    _password = [password copy];
    _certificateRef = [certRef copy];
    _displayName = [displayName copy];
    
    // 重置重试计数
    _retryCount = 0;
    
    [[NSNotificationCenter defaultCenter] postNotificationName:MUConnectionConnectingNotification object:nil];
    
    if (wasConnected) {
        NSLog(@"⏳ Waiting 0.5s for socket cleanup...");

        [self performSelector:@selector(establishConnection) withObject:nil afterDelay:0.5];
    } else {
        [self establishConnection];
    }
}

- (BOOL) isConnected {
    return _connection != nil;
}

- (void) disconnectFromServer {
    NSLog(@"🛑 User initiated disconnect/cancel.");
    _isUserInitiatedDisconnect = YES;
    if ([_reconnectTimer isValid]) {
        [_reconnectTimer invalidate];
    }
    _reconnectTimer = nil;
    
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
            [self teardownConnection];
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

- (void) startNetworkMonitor {
    if (_pathMonitor) return;
    
    _pathMonitor = nw_path_monitor_create();
    nw_path_monitor_set_queue(_pathMonitor, dispatch_get_main_queue());
    _networkWasSatisfied = YES;
    
    __weak typeof(self) weakSelf = self;
    nw_path_monitor_set_update_handler(_pathMonitor, ^(nw_path_t path) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        BOOL isSatisfied = (nw_path_get_status(path) == nw_path_status_satisfied);
        
        if (!strongSelf->_networkWasSatisfied && isSatisfied) {
            NSLog(@"🌐 Network restored. Triggering reconnect...");
            // 网络恢复后，如果当前没有连接或连接已断开，则触发重连
            if (strongSelf->_connection == nil && strongSelf->_hostname != nil && !strongSelf->_isUserInitiatedDisconnect) {
                strongSelf->_retryCount = 0;
                [strongSelf establishConnection];
                NSDictionary *info = @{ @"isReconnecting": @(YES) };
                [[NSNotificationCenter defaultCenter] postNotificationName:MUConnectionConnectingNotification object:nil userInfo:info];
            }
        }
        
        strongSelf->_networkWasSatisfied = isSatisfied;
    });
    
    nw_path_monitor_start(_pathMonitor);
}

- (void) stopNetworkMonitor {
    if (_pathMonitor) {
        nw_path_monitor_cancel(_pathMonitor);
        _pathMonitor = nil;
    }
}

- (void) establishConnection {
    // 只有在 connectToHostname 中才重置为 0
    _isUserInitiatedDisconnect = NO;
    
    // 启动网络监控
    [self startNetworkMonitor];

    _connection = [[MKConnection alloc] init];
    [_connection setDelegate:self];
    [_connection setForceTCP:[[NSUserDefaults standardUserDefaults] boolForKey:@"NetworkForceTCP"]];
    [_connection setIgnoreSSLVerification:YES];
    
    _serverModel = [[MKServerModel alloc] initWithConnection:_connection];
    [_serverModel addDelegate:self];
    
    if (_certificateRef != nil) {
        // 如果这个服务器有专属证书，就优先使用可认证（含 identity）的证书链
        NSArray *certChain = MUIdentityBackedChainForPersistentRef(_certificateRef, @"server-specific");
        if (certChain && certChain.count > 0) {
            [_connection setCertificateChain:certChain];
            NSLog(@"🔐 Using server-specific certificate for connection. (chain length: %lu)", (unsigned long)certChain.count);
        } else {
            // 专属证书不可用，回退到全局默认
            NSLog(@"⚠️ Failed to resolve server-specific cert identity (%lu bytes). Falling back...", (unsigned long)_certificateRef.length);
            NSData *globalCert = [[NSUserDefaults standardUserDefaults] objectForKey:@"DefaultCertificate"];
            if (globalCert) {
                NSArray *fallbackChain = MUIdentityBackedChainForPersistentRef(globalCert, @"global-default");
                if (fallbackChain && fallbackChain.count > 0) {
                    [_connection setCertificateChain:fallbackChain];
                    NSLog(@"🔐 Fell back to global default certificate.");
                } else {
                    NSLog(@"👤 Global default certificate is unusable for client auth. Connecting anonymously.");
                }
            } else {
                NSLog(@"👤 No fallback certificate available. Connecting anonymously.");
            }
        }
    } else {
        // 如果没有专属证书，再回退到全局默认 (可选，或者直接匿名)
        NSData *globalCert = [[NSUserDefaults standardUserDefaults] objectForKey:@"DefaultCertificate"];
        if (globalCert) {
            NSArray *certChain = MUIdentityBackedChainForPersistentRef(globalCert, @"global-default");
            if (certChain && certChain.count > 0) {
                [_connection setCertificateChain:certChain];
                NSLog(@"🔐 Using global default certificate.");
            } else {
                NSLog(@"👤 Global default certificate is unusable for client auth. Connecting anonymously.");
            }
        } else {
            NSLog(@"👤 Connecting anonymously (No certificate).");
        }
    }
    
    // Ensure audio starts with a valid connection snapshot already attached.
    NSLog(@"🎤 Starting Audio Engine...");
    [[MKAudio sharedAudio] restart];
    
    [_connection connectToHost:_hostname port:_port];
}

- (void) teardownConnection {
    [self stopNetworkMonitor];
    
    if (_serverModel) {
        [_serverModel removeDelegate:self];
        _serverModel = nil;
    }
    
    if (_connection) {
        [_connection setDelegate:nil];
        [_connection disconnect];
        _connection = nil;
    }
    [_timer invalidate];
#if TARGET_OS_IOS
    [[UNUserNotificationCenter currentNotificationCenter] setBadgeCount:0 withCompletionHandler:nil];
#endif
    
    // --- 核心修复：发送关闭通知 ---
    // AppState 收到这个通知后，会将 isConnected 设为 false，从而让界面回到首页
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:MUConnectionClosedNotification object:nil];
    });
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        NSLog(@"🎤 [Async] Stopping Audio Engine (Release Mic)...");
        [[MKAudio sharedAudio] stop];
        
        // 显式停用 Session，消除橙色点
        // 这个操作涉及系统 IPC 通信，是造成卡顿的主要原因
#if TARGET_OS_IOS
        NSError *error = nil;
        [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&error];
        
        if (error) {
            NSLog(@"⚠️ [Async] Failed to deactivate AudioSession: %@", error.localizedDescription);
        } else {
            NSLog(@"✅ [Async] Audio session deactivated successfully.");
        }
#endif
    });
}

- (void) postErrorWithTitle:(NSString *)title message:(NSString *)message {
    NSDictionary *userInfo = @{ @"title": title, @"message": message };
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:MUConnectionErrorNotification object:nil userInfo:userInfo];
        // 报错后必须 teardown，确保状态重置
        [self teardownConnection];
    });
}

- (void) postMessage:(NSString *)message type:(NSString *)type {
    if (!message) return;
    NSDictionary *userInfo = @{ @"message": message, @"type": type ?: @"info" };
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:MUAppShowMessageNotification object:nil userInfo:userInfo];
    });
}

// ... Key helper methods (unchanged) ...
- (NSString *) lastChannelKey { return [NSString stringWithFormat:@"LastChannel_%@_%lu_%@", _hostname, (unsigned long)_port, _username]; }
- (NSString *) muteStateKey { return [NSString stringWithFormat:@"State_Mute_%@_%lu_%@", _hostname, (unsigned long)_port, _username]; }
- (NSString *) deafStateKey { return [NSString stringWithFormat:@"State_Deaf_%@_%lu_%@", _hostname, (unsigned long)_port, _username]; }

#pragma mark - MKConnectionDelegate

- (void) connectionOpened:(MKConnection *)conn {
    // 连接成功，重置重试计数
    _retryCount = 0;
    
    NSArray *tokens = [MUDatabase accessTokensForServerWithHostname:[conn hostname] port:[conn port]];
    [conn authenticateWithUsername:_username password:_password accessTokens:tokens];
    
    NSString *nameToSave = (_displayName && _displayName.length > 0) ? _displayName : _hostname;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[RecentServerManager shared] addRecentWithHostname:self->_hostname
                                                       port:self->_port
                                                   username:self->_username
                                                displayName:nameToSave];
    });
}

- (void) connection:(MKConnection *)conn closedWithError:(NSError *)err {
    [self hideConnectingView];
    
    if (_isUserInitiatedDisconnect) {
        [self teardownConnection];
        return;
    }
    
    // If the error is a codec incompatibility, don't retry — it will always fail
    if ([[err domain] isEqualToString:@"MKConnection"]) {
        NSLog(@"❌ Connection closed due to unrecoverable error: %@", [err localizedFailureReason] ?: [err localizedDescription]);
        [self postErrorWithTitle:[err localizedDescription] ?: NSLocalizedString(@"Connection Failed", nil)
                         message:[err localizedFailureReason] ?: NSLocalizedString(@"The connection was closed due to an error.", nil)];
        return;
    }
    
    // --- 核心修复：重试逻辑 ---
    // 如果重试超过 10 次，就放弃并报错
    if (_retryCount >= 10) {
        NSLog(@"❌ Max retries reached (%ld). Giving up.", (long)_retryCount);
        [self postErrorWithTitle:NSLocalizedString(@"Connection Failed", nil)
                         message:NSLocalizedString(@"Unable to reconnect to server after multiple attempts.", nil)];
        return; // postError 会调用 teardown
    }
    
    _retryCount++;
    NSLog(@"⚠️ Connection closed unexpectedly. Attempting reconnect (Attempt %ld/10)...", (long)_retryCount);
    
    // 通知 UI 显示 "Reconnecting..."
    NSDictionary *info = @{ @"isReconnecting": @(YES) };
    [[NSNotificationCenter defaultCenter] postNotificationName:MUConnectionConnectingNotification object:nil userInfo:info];
    
    [_serverModel removeDelegate:self];
    _serverModel = nil;
    [_connection setDelegate:nil];
    [_connection disconnect];
    _connection = nil;
    
    [_reconnectTimer invalidate];
    _reconnectTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(performReconnect) userInfo:nil repeats:NO];
}

- (void) performReconnect {
    NSLog(@"🔄 Performing reconnect...");
    [self establishConnection];
}

- (void) connection:(MKConnection*)conn unableToConnectWithError:(NSError *)err {
    NSString *msg = [err localizedDescription];
    if ([[err domain] isEqualToString:NSOSStatusErrorDomain] && [err code] == -9806) {
        msg = NSLocalizedString(@"The TLS connection was closed due to an error.", nil);
    }
    // 无法连接 -> 报错 -> teardown -> 回到首页
    [self postErrorWithTitle:NSLocalizedString(@"Unable to connect", nil) message:msg];
}

// ... (Rest of methods: trustFailure, rejected, serverModel delegates... ALL UNCHANGED) ...
// 请保持剩余代码与之前一致
- (void) connection:(MKConnection *)conn trustFailureInCertificateChain:(NSArray *)chain {
    NSLog(@"⚠️ Certificate Trust Failure - Automatically trusting for now.");
    MKCertificate *cert = [[conn peerCertificates] firstObject];
    NSString *serverDigest = [cert hexDigest];
    [MUDatabase storeDigest:serverDigest forServerWithHostname:[conn hostname] port:[conn port]];
    [conn setIgnoreSSLVerification:YES];
    [conn reconnect];
}

- (void) connection:(MKConnection *)conn rejectedWithReason:(MKRejectReason)reason explanation:(NSString *)explanation {
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
    
    if (reason == MKRejectReasonUsernameInUse) {
        // 检查：如果当前没有使用证书 (未注册/匿名)
        if (self.currentCertificateRef == nil) {
            NSLog(@"⚠️ Username in use (Unregistered). Aborting retry and showing guidance.");
            
            // 构建引导注册的提示信息
            title = NSLocalizedString(@"Username Already in Use", nil);
            msg = NSLocalizedString(@"Your username is still active from a previous session.\nSince you are not registered, you cannot disconnect the old session immediately.\n\nTip: If you are seeing this from reconnecting, register your user on the server to allow instant reconnection in the future.", nil);
            
            // 直接报错显示弹窗，不进行自动重连
            [self postErrorWithTitle:title message:msg];
            return;
        } else {
            // 如果已注册 (有证书)，继续尝试自动重连 (等待 Ghost Session 被顶掉)
            NSLog(@"⚠️ Username in use (Registered). Waiting for server to kick old session... Retrying.");
            NSError *err = [NSError errorWithDomain:@"Mumble" code:reason userInfo:@{NSLocalizedDescriptionKey: @"Username already in use (Ghost Session)"}];
            [self connection:conn closedWithError:err];
            return;
        }
    }
    
    if (explanation && explanation.length > 0 && ![explanation isEqualToString:msg]) {
        msg = [NSString stringWithFormat:@"%@\n\n%@", msg, explanation];
    }
    
    [self postErrorWithTitle:title message:msg];
}

- (void) serverModel:(MKServerModel *)model joinedServerAsUser:(MKUser *)user withWelcomeMessage:(MKTextMessage *)welcomeMessage {
    // 1. 存储用户名
    [MUDatabase storeUsername:[user userName] forServerWithHostname:[model hostname] port:[model port]];
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSInteger lastChannelId = [defaults integerForKey:[self lastChannelKey]];
    BOOL shouldMute = [defaults boolForKey:[self muteStateKey]];
    BOOL shouldDeaf = [defaults boolForKey:[self deafStateKey]];
    
    // 2. 恢复静音状态
    if (shouldMute || shouldDeaf) {
        if (shouldDeaf) shouldMute = YES;
        [model setSelfMuted:shouldMute andSelfDeafened:shouldDeaf];
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
            NSString *displayTitle = self->_displayName;
            if (!displayTitle || [displayTitle length] == 0) {
                displayTitle = self->_hostname;
            }
            
            NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
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
            [[NSNotificationCenter defaultCenter] postNotificationName:MUConnectionOpenedNotification
                                                                object:self
                                                              userInfo:userInfo];
        });
    }];
}

// ... (Copy remaining serverModel delegates from previous answer) ...
- (void) serverModel:(MKServerModel *)model userMoved:(MKUser *)user toChannel:(MKChannel *)chan fromChannel:(MKChannel *)prevChan byUser:(MKUser *)mover {
    if (user == [model connectedUser]) {
        [[NSUserDefaults standardUserDefaults] setInteger:[chan channelId] forKey:[self lastChannelKey]];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
}
- (void) serverModel:(MKServerModel *)model userSelfMuteDeafenStateChanged:(MKUser *)user {
    if (user == [model connectedUser]) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setBool:[user isSelfMuted] forKey:[self muteStateKey]];
        [defaults setBool:[user isSelfDeafened] forKey:[self deafStateKey]];
        [defaults synchronize];
    }
}
- (void) serverModel:(MKServerModel *)model userKicked:(MKUser *)user byUser:(MKUser *)actor forReason:(NSString *)reason {
    if (user == [model connectedUser]) {
        NSString *msg = [NSString stringWithFormat:NSLocalizedString(@"Kicked by %@: %@", nil), [actor userName], reason ?: @""];
        [self postErrorWithTitle:NSLocalizedString(@"You were kicked", nil) message:msg];
    }
}
- (void) serverModel:(MKServerModel *)model userBanned:(MKUser *)user byUser:(MKUser *)actor forReason:(NSString *)reason {
    if (user == [model connectedUser]) {
        NSString *msg = [NSString stringWithFormat:NSLocalizedString(@"Banned by %@: %@", nil), [actor userName], reason ?: @""];
        [self postErrorWithTitle:NSLocalizedString(@"You were banned", nil) message:msg];
    }
}
- (void) serverModel:(MKServerModel *)model userJoined:(MKUser *)user {}
- (void) serverModel:(MKServerModel *)model userDisconnected:(MKUser *)user {}
- (void) serverModel:(MKServerModel *)model userLeft:(MKUser *)user {}
- (void) serverModel:(MKServerModel *)model userTalkStateChanged:(MKUser *)user {}
- (void) serverModel:(MKServerModel *)model permissionDenied:(MKPermission)perm forUser:(MKUser *)user inChannel:(MKChannel *)channel {
    [self postMessage:NSLocalizedString(@"Permission denied", nil) type:@"error"];
}
- (void) serverModel:(MKServerModel *)model permissionDeniedForReason:(NSString *)reason {
    NSString *msg = reason ?: NSLocalizedString(@"Permission denied", nil);
    [self postMessage:msg type:@"error"];
}
- (void) serverModelInvalidChannelNameError:(MKServerModel *)model {
    [self postMessage:NSLocalizedString(@"Invalid channel name", nil) type:@"error"];
}
- (void) serverModelModifySuperUserError:(MKServerModel *)model {
    [self postMessage:NSLocalizedString(@"Cannot modify SuperUser", nil) type:@"error"];
}
- (void) serverModelTextMessageTooLongError:(MKServerModel *)model {
    [self postMessage:NSLocalizedString(@"Message too long", nil) type:@"error"];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"MUMessageSendFailed"
                                                        object:nil
                                                      userInfo:@{@"reason": @"permissionDenied"}];
}
- (void) serverModelTemporaryChannelError:(MKServerModel *)model {
    [self postMessage:NSLocalizedString(@"Not permitted in temporary channel", nil) type:@"error"];
}
- (void) serverModel:(MKServerModel *)model missingCertificateErrorForUser:(MKUser *)user {
    [self postMessage:NSLocalizedString(@"Missing certificate", nil) type:@"error"];
}
- (void) serverModel:(MKServerModel *)model invalidUsernameErrorForName:(NSString *)name {
    NSString *msg = [NSString stringWithFormat:@"Invalid username: %@", name ?: @""];
    [self postMessage:msg type:@"error"];
}
- (void) serverModelChannelFullError:(MKServerModel *)model {
    [self postMessage:NSLocalizedString(@"Channel is full", nil) type:@"error"];
}
@end
