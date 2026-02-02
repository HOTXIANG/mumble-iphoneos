// Copyright 2009-2011 The 'Mumble for iOS' Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import "MUConnectionController.h"
#import "MUServerRootViewController.h"
#import "MUServerCertificateTrustViewController.h"
#import "MUCertificateController.h"
#import "MUCertificateChainBuilder.h"
#import "MUDatabase.h"
#import "Mumble-Swift.h"

#import <MumbleKit/MKAudio.h>
#import <MumbleKit/MKConnection.h>
#import <MumbleKit/MKServerModel.h>
#import <MumbleKit/MKCertificate.h>
#import <AVFoundation/AVFoundation.h>

NSString *MUConnectionOpenedNotification = @"MUConnectionOpenedNotification";
NSString *MUConnectionClosedNotification = @"MUConnectionClosedNotification";
NSString *MUConnectionConnectingNotification = @"MUConnectionConnectingNotification";
NSString *MUConnectionErrorNotification = @"MUConnectionErrorNotification";

NSString *MUAppShowMessageNotification = @"MUAppShowMessageNotification";

@interface MUConnectionController () <MKConnectionDelegate, MKServerModelDelegate, MUServerCertificateTrustViewControllerProtocol> {
    MKConnection               *_connection;
    MKServerModel              *_serverModel;
    MUServerRootViewController *_serverRoot;
    UIViewController           *_parentViewController;
    UIAlertController          *_alertCtrl;
    NSTimer                    *_timer;
    int                        _numDots;

    UIAlertController          *_rejectAlertCtrl;
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
}
- (void) establishConnection;
- (void) teardownConnection;
- (void) showConnectingView;
- (void) hideConnectingView;
- (void) hideConnectingViewWithCompletion:(void(^)(void))completion;
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

- (void) connetToHostname:(NSString *)hostName
                     port:(NSUInteger)port
             withUsername:(NSString *)userName
              andPassword:(NSString *)password
           certificateRef:(NSData *)certRef
              displayName:(NSString *)displayName {
    
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
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self establishConnection];
        });
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
    
    [_serverRoot dismissViewControllerAnimated:YES completion:nil];
    [self teardownConnection];
}

- (void) showConnectingView {
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
}

- (void) updateTitle {
    if (_alertCtrl) {
        _numDots = (_numDots + 1) % 4;
        NSString *dots = @"";
        for (int i = 0; i < _numDots; i++) dots = [dots stringByAppendingString:@"."];
        _alertCtrl.title = [NSString stringWithFormat:@"%@%@", NSLocalizedString(@"Connecting", nil), dots];
    }
}

- (void) hideConnectingView {
    [self hideConnectingViewWithCompletion:nil];
}

- (void) hideConnectingViewWithCompletion:(void (^)(void))completion {
    [_timer invalidate];
    _timer = nil;

    if (_alertCtrl != nil && _parentViewController != nil) {
        [_parentViewController dismissViewControllerAnimated:YES completion:completion];
        _alertCtrl = nil;
    } else {
        if (completion) {
            completion();
        }
    }
}

- (void) establishConnection {
    NSLog(@"🎤 Starting Audio Engine for connection...");
    [[MKAudio sharedAudio] restart];
    // 只有在 connetToHostname 中才重置为 0
    _isUserInitiatedDisconnect = NO;
    
    _connection = [[MKConnection alloc] init];
    [_connection setDelegate:self];
    [_connection setForceTCP:[[NSUserDefaults standardUserDefaults] boolForKey:@"NetworkForceTCP"]];
    [_connection setIgnoreSSLVerification:YES];
    
    _serverModel = [[MKServerModel alloc] initWithConnection:_connection];
    [_serverModel addDelegate:self];
    
    _serverRoot = [[MUServerRootViewController alloc] initWithConnection:_connection andServerModel:_serverModel];

    if (_certificateRef != nil) {
        // 如果这个服务器有专属证书，就用它
        NSArray *certChain = [MUCertificateChainBuilder buildChainFromPersistentRef:_certificateRef];
        [_connection setCertificateChain:certChain];
        NSLog(@"🔐 Using server-specific certificate for connection.");
    } else {
        // 如果没有专属证书，再回退到全局默认 (可选，或者直接匿名)
        // 建议：如果你想要彻底隔离，这里可以删掉 fallback，让其直接匿名
        NSData *globalCert = [[NSUserDefaults standardUserDefaults] objectForKey:@"DefaultCertificate"];
        if (globalCert) {
            NSArray *certChain = [MUCertificateChainBuilder buildChainFromPersistentRef:globalCert];
            [_connection setCertificateChain:certChain];
            NSLog(@"🔐 Using global default certificate.");
        } else {
            NSLog(@"👤 Connecting anonymously (No certificate).");
        }
    }
    
    [_connection connectToHost:_hostname port:_port];
}

- (void) teardownConnection {
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
    _serverRoot = nil;
    
    [[UIApplication sharedApplication] setApplicationIconBadgeNumber:0];
    
    // --- 核心修复：发送关闭通知 ---
    // AppState 收到这个通知后，会将 isConnected 设为 false，从而让界面回到首页
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:MUConnectionClosedNotification object:nil];
    });
    
    NSLog(@"🎤 Stopping Audio Engine (Release Mic)...");
    [[MKAudio sharedAudio] stop];
    
    // 显式停用 Session，确保系统状态栏的橙色点立即消失
    NSError *error = nil;
    [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&error];
    if (error) {
        NSLog(@"⚠️ Failed to deactivate AudioSession: %@", error.localizedDescription);
    }
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
                // MumbleKit 的 MKTextMessage 通常有一个 plainTextString 方法或者直接取 string (HTML)
                // 这里我们尝试取纯文本，如果没有则取原始 HTML string
                NSString *msgContent = [welcomeMessage plainTextString];
                if (!msgContent) {
                    if ([welcomeMessage respondsToSelector:@selector(message)]) {
                        msgContent = [welcomeMessage performSelector:@selector(message)];
                    }
                }
                if (msgContent) {
                    userInfo[@"welcomeMessage"] = msgContent;
                }
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
- (void) serverCertificateTrustViewControllerDidDismiss:(MUServerCertificateTrustViewController *)trustView {
    [self showConnectingView];
    [_connection reconnect];
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
