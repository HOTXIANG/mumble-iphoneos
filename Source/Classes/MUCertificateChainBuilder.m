// Copyright 2012 The 'Mumble for iOS' Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import "MUCertificateChainBuilder.h"
#include <MumbleKit/MKCertificate.h>
@import Security;

// 辅助函数：验证 child 是否由 parent 签名
static BOOL IsSignedBy(SecCertificateRef child, SecCertificateRef parent) {
    if (!child || !parent) return NO;
    
    SecPolicyRef policy = SecPolicyCreateBasicX509();
    SecTrustRef trust = NULL;
    
    // --- 修复：移除 __bridge，直接使用 C 类型转换 ---
    // SecCertificateRef -> CFTypeRef 是 C 指针转换，不需要桥接
    OSStatus status = SecTrustCreateWithCertificates((CFTypeRef)child, policy, &trust);
    CFRelease(policy);
    
    if (status != errSecSuccess || !trust) {
        return NO;
    }
    
    // 将父证书设为唯一的信任锚点（Anchor）
    // 这里 anchors 是 NSArray (OC对象)，转换为 CFArrayRef 需要 __bridge
    NSArray *anchors = @[(__bridge id)parent];
    SecTrustSetAnchorCertificates(trust, (__bridge CFArrayRef)anchors);
    
    // 禁用网络获取，只进行本地验证
    SecTrustSetNetworkFetchAllowed(trust, false);
    
    SecTrustResultType result;
    // 忽略 SecTrustEvaluate 在 iOS 13+ 的废弃警告
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    status = SecTrustEvaluate(trust, &result);
#pragma clang diagnostic pop
    
    CFRelease(trust);
    
    // 如果验证成功 (Proceed) 或 未指定 (Unspecified, 通常指自签名或手动信任)，则认为签名匹配
    return (status == errSecSuccess && (result == kSecTrustResultUnspecified || result == kSecTrustResultProceed));
}

// 查找证书的有效父级证书
static NSArray *FindValidParentsForCert(SecCertificateRef cert) {
    CFDataRef issuerData = SecCertificateCopyNormalizedIssuerSequence(cert);
    if (!issuerData) return nil;
    
    // CFDataRef -> NSData* 需要 __bridge_transfer
    NSData *issuer = (__bridge_transfer NSData *)issuerData;

    // 在 Keychain 中搜索 Subject 等于该 Issuer 的证书
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassCertificate,
        (__bridge id)kSecAttrSubject: issuer,
        (__bridge id)kSecReturnRef: (__bridge id)kCFBooleanTrue,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll
    };

    CFTypeRef result = NULL;
    OSStatus err = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    
    if (err != noErr) {
        return nil;
    }

    NSArray *matches = (__bridge_transfer NSArray *)result;
    NSMutableArray *parents = [NSMutableArray arrayWithCapacity:[matches count]];

    for (id match in matches) {
        // id -> SecCertificateRef 需要 __bridge
        SecCertificateRef parentCert = (__bridge SecCertificateRef)match;
        
        CFDataRef parentSubjectData = SecCertificateCopyNormalizedSubjectSequence(parentCert);
        CFDataRef parentIssuerData = SecCertificateCopyNormalizedIssuerSequence(parentCert);
        
        BOOL isSelfSigned = NO;
        if (parentSubjectData && parentIssuerData) {
            if ([(__bridge NSData *)parentSubjectData isEqualToData:(__bridge NSData *)parentIssuerData]) {
                isSelfSigned = YES;
            }
        }
        if (parentSubjectData) CFRelease(parentSubjectData);
        if (parentIssuerData) CFRelease(parentIssuerData);

        if (isSelfSigned)
            continue;

        // 验证签名
        if (IsSignedBy(cert, parentCert)) {
            [parents addObject:(__bridge id)parentCert];
        }
    }

    return parents;
}

static NSArray *BuildCertChainFromCert(SecCertificateRef cert) {
    NSMutableArray *chain = [[NSMutableArray alloc] initWithCapacity:1];
    
    // 添加叶子证书
    [chain addObject:(__bridge id)cert];

    SecCertificateRef current = cert;
    int depth = 0;
    
    // 构建链条，最大深度限制为 20 防止死循环
    while (depth < 20) {
        NSArray *parents = FindValidParentsForCert(current);
        if (parents == nil || [parents count] == 0)
            break;
        
        // 简单策略：取第一个找到的有效父证书
        SecCertificateRef parent = (__bridge SecCertificateRef)[parents objectAtIndex:0];
        
        // 防止循环引用
        if ([chain containsObject:(__bridge id)parent]) {
            break;
        }
        
        [chain addObject:(__bridge id)parent];
        current = parent;
        depth++;
    }

    return chain;
}

@implementation MUCertificateChainBuilder

+ (NSArray *) buildChainFromPersistentRef:(NSData *)persistentRef {
    CFTypeRef thing = NULL;
    OSStatus err;

    NSMutableArray *chain = [[NSMutableArray alloc] initWithCapacity:1];

    NSDictionary *query = @{
        (__bridge id)kSecValuePersistentRef: persistentRef,
        (__bridge id)kSecReturnRef: (__bridge id)kCFBooleanTrue,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };
    
    err = SecItemCopyMatching((__bridge CFDictionaryRef)query, &thing);
    if (err != noErr) {
        return nil;
    }

    CFTypeID typeID = CFGetTypeID(thing);
    
    if (typeID == SecIdentityGetTypeID()) {
        SecIdentityRef identity = (SecIdentityRef) thing;
        
        [chain addObject:(__bridge id)identity];
        
        SecCertificateRef cert = NULL;
        OSStatus copyStatus = SecIdentityCopyCertificate(identity, &cert);
        
        if (copyStatus == errSecSuccess && cert != NULL) {
            NSArray *firstValidChain = BuildCertChainFromCert(cert);
            [chain addObjectsFromArray:firstValidChain];
            CFRelease(cert);
        }
        
    } else if (typeID == SecCertificateGetTypeID()) {
        SecCertificateRef cert = (SecCertificateRef) thing;
        NSArray *firstValidChain = BuildCertChainFromCert(cert);
        [chain addObjectsFromArray:firstValidChain];
    }

    if (thing) {
        CFRelease(thing);
    }

    return chain;
}

@end
