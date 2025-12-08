// Copyright 2009-2011 The 'Mumble for iOS' Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import "MUConnectionController.h"
#import "MUServerRootViewController.h"
#import "MUServerCertificateTrustViewController.h"
#import "MUCertificateController.h"
#import "MUCertificateChainBuilder.h"
#import "MUDatabase.h"

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

- (void) connetToHostname:(NSString *)hostName port:(NSUInteger)port withUsername:(NSString *)userName andPassword:(NSString *)password {
    _hostname = [hostName copy];
    _port = port;
    _username = [userName copy];
    _password = [password copy];
    
    // 发送“正在连接”通知，SwiftUI 可以借此显示 Loading 转圈
    [[NSNotificationCenter defaultCenter] postNotificationName:MUConnectionConnectingNotification object:nil];
    
    [self establishConnection];
}

- (BOOL) isConnected {
    return _connection != nil;
}

- (void) disconnectFromServer {
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
    [_serverModel removeDelegate:self];
    _serverModel = nil;
    [_connection setDelegate:nil];
    [_connection disconnect];
    _connection = nil;
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

#pragma mark - MKConnectionDelegate

- (void) connectionOpened:(MKConnection *)conn {
    NSArray *tokens = [MUDatabase accessTokensForServerWithHostname:[conn hostname] port:[conn port]];
    [conn authenticateWithUsername:_username password:_password accessTokens:tokens];
}

- (void) connection:(MKConnection *)conn closedWithError:(NSError *)err {
    if (err) {
        [self postErrorWithTitle:NSLocalizedString(@"Connection closed", nil)
                         message:[err localizedDescription]];
    } else {
        [self teardownConnection];
    }
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
    
    // 清理凭据
    _username = nil;
    _hostname = nil;
    _password = nil;
    
    // 通知全区：连接成功！
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:MUConnectionOpenedNotification object:self];
    });
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
