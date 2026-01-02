// Copyright 2009-2010 The 'Mumble for iOS' Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

@import Foundation;
#import <MumbleKit/MKCertificate.h>

@interface MUCertificateController : NSObject
+ (MKCertificate *) certificateWithPersistentRef:(NSData *)persistentRef;
+ (OSStatus) deleteCertificateWithPersistentRef:(NSData *)persistentRef;

+ (NSString *) fingerprintFromHexString:(NSString *)hexDigest;

+ (void) setDefaultCertificateByPersistentRef:(NSData *)persistentRef;
+ (MKCertificate *) defaultCertificate;

+ (NSArray *) persistentRefsForIdentities;

+ (NSData *) generateSelfSignedCertificateWithName:(NSString *)name email:(NSString *)email;

// 导出指定身份为 P12 数据
+ (NSData *) exportPKCS12DataForPersistentRef:(NSData *)ref password:(NSString *)password;

// 导入 P12 数据到 Keychain
+ (NSData *) importPKCS12Data:(NSData *)data password:(NSString *)password error:(NSError **)error;
@end
