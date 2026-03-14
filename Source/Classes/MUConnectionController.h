// Copyright 2009-2011 The 'Mumble for iOS' Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import <Foundation/Foundation.h>

// 前向声明 MKServerModel
@class MKServerModel;
@class MKConnection;

extern NSString *MUConnectionOpenedNotification;  // 连接成功 (已有)
extern NSString *MUConnectionClosedNotification;  // 连接关闭 (已有)
extern NSString *MUConnectionConnectingNotification; // 正在连接 (新增)
extern NSString *MUAppShowMessageNotification;
extern NSString *MUConnectionUDPTransportStatusNotification;

// 错误处理通知 (新增)
// userInfo key: @"title", @"message"
extern NSString *MUConnectionErrorNotification;

// SSL 证书信任失败通知
// userInfo keys: @"hostname", @"port", @"subjectName", @"issuerName",
//               @"fingerprint", @"notBefore", @"notAfter", @"isChanged"
extern NSString *MUCertificateTrustFailureNotification;

@interface MUConnectionController : NSObject
+ (MUConnectionController *) sharedController;
- (void) connectToHostname:(NSString *)hostName
                     port:(NSUInteger)port
             withUsername:(NSString *)userName
              andPassword:(NSString *)password
           certificateRef:(NSData *)certRef
              displayName:(NSString *)displayName;
- (BOOL) isConnected;
- (void) disconnectFromServer;
- (void) acceptCertificateTrust;
- (void) rejectCertificateTrust;
@property (nonatomic, strong, readonly) NSString *lastWelcomeMessage;
@property (nonatomic, readonly) MKServerModel *serverModel;
@property (nonatomic, readonly) NSData *currentCertificateRef;

@property (nonatomic, readonly) MKConnection *connection;

@end
