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

#import <MumbleKit/MKConnection.h>
#import <MumbleKit/MKServerModel.h>
#import <MumbleKit/MKCertificate.h>

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
    NSString                   *_displayName;
    
    BOOL            _isUserInitiatedDisconnect; // 是否用户主动断开
    NSTimer         *_reconnectTimer;           // 重连定时器
    NSInteger       _retryCount;                // 重试计数

}
- (void) establishConnection;
- (void) teardownConnection;
- (void) showConnectingView;
- (void) hideConnectingView;
- (void) hideConnectingViewWithCompletion:(void(^)(void))completion;
@end

@implementation MUConnectionController

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
        
    }
    return self;
}

- (MKServerModel *)serverModel {
    return _serverModel;
}

- (void) connetToHostname:(NSString *)hostName port:(NSUInteger)port withUsername:(NSString *)userName andPassword:(NSString *)password displayName:(NSString *)displayName {
    _hostname = [hostName copy];
    _port = port;
    _username = [userName copy];
    _password = [password copy];
    _displayName = [displayName copy];
    
    // 发送“正在连接”通知，SwiftUI 可以借此显示 Loading 转圈
    [[NSNotificationCenter defaultCenter] postNotificationName:MUConnectionConnectingNotification object:nil];
    
    [self establishConnection];
}

- (BOOL) isConnected {
    return _connection != nil;
}

- (void) disconnectFromServer {
    NSLog(@"🛑 User initiated disconnect/cancel.");
    _isUserInitiatedDisconnect = YES; // 标记为主动断开
    // 1. 停止任何正在进行的重连定时器
    if ([_reconnectTimer isValid]) {
        [_reconnectTimer invalidate];
    }
    _reconnectTimer = nil;
    
    if (_connection) {
        NSLog(@"🛑 Attempting to send disconnect packet...");
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
    [_parentViewController presentViewController:_alertCtrl animated:YES completion:nil];
    
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.2f target:self selector:@selector(updateTitle) userInfo:nil repeats:YES];
}

- (void) hideConnectingView {
    [self hideConnectingViewWithCompletion:nil];
}

- (void) hideConnectingViewWithCompletion:(void (^)(void))completion {
    [_timer invalidate];
    _timer = nil;

    if (_alertCtrl != nil) {
        [_parentViewController dismissViewControllerAnimated:YES completion:completion];
        _alertCtrl = nil;
    }
}

- (void) establishConnection {
    // 每次开始新连接时，重置主动断开标志
    _isUserInitiatedDisconnect = NO;
    
    _connection = [[MKConnection alloc] init];
    [_connection setDelegate:self];
    [_connection setForceTCP:[[NSUserDefaults standardUserDefaults] boolForKey:@"NetworkForceTCP"]];
    
    // 添加：设置忽略 SSL 验证（用于测试）
    [_connection setIgnoreSSLVerification:YES];
    
    _serverModel = [[MKServerModel alloc] initWithConnection:_connection];
    [_serverModel addDelegate:self];
    
    _serverRoot = [[MUServerRootViewController alloc] initWithConnection:_connection andServerModel:_serverModel];
    
    // Set the connection's client cert if one is set in the app's preferences...
    NSData *certPersistentId = [[NSUserDefaults standardUserDefaults] objectForKey:@"DefaultCertificate"];
    if (certPersistentId != nil) {
        NSArray *certChain = [MUCertificateChainBuilder buildChainFromPersistentRef:certPersistentId];
        [_connection setCertificateChain:certChain];
    }
    
    [_connection connectToHost:_hostname port:_port];

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:MUConnectionOpenedNotification object:nil];
    });
}

- (void) teardownConnection {
    // 1. 先断开 Model 的代理，防止后续不仅要的消息刷屏
    if (_serverModel) {
        [_serverModel removeDelegate:self];
        _serverModel = nil;
    }
    
    // 2. 再次确保断开连接并清理代理
    if (_connection) {
        [_connection setDelegate:nil];
        // 即使 disconnectFromServer 已经调用过，这里再调用一次也是安全的（幂等操作），
        // 确保如果是从其他路径进入 teardown（比如证书错误），也能断开连接。
        [_connection disconnect];
        _connection = nil;
    }
    [_timer invalidate];
    _serverRoot = nil;
    
    // Reset app badge. The connection is no more.
    [[UIApplication sharedApplication] setApplicationIconBadgeNumber:0];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:MUConnectionClosedNotification object:nil];
    });
}
            
// 辅助方法：发送错误通知
- (void) postErrorWithTitle:(NSString *)title message:(NSString *)message {
    NSDictionary *userInfo = @{ @"title": title, @"message": message };
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:MUConnectionErrorNotification object:nil userInfo:userInfo];
        // 发生错误时，通常也意味着连接断开/终止
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

- (NSString *) lastChannelKey {
    return [NSString stringWithFormat:@"LastChannel_%@_%lu_%@", _hostname, (unsigned long)_port, _username];
}

// 生成状态存储 Key，绑定到具体服务器和用户名，避免跨服务器混淆
- (NSString *) muteStateKey {
    return [NSString stringWithFormat:@"State_Mute_%@_%lu_%@", _hostname, (unsigned long)_port, _username];
}

- (NSString *) deafStateKey {
    return [NSString stringWithFormat:@"State_Deaf_%@_%lu_%@", _hostname, (unsigned long)_port, _username];
}

#pragma mark - MKConnectionDelegate

- (void) connectionOpened:(MKConnection *)conn {
    NSArray *tokens = [MUDatabase accessTokensForServerWithHostname:[conn hostname] port:[conn port]];
    [conn authenticateWithUsername:_username password:_password accessTokens:tokens];
    
    NSString *nameToSave = (_displayName && _displayName.length > 0) ? _displayName : _hostname;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // 调用 Swift 的 addRecent，把名字存进去！
        [[RecentServerManager shared] addRecentWithHostname:self->_hostname
                                                       port:self->_port
                                                   username:self->_username
                                                displayName:nameToSave];
    });
}

- (void) connection:(MKConnection *)conn closedWithError:(NSError *)err {
    [self hideConnectingView]; // 关闭初始连接时的 Alert（如果有）
    
    if (_isUserInitiatedDisconnect) {
        // 情况 A: 用户点了“断开”按钮 -> 正常清理，回主页
        [self teardownConnection];
        return;
    }
    
    // 情况 B: 意外断线 -> 尝试重连
    NSLog(@"⚠️ Connection closed unexpectedly. Attempting reconnect...");
    
    // 1. 发送“正在重连”通知给 SwiftUI (稍后在 Swift 端定义这个通知名)
    // 我们复用 MUConnectionConnectingNotification，或者定义一个新的
    // 为了区分 UI（显示“Reconnecting”而不是“Connecting”），我们通过 userInfo 传参
    NSDictionary *info = @{ @"isReconnecting": @(YES) };
    [[NSNotificationCenter defaultCenter] postNotificationName:MUConnectionConnectingNotification object:nil userInfo:info];
    
    // 2. 销毁旧的底层连接对象 (必须清理，否则状态会乱)
    [_serverModel removeDelegate:self];
    _serverModel = nil;
    [_connection setDelegate:nil];
    [_connection disconnect];
    _connection = nil;
    
    // 3. 启动定时器，3秒后重试
    [_reconnectTimer invalidate];
    _reconnectTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self selector:@selector(performReconnect) userInfo:nil repeats:NO];
}

// 执行重连的 Action
- (void) performReconnect {
    NSLog(@"🔄 Performing reconnect...");
    [self establishConnection];
}

- (void) connection:(MKConnection*)conn unableToConnectWithError:(NSError *)err {
    NSString *msg = [err localizedDescription];
    if ([[err domain] isEqualToString:NSOSStatusErrorDomain] && [err code] == -9806) {
        msg = NSLocalizedString(@"The TLS connection was closed due to an error.", nil);
    }
    [self postErrorWithTitle:NSLocalizedString(@"Unable to connect", nil) message:msg];
}

// The connection encountered an invalid SSL certificate chain.
- (void) connection:(MKConnection *)conn trustFailureInCertificateChain:(NSArray *)chain {
    // 简化处理：暂时全部自动信任 (Refactor Phase 2 暂且跳过复杂的证书弹窗逻辑)
    // 后续我们可以在 Swift 端实现一个更好的证书确认流程
    NSLog(@"⚠️ Certificate Trust Failure - Automatically trusting for now.");
    
    MKCertificate *cert = [[conn peerCertificates] firstObject];
    NSString *serverDigest = [cert hexDigest];
    [MUDatabase storeDigest:serverDigest forServerWithHostname:[conn hostname] port:[conn port]];
    
    [conn setIgnoreSSLVerification:YES];
    [conn reconnect];
}

// The server rejected our connection.
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
    
    if (explanation && explanation.length > 0) {
        msg = [NSString stringWithFormat:@"%@\n\n%@", msg, explanation];
    }

    [self postErrorWithTitle:title message:msg];
}

#pragma mark - MKServerModelDelegate

- (void) serverModel:(MKServerModel *)model joinedServerAsUser:(MKUser *)user {
    [MUDatabase storeUsername:[user userName] forServerWithHostname:[model hostname] port:[model port]];
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSInteger lastChannelId = [defaults integerForKey:[self lastChannelKey]];
    BOOL shouldMute = [defaults boolForKey:[self muteStateKey]];
    BOOL shouldDeaf = [defaults boolForKey:[self deafStateKey]];
    
    // 如果有记录状态（且状态为真），则应用
    if (shouldMute || shouldDeaf) {
        NSLog(@"🔄 Restoring user state: Muted=%d, Deafened=%d", shouldMute, shouldDeaf);
        // 注意：Mumble 协议要求如果 Deaf 为真，Mute 必须也为真
        if (shouldDeaf) shouldMute = YES;
        [model setSelfMuted:shouldMute andSelfDeafened:shouldDeaf];
    }
    
    // 0 通常是 Root 频道，如果存的是 0 就不需要动
    if (lastChannelId > 0) {
        MKChannel *targetChannel = [model channelWithId:lastChannelId];
        if (targetChannel) {
            NSLog(@"🔄 Automatically joining last channel: %@", [targetChannel channelName]);
            [model joinChannel:targetChannel];
        }
    }
    
    [self hideConnectingViewWithCompletion:^{
        [self->_serverRoot takeOwnershipOfConnectionDelegate];
        dispatch_async(dispatch_get_main_queue(), ^{
            
            NSString *displayTitle = self->_displayName;
            if (!displayTitle || [displayTitle length] == 0) {
                displayTitle = self->_hostname;
            }
            
            // 构建 userInfo
            NSDictionary *userInfo = nil;
            if (displayTitle) {
                userInfo = @{ @"displayName": displayTitle };
            }
            
            NSLog(@"   -> Final UserInfo to send: %@", userInfo);
            
            [[NSNotificationCenter defaultCenter] postNotificationName:@"MUConnectionReadyForSwiftUI"
                                                                object:self
                                                              userInfo:userInfo];
            
            [[NSNotificationCenter defaultCenter] postNotificationName:MUConnectionOpenedNotification
                                                                object:self
                                                              userInfo:userInfo];
        });
    }];
}

- (void) serverModel:(MKServerModel *)model userMoved:(MKUser *)user toChannel:(MKChannel *)chan fromChannel:(MKChannel *)prevChan byUser:(MKUser *)mover {
    // 只有当移动的是“我自己”时才保存
    if (user == [model connectedUser]) {
        [[NSUserDefaults standardUserDefaults] setInteger:[chan channelId] forKey:[self lastChannelKey]];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
}

- (void) serverModel:(MKServerModel *)model userSelfMuteDeafenStateChanged:(MKUser *)user {
    // 只保存“我自己”的状态
    if (user == [model connectedUser]) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setBool:[user isSelfMuted] forKey:[self muteStateKey]];
        [defaults setBool:[user isSelfDeafened] forKey:[self deafStateKey]];
        [defaults synchronize];
        // NSLog(@"💾 Saved user state: Muted=%d, Deafened=%d", [user isSelfMuted], [user isSelfDeafened]);
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

// ✅ 1. 权限拒绝 (带类型)
- (void) serverModel:(MKServerModel *)model permissionDenied:(MKPermission)perm forUser:(MKUser *)user inChannel:(MKChannel *)channel {
    // 简单处理：直接提示权限不足
    [self postMessage:NSLocalizedString(@"Permission denied", nil) type:@"error"];
}

// ✅ 2. 权限拒绝 (带原因字符串)
- (void) serverModel:(MKServerModel *)model permissionDeniedForReason:(NSString *)reason {
    NSString *msg = reason ?: NSLocalizedString(@"Permission denied", nil);
    [self postMessage:msg type:@"error"];
}

// ✅ 3. 频道名称无效
- (void) serverModelInvalidChannelNameError:(MKServerModel *)model {
    [self postMessage:NSLocalizedString(@"Invalid channel name", nil) type:@"error"];
}

// ✅ 4. 修改超级用户错误
- (void) serverModelModifySuperUserError:(MKServerModel *)model {
    [self postMessage:NSLocalizedString(@"Cannot modify SuperUser", nil) type:@"error"];
}

// ✅ 5. 文本消息过长
- (void) serverModelTextMessageTooLongError:(MKServerModel *)model {
    [self postMessage:NSLocalizedString(@"Message too long", nil) type:@"error"];
}

// ✅ 6. 临时频道错误
- (void) serverModelTemporaryChannelError:(MKServerModel *)model {
    [self postMessage:NSLocalizedString(@"Not permitted in temporary channel", nil) type:@"error"];
}

// ✅ 7. 缺少证书
- (void) serverModel:(MKServerModel *)model missingCertificateErrorForUser:(MKUser *)user {
    [self postMessage:NSLocalizedString(@"Missing certificate", nil) type:@"error"];
}

// ✅ 8. 无效用户名
- (void) serverModel:(MKServerModel *)model invalidUsernameErrorForName:(NSString *)name {
    NSString *msg = [NSString stringWithFormat:@"Invalid username: %@", name ?: @""];
    [self postMessage:msg type:@"error"];
}

// ✅ 9. 频道已满
- (void) serverModelChannelFullError:(MKServerModel *)model {
    [self postMessage:NSLocalizedString(@"Channel is full", nil) type:@"error"];
}

@end
