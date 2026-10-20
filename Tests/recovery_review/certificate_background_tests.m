#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <assert.h>

static NSMutableDictionary *fixtureAttributes;
static NSMutableArray *updates;
static OSStatus readStatus, writeStatus, keyStatus, certificateStatus;
static BOOL malformedAttributes;

static OSStatus FixtureCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    NSDictionary *match = (__bridge NSDictionary *)query;
    assert([match[(__bridge id)kSecReturnAttributes] boolValue]);
    assert(match[(__bridge id)kSecMatchLimit] == (__bridge id)kSecMatchLimitOne);
    if (readStatus != errSecSuccess) return readStatus;
    id value = malformedAttributes ? (id)@[] : fixtureAttributes[match[(__bridge id)kSecValueRef]];
    *result = CFBridgingRetain(value);
    return errSecSuccess;
}

static OSStatus FixtureUpdate(CFDictionaryRef query, CFDictionaryRef attributes) {
    NSDictionary *match = (__bridge NSDictionary *)query;
    NSDictionary *change = (__bridge NSDictionary *)attributes;
    assert(match.count == 2 && change.count == 1);
    assert(match[(__bridge id)kSecValueRef] && match[(__bridge id)kSecClass]);
    [updates addObject:@{@"match": match, @"change": change}];
    return writeStatus;
}

static OSStatus FixturePrivateKey(SecIdentityRef identity, SecKeyRef *key) {
    assert(identity);
    if (keyStatus == errSecSuccess) *key = (SecKeyRef)CFBridgingRetain(@"selected-key");
    return keyStatus;
}

static OSStatus FixtureCertificate(SecIdentityRef identity, SecCertificateRef *certificate) {
    assert(identity);
    if (certificateStatus == errSecSuccess) *certificate = (SecCertificateRef)CFBridgingRetain(@"selected-certificate");
    return certificateStatus;
}

#define SecItemCopyMatching FixtureCopyMatching
#define SecItemUpdate FixtureUpdate
#define SecIdentityCopyPrivateKey FixturePrivateKey
#define SecIdentityCopyCertificate FixtureCertificate
#import "MUCertificateBackgroundAccess.h"

static void reset(CFStringRef accessibility) {
    NSDictionary *attributes = @{(__bridge id)kSecAttrAccessible: (__bridge id)accessibility};
    fixtureAttributes = [@{@"selected-key": attributes, @"selected-certificate": attributes} mutableCopy];
    updates = [NSMutableArray array];
    readStatus = writeStatus = keyStatus = certificateStatus = errSecSuccess;
    malformedAttributes = NO;
}

static OSStatus prepare(void) {
    return MUPrepareClientIdentityForBackgroundUse((__bridge SecIdentityRef)@"selected-identity");
}

int main(void) {
    @autoreleasepool {
        reset(kSecAttrAccessibleWhenUnlocked);
        assert(prepare() == errSecSuccess && updates.count == 2);
        assert([updates[0][@"match"][(__bridge id)kSecClass] isEqual:(__bridge id)kSecClassKey]);
        assert([updates[1][@"match"][(__bridge id)kSecClass] isEqual:(__bridge id)kSecClassCertificate]);
        for (NSDictionary *update in updates)
            assert([update[@"change"][(__bridge id)kSecAttrAccessible] isEqual:(__bridge id)kSecAttrAccessibleAfterFirstUnlock]);

        reset(kSecAttrAccessibleWhenUnlockedThisDeviceOnly);
        assert(prepare() == errSecSuccess && updates.count == 2);
        for (NSDictionary *update in updates)
            assert([update[@"change"][(__bridge id)kSecAttrAccessible] isEqual:(__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]);

        for (id accessibility in @[(__bridge id)kSecAttrAccessibleAfterFirstUnlock,
                                   (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                   (__bridge id)kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly]) {
            reset((__bridge CFStringRef)accessibility);
            assert(prepare() == errSecSuccess && updates.count == 0);
        }
        reset(kSecAttrAccessibleWhenUnlocked);
        NSDictionary *restricted = @{(__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleWhenUnlocked,
                                      (__bridge id)kSecAttrAccessControl: @"explicit-user-presence"};
        fixtureAttributes[@"selected-key"] = restricted;
        fixtureAttributes[@"selected-certificate"] = restricted;
        assert(prepare() == errSecSuccess && updates.count == 0);

        reset(kSecAttrAccessibleWhenUnlocked);
        readStatus = errSecInteractionNotAllowed;
        assert(prepare() == errSecInteractionNotAllowed && updates.count == 0);
        reset(kSecAttrAccessibleWhenUnlocked);
        writeStatus = errSecAuthFailed;
        assert(prepare() == errSecAuthFailed);
        reset(kSecAttrAccessibleWhenUnlocked);
        keyStatus = errSecItemNotFound;
        assert(prepare() == errSecItemNotFound && updates.count == 0);
        reset(kSecAttrAccessibleWhenUnlocked);
        certificateStatus = errSecItemNotFound;
        assert(prepare() == errSecItemNotFound);
        reset(kSecAttrAccessibleWhenUnlocked);
        malformedAttributes = YES;
        assert(prepare() == errSecDecode && updates.count == 0);
        assert(MUBackgroundCertificateAccessibility(NULL) == NULL);
        puts("PASS background certificate access: key/cert migration, device binding, explicit restrictions and failures");
    }
    return 0;
}
