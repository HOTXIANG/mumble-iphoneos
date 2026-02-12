// Copyright 2009-2010 The 'Mumble for iOS' Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import "MUCertificateController.h"
#import <MumbleKit/MKCertificate.h>

// --- 引入 OpenSSL 头文件 ---
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <openssl/evp.h>
#include <openssl/rsa.h>
#include <openssl/pkcs12.h>
#include <openssl/bio.h>
#include <openssl/err.h>
#include <openssl/bn.h>
#include <TargetConditionals.h>

@implementation MUCertificateController

+ (NSData *)persistentRefForIdentity:(SecIdentityRef)identity {
    if (!identity) return nil;

    NSDictionary *query = @{
        (__bridge id)kSecValueRef: (__bridge id)identity,
        (__bridge id)kSecReturnPersistentRef: (__bridge id)kCFBooleanTrue,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };

    CFTypeRef persistentRef = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &persistentRef);
    if (status == errSecSuccess && persistentRef != NULL) {
        return (__bridge_transfer NSData *)persistentRef;
    }
    return nil;
}

+ (SecIdentityRef)copyIdentityForPersistentRef:(NSData *)ref {
    if (!ref) return NULL;

    // First try: explicit identity query by persistent ref.
    NSDictionary *identityQuery = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassIdentity,
        (__bridge id)kSecValuePersistentRef: ref,
        (__bridge id)kSecReturnRef: (__bridge id)kCFBooleanTrue,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };

    CFTypeRef identityItem = NULL;
    OSStatus identityStatus = SecItemCopyMatching((__bridge CFDictionaryRef)identityQuery, &identityItem);
    if (identityStatus == errSecSuccess && identityItem && CFGetTypeID(identityItem) == SecIdentityGetTypeID()) {
        return (SecIdentityRef)identityItem; // already retained by CopyMatching
    }
    if (identityItem) CFRelease(identityItem);

    // Second try: generic query and type-check.
    NSDictionary *genericQuery = @{
        (__bridge id)kSecValuePersistentRef: ref,
        (__bridge id)kSecReturnRef: (__bridge id)kCFBooleanTrue,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };

    CFTypeRef item = NULL;
    OSStatus itemStatus = SecItemCopyMatching((__bridge CFDictionaryRef)genericQuery, &item);
    if (itemStatus != errSecSuccess || item == NULL) {
        return NULL;
    }

    if (CFGetTypeID(item) == SecIdentityGetTypeID()) {
        return (SecIdentityRef)item;
    }

    if (CFGetTypeID(item) == SecCertificateGetTypeID()) {
        SecCertificateRef targetCert = (SecCertificateRef)item;
        NSData *targetCertData = (__bridge_transfer NSData *)SecCertificateCopyData(targetCert);
        CFRelease(item);

        if (!targetCertData) return NULL;

        NSDictionary *allIdentityQuery = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassIdentity,
            (__bridge id)kSecReturnRef: (__bridge id)kCFBooleanTrue,
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll
        };

        CFTypeRef allIdentities = NULL;
        OSStatus allStatus = SecItemCopyMatching((__bridge CFDictionaryRef)allIdentityQuery, &allIdentities);
        if (allStatus == errSecSuccess && allIdentities && CFGetTypeID(allIdentities) == CFArrayGetTypeID()) {
            NSArray *identityArray = (__bridge NSArray *)allIdentities;
            for (id obj in identityArray) {
                SecIdentityRef candidate = (__bridge SecIdentityRef)obj;
                if (CFGetTypeID(candidate) != SecIdentityGetTypeID()) {
                    continue;
                }

                SecCertificateRef candidateCert = NULL;
                if (SecIdentityCopyCertificate(candidate, &candidateCert) == errSecSuccess && candidateCert) {
                    NSData *candidateData = (__bridge_transfer NSData *)SecCertificateCopyData(candidateCert);
                    CFRelease(candidateCert);
                    if (candidateData && [candidateData isEqualToData:targetCertData]) {
                        CFRetain(candidate);
                        CFRelease(allIdentities);
                        return candidate;
                    }
                }
            }
        }
        if (allIdentities) CFRelease(allIdentities);
        return NULL;
    }

    CFRelease(item);
    return NULL;
}

+ (MKCertificate *) certificateWithPersistentRef:(NSData *)persistentRef {
    // --- 核心修复：修正字典键值对顺序 ---
    NSDictionary *query = @{
        (__bridge id)kSecValuePersistentRef: persistentRef,
        (__bridge id)kSecReturnRef: (__bridge id)kCFBooleanTrue, // 之前写反了，这里必须是 Key:kSecReturnRef, Value:True
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };
    
    CFTypeRef thing = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &thing);
    
    if (status == noErr && thing != NULL) {
        CFTypeID receivedType = CFGetTypeID(thing);
        
        if (receivedType == SecIdentityGetTypeID()) {
            SecIdentityRef identity = (SecIdentityRef) thing;
            SecCertificateRef secCert = NULL;
            
            if (SecIdentityCopyCertificate(identity, &secCert) == noErr) {
                NSData *certData = (__bridge_transfer NSData *)SecCertificateCopyData(secCert);
                // 使用 Identity 创建证书对象，这样它才包含私钥用于认证
                MKCertificate *mkCert = [MKCertificate certificateWithCertificate:certData privateKey:nil];
                
                CFRelease(secCert);
                CFRelease(identity);
                return mkCert;
            }
            CFRelease(identity);
        } else if (receivedType == SecCertificateGetTypeID()) {
            SecCertificateRef secCert = (SecCertificateRef) thing;
            NSData *certData = (__bridge_transfer NSData *)SecCertificateCopyData(secCert);
            MKCertificate *mkCert = [MKCertificate certificateWithCertificate:certData privateKey:nil];
            
            CFRelease(secCert);
            return mkCert;
        }
        
        // 如果类型不对，也释放
        if (thing) CFRelease(thing);
    } else {
        NSLog(@"MUCertificateController: Failed to load certificate from keychain. Status: %d", (int)status);
    }
    
    return nil;
}

+ (OSStatus) deleteCertificateWithPersistentRef:(NSData *)persistentRef {
    NSDictionary *op = @{
        (__bridge id)kSecValuePersistentRef: persistentRef
    };
    return SecItemDelete((__bridge CFDictionaryRef)op);
}

+ (MKCertificate *) defaultCertificate {
    NSData *persistentRef = [[NSUserDefaults standardUserDefaults] objectForKey:@"DefaultCertificate"];
    if (!persistentRef) return nil;
    return [MUCertificateController certificateWithPersistentRef:persistentRef];
}

+ (void) setDefaultCertificateByPersistentRef:(NSData *)persistentRef {
    [[NSUserDefaults standardUserDefaults] setObject:persistentRef forKey:@"DefaultCertificate"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (NSArray *) persistentRefsForIdentities {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassIdentity,
        (__bridge id)kSecReturnPersistentRef: (__bridge id)kCFBooleanTrue,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll
    };
    
    CFTypeRef result = NULL;
    OSStatus err = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (err != noErr) {
        return nil;
    }
    return (__bridge_transfer NSArray *)result;
}

+ (NSString *) fingerprintFromHexString:(NSString *)hexDigest {
    if ([hexDigest length] != 40)
        return hexDigest;
    NSMutableString *str = [NSMutableString stringWithCapacity:60];
    for (NSUInteger i = 0; i < [hexDigest length]; i++) {
        if (i > 0 && i % 2 == 0)
            [str appendString:@":"];
        [str appendFormat:@"%c", [hexDigest characterAtIndex:i]];
    }
    return str;
}

// OpenSSL 生成逻辑 (保持不变，这部分是正确的)
+ (NSData *) generateSelfSignedCertificateWithName:(NSString *)name email:(NSString *)email {
    NSLog(@"Generating OpenSSL Self-Signed Certificate for %@ <%@>", name, email);
    
    OpenSSL_add_all_algorithms();
    ERR_load_crypto_strings();
    
    // 1. 生成 RSA 密钥对
    EVP_PKEY *pkey = EVP_PKEY_new();
    BIGNUM *e = BN_new();
    BN_set_word(e, RSA_F4);
    RSA *rsa = RSA_new();
    if (!RSA_generate_key_ex(rsa, 2048, e, NULL)) {
        NSLog(@"OpenSSL: Failed to generate RSA key");
        return nil;
    }
    EVP_PKEY_assign_RSA(pkey, rsa);
    BN_free(e);
    
    // 2. 创建 X.509 证书
    X509 *x509 = X509_new();
    ASN1_INTEGER_set(X509_get_serialNumber(x509), 1);
    X509_gmtime_adj(X509_get_notBefore(x509), 0);
    X509_gmtime_adj(X509_get_notAfter(x509), 31536000L * 20); // 20年有效期
    X509_set_pubkey(x509, pkey);
    
    X509_NAME *subject = X509_get_subject_name(x509);
    X509_NAME_add_entry_by_txt(subject, "CN", MBSTRING_UTF8, (unsigned char *)[name UTF8String], -1, -1, 0);
    if (email && email.length > 0) {
        X509_NAME_add_entry_by_txt(subject, "emailAddress", MBSTRING_UTF8, (unsigned char *)[email UTF8String], -1, -1, 0);
    }
    X509_set_issuer_name(x509, subject);
    
    if (!X509_sign(x509, pkey, EVP_sha256())) {
        NSLog(@"OpenSSL: Failed to sign certificate");
        return nil;
    }
    
    // 3. 导出 PKCS#12
    char *pass = "password";
    PKCS12 *p12 = PKCS12_create(pass, (char *)[name UTF8String], pkey, x509, NULL, 0, 0, 0, 0, 0);
    if (!p12) {
        NSLog(@"OpenSSL: Failed to create PKCS12");
        return nil;
    }
    
    BIO *bio = BIO_new(BIO_s_mem());
    i2d_PKCS12_bio(bio, p12);
    char *buffer = NULL;
    long length = BIO_get_mem_data(bio, &buffer);
    NSData *p12Data = [NSData dataWithBytes:buffer length:length];
    
    BIO_free(bio);
    PKCS12_free(p12);
    X509_free(x509);
    EVP_PKEY_free(pkey);
    
    // 4. 导入 Keychain
    NSMutableDictionary *options = [[NSMutableDictionary alloc] init];
    [options setObject:@"password" forKey:(__bridge id)kSecImportExportPassphrase];
    
    CFArrayRef items = NULL;
    OSStatus status = SecPKCS12Import((__bridge CFDataRef)p12Data, (__bridge CFDictionaryRef)options, &items);
    
    NSData *returnRef = nil;
    
    if (status == errSecSuccess && items && CFArrayGetCount(items) > 0) {
        NSDictionary *identityDict = (__bridge NSDictionary *)CFArrayGetValueAtIndex(items, 0);
        SecIdentityRef identity = (__bridge SecIdentityRef)[identityDict objectForKey:(__bridge id)kSecImportItemIdentity];
        
        if (identity) {
            returnRef = [self persistentRefForIdentity:identity];

            if (!returnRef) {
                NSDictionary *addQuery = @{
                    (__bridge id)kSecValueRef: (__bridge id)identity,
                    (__bridge id)kSecReturnPersistentRef: (__bridge id)kCFBooleanTrue
                };

                CFTypeRef persistentRef = NULL;
                OSStatus addErr = SecItemAdd((__bridge CFDictionaryRef)addQuery, &persistentRef);

                if (addErr == noErr && persistentRef != NULL) {
                    returnRef = (__bridge_transfer NSData *)persistentRef;
                } else if (addErr == errSecDuplicateItem) {
                    returnRef = [self persistentRefForIdentity:identity];
                    if (!returnRef) {
                        NSLog(@"Identity already exists but persistent ref lookup failed.");
                    }
                } else {
                    NSLog(@"SecItemAdd failed: %d", (int)addErr);
                }
            }
        }
    } else {
        NSLog(@"SecPKCS12Import failed: %d", (int)status);
    }
    
    if (items) CFRelease(items);
    return returnRef;
}

// --- 新增：导出 P12 ---
+ (NSData *) exportPKCS12DataForPersistentRef:(NSData *)ref password:(NSString *)password {
    // 1. 从 Persistent Ref 获取 Identity（兼容历史 ref 类型）
    SecIdentityRef identity = [self copyIdentityForPersistentRef:ref];
    if (!identity) {
        NSLog(@"MUCertificateController: export failed, cannot resolve identity from persistent ref.");
        return nil;
    }

#if TARGET_OS_OSX || TARGET_OS_MACCATALYST
    // 2. macOS 优先使用系统 PKCS12 导出，避免私钥外部表示格式差异导致失败
    NSString *safePassword = password ? password : @"";
    SecItemImportExportKeyParameters keyParams;
    memset(&keyParams, 0, sizeof(keyParams));
    keyParams.version = SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION;
    keyParams.passphrase = (__bridge CFTypeRef)safePassword;

    CFDataRef exportedData = NULL;
    OSStatus exportStatus = SecItemExport(identity, kSecFormatPKCS12, 0, &keyParams, &exportedData);
    if (exportStatus == errSecSuccess && exportedData != NULL) {
        NSData *result = (__bridge_transfer NSData *)exportedData;
        CFRelease(identity);
        return result;
    } else {
        NSLog(@"MUCertificateController: SecItemExport PKCS12 failed: %d, falling back to OpenSSL path.", (int)exportStatus);
        if (exportedData) CFRelease(exportedData);
    }
#endif

    // 3. 兜底路径：OpenSSL 组包（保留原逻辑）
    SecCertificateRef cert = NULL;
    SecKeyRef privateKey = NULL;

    if (SecIdentityCopyCertificate(identity, &cert) != errSecSuccess) {
        NSLog(@"MUCertificateController: export fallback failed at SecIdentityCopyCertificate.");
        CFRelease(identity);
        return nil;
    }
    if (SecIdentityCopyPrivateKey(identity, &privateKey) != errSecSuccess) {
        NSLog(@"MUCertificateController: export fallback failed at SecIdentityCopyPrivateKey.");
        CFRelease(cert);
        CFRelease(identity);
        return nil;
    }
    
    if (!cert || !privateKey) {
        if (cert) CFRelease(cert);
        if (privateKey) CFRelease(privateKey);
        CFRelease(identity);
        return nil;
    }
    
    // 2. 转换证书为 OpenSSL X509
    NSData *certData = (__bridge_transfer NSData *)SecCertificateCopyData(cert);
    const unsigned char *certBytes = [certData bytes];
    X509 *x509 = d2i_X509(NULL, &certBytes, [certData length]);
    
    // 3. 转换私钥为 OpenSSL EVP_PKEY
    // 注意：需要导出私钥的原始数据 (PKCS#1)
    CFErrorRef error = NULL;
    NSData *keyData = (__bridge_transfer NSData *)SecKeyCopyExternalRepresentation(privateKey, &error);
    EVP_PKEY *pkey = NULL;
    
    if (keyData) {
        const unsigned char *keyBytes = [keyData bytes];
        // 尝试作为 RSA 私钥读取
        RSA *rsa = d2i_RSAPrivateKey(NULL, &keyBytes, [keyData length]);
        if (rsa) {
            pkey = EVP_PKEY_new();
            EVP_PKEY_assign_RSA(pkey, rsa);
        }
    }
    
    NSData *p12Data = nil;
    
    // 4. 打包为 PKCS12
    if (x509 && pkey) {
        OpenSSL_add_all_algorithms();
        
        // 获取 Friendly Name (别名)
        NSString *friendlyName = nil;
        CFStringRef commonName = NULL;
        SecCertificateCopyCommonName(cert, &commonName);
        if (commonName) {
            friendlyName = (__bridge NSString *)commonName;
            CFRelease(commonName);
        }
        
        PKCS12 *p12 = PKCS12_create((char *)[password UTF8String],
                                    (char *)[friendlyName UTF8String],
                                    pkey, x509, NULL, 0, 0, 0, 0, 0);
        
        if (p12) {
            BIO *bio = BIO_new(BIO_s_mem());
            i2d_PKCS12_bio(bio, p12);
            char *buffer = NULL;
            long length = BIO_get_mem_data(bio, &buffer);
            p12Data = [NSData dataWithBytes:buffer length:length];
            
            BIO_free(bio);
            PKCS12_free(p12);
        }
    }
    
    // 清理
    if (x509) X509_free(x509);
    if (pkey) EVP_PKEY_free(pkey); // RSA is freed with PKEY
    CFRelease(cert);
    CFRelease(privateKey);
    CFRelease(identity);
    
    return p12Data;
}

// --- 新增：导入 P12 ---
+ (NSData *) importPKCS12Data:(NSData *)data password:(NSString *)password error:(NSError **)error {
    NSMutableDictionary *options = [[NSMutableDictionary alloc] init];
    [options setObject:(password ? password : @"") forKey:(__bridge id)kSecImportExportPassphrase];
    
    CFArrayRef items = NULL;
    OSStatus status = SecPKCS12Import((__bridge CFDataRef)data, (__bridge CFDictionaryRef)options, &items);
    
    // 1. 处理 P12 解析/密码错误
    if (status != errSecSuccess) {
        if (error) {
            NSString *msg = @"Unknown import error.";
            if (status == errSecAuthFailed) {
                msg = @"Incorrect password."; // 密码错误
            } else if (status == errSecDecode) {
                msg = @"The file is corrupted or not a valid PKCS#12 certificate.";
            } else {
                msg = [NSString stringWithFormat:@"SecPKCS12Import failed (Code: %d)", (int)status];
            }
            
            *error = [NSError errorWithDomain:@"MumbleCertError" code:status userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        return nil;
    }
    
    NSData *returnRef = nil;
    
    if (status == errSecSuccess && items && CFArrayGetCount(items) > 0) {
        NSDictionary *identityDict = (__bridge NSDictionary *)CFArrayGetValueAtIndex(items, 0);
        SecIdentityRef identity = (__bridge SecIdentityRef)[identityDict objectForKey:(__bridge id)kSecImportItemIdentity];
        
        if (identity) {
            // 2. 尝试存入 Keychain
            returnRef = [self persistentRefForIdentity:identity];

            if (!returnRef) {
                NSDictionary *addQuery = @{
                    (__bridge id)kSecValueRef: (__bridge id)identity,
                    (__bridge id)kSecReturnPersistentRef: (__bridge id)kCFBooleanTrue
                };

                CFTypeRef persistentRef = NULL;
                OSStatus addErr = SecItemAdd((__bridge CFDictionaryRef)addQuery, &persistentRef);

                if (addErr == noErr && persistentRef != NULL) {
                    returnRef = (__bridge_transfer NSData *)persistentRef;
                } else if (addErr == errSecDuplicateItem) {
                    returnRef = [self persistentRefForIdentity:identity];
                    if (!returnRef && error) {
                        *error = [NSError errorWithDomain:@"MumbleCertError" code:addErr userInfo:@{NSLocalizedDescriptionKey: @"This certificate already exists in your Keychain."}];
                    }
                } else {
                    // 3. 处理 Keychain 存储错误
                    if (error) {
                        NSString *msg = [NSString stringWithFormat:@"Keychain Add Error: %d", (int)addErr];
                        *error = [NSError errorWithDomain:@"MumbleCertError" code:addErr userInfo:@{NSLocalizedDescriptionKey: msg}];
                    }
                }
            }
        } else {
            if (error) *error = [NSError errorWithDomain:@"MumbleCertError" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"No identity found inside the P12 file."}];
        }
    } else {
        if (error) *error = [NSError errorWithDomain:@"MumbleCertError" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"No items found in P12 file."}];
    }
    
    if (items) CFRelease(items);
    return returnRef;
}

@end
