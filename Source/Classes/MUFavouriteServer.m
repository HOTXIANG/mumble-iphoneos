// Copyright 2009-2010 The 'Mumble for iOS' Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import "MUFavouriteServer.h"
#import "MUDatabase.h"

@interface MUFavouriteServer () {
    NSInteger  _pkey;
    NSString   *_displayName;
    NSString   *_hostName;
    NSUInteger _port;
    NSString   *_userName;
    NSString   *_password;
}
@end

@implementation MUFavouriteServer

@synthesize primaryKey         = _pkey;
@synthesize displayName        = _displayName;
@synthesize hostName           = _hostName;
@synthesize port               = _port;
@synthesize userName           = _userName;
@synthesize password           = _password;
@synthesize certificateRef     = _certificateRef;

- (id) initWithDisplayName:(NSString *)displayName hostName:(NSString *)hostName port:(NSUInteger)port userName:(NSString *)userName password:(NSString *)passWord {
    self = [super init];
    if (self == nil)
        return nil;

    _pkey = -1;
    _displayName = [displayName copy];
    _hostName = [hostName copy];
    _port = port;
    _userName = [userName copy];
    _password = [passWord copy];

    return self;
}

- (id) init {
    return [self initWithDisplayName:nil hostName:nil port:0 userName:nil password:nil];
}

- (id) copyWithZone:(NSZone *)zone {
    MUFavouriteServer *copy = [[MUFavouriteServer alloc] init];
    [copy setDisplayName:[self displayName]];
    [copy setHostName:[self hostName]];
    [copy setPort:[self port]];
    [copy setUserName:[self userName]];
    [copy setPassword:[self password]];
    [copy setCertificateRef:[self certificateRef]]; // Copy ref
    if ([self hasPrimaryKey])
        [copy setPrimaryKey:[self primaryKey]];
    return copy;
}

- (BOOL) hasPrimaryKey {
    return _pkey != -1;
}

- (NSComparisonResult) compare:(MUFavouriteServer *)favServ {
    return [_displayName caseInsensitiveCompare:[favServ displayName]];
}

@end
