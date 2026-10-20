#import <Foundation/Foundation.h>
#import <Security/Security.h>

// Preserve backup/device binding and any explicit user-presence restrictions.
static inline CFStringRef MUBackgroundCertificateAccessibility(CFTypeRef accessibility) {
    if (!accessibility) return NULL;
    if (CFEqual(accessibility, kSecAttrAccessibleWhenUnlocked))
        return kSecAttrAccessibleAfterFirstUnlock;
    if (CFEqual(accessibility, kSecAttrAccessibleWhenUnlockedThisDeviceOnly))
        return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    return NULL;
}

static inline OSStatus MUPrepareCertificateItemForBackgroundUse(CFTypeRef item, CFStringRef itemClass) {
    NSDictionary *match = @{
        (__bridge id)kSecClass: (__bridge id)itemClass,
        (__bridge id)kSecValueRef: (__bridge id)item
    };
    NSMutableDictionary *query = [match mutableCopy];
    query[(__bridge id)kSecReturnAttributes] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess) {
        if (result) CFRelease(result);
        return status;
    }
    if (!result || CFGetTypeID(result) != CFDictionaryGetTypeID()) {
        if (result) CFRelease(result);
        return errSecDecode;
    }
    NSDictionary *attributes = CFBridgingRelease(result);
    if (attributes[(__bridge id)kSecAttrAccessControl]) return errSecSuccess;
    CFStringRef accessibility = MUBackgroundCertificateAccessibility(
        (__bridge CFTypeRef)attributes[(__bridge id)kSecAttrAccessible]);
    if (!accessibility) return errSecSuccess;
    NSDictionary *updates = @{(__bridge id)kSecAttrAccessible: (__bridge id)accessibility};
    return SecItemUpdate((__bridge CFDictionaryRef)match, (__bridge CFDictionaryRef)updates);
}

static inline OSStatus MUPrepareClientIdentityForBackgroundUse(SecIdentityRef identity) {
    SecKeyRef privateKey = NULL;
    OSStatus status = SecIdentityCopyPrivateKey(identity, &privateKey);
    if (status != errSecSuccess) return status;
    if (!privateKey) return errSecItemNotFound;
    OSStatus keyStatus = MUPrepareCertificateItemForBackgroundUse(privateKey, kSecClassKey);
    CFRelease(privateKey);
    SecCertificateRef certificate = NULL;
    status = SecIdentityCopyCertificate(identity, &certificate);
    if (status != errSecSuccess) return status;
    if (!certificate) return errSecItemNotFound;
    OSStatus certificateStatus = MUPrepareCertificateItemForBackgroundUse(certificate, kSecClassCertificate);
    CFRelease(certificate);
    return keyStatus != errSecSuccess ? keyStatus : certificateStatus;
}
