// Copyright 2009-2012 The 'Mumble for iOS' Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import "MUMessagesDatabase.h"
#import "MUTextMessage.h"
#import "MUDataURL.h"

#import <MumbleKit/MKTextMessage.h>

#import <FMDB/FMDatabase.h>
#import <dispatch/dispatch.h>

static void *kMUMessagesDatabaseQueueKey = &kMUMessagesDatabaseQueueKey;

@interface MUMessagesDatabase () {
    NSCache    *_msgCache;
    FMDatabase *_db;
    NSInteger  _count;
    dispatch_queue_t _databaseQueue;
}
- (void)performDatabaseSync:(dispatch_block_t)block;
@end

@implementation MUMessagesDatabase

- (id)init {
    if ((self = [super init])) {
        _databaseQueue = dispatch_queue_create("cn.hotxiang.mumble.messages-database", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_databaseQueue, kMUMessagesDatabaseQueueKey, (__bridge void *)self, NULL);

        NSFileManager *manager = [NSFileManager defaultManager];
        NSString *directory = NSTemporaryDirectory();
        NSString *dbPath = [directory stringByAppendingPathComponent:@"msg.db"];

        [self performDatabaseSync:^{
            [manager removeItemAtPath:dbPath error:nil];
            self->_db = [[FMDatabase alloc] initWithPath:dbPath];
            if (![self->_db open]) {
                MULogError(Database, @"MUMessagesDatabase: Failed to open.");
            }

            [self->_db executeUpdate:@"CREATE TABLE IF NOT EXISTS `msg` "
                                      @"(`id` INTEGER PRIMARY KEY AUTOINCREMENT,"
                                      @" `rendered` BLOB,"
                                      @" `plist` BLOB)"];
        }];

        _msgCache = [[NSCache alloc] init];
        [_msgCache setCountLimit:10];
    }
    return self;
}

- (void)dealloc {
    [self performDatabaseSync:^{
        [self->_db close];
        self->_db = nil;
    }];
}

- (void)performDatabaseSync:(dispatch_block_t)block {
    if (!block) {
        return;
    }
    if (dispatch_get_specific(kMUMessagesDatabaseQueueKey) == (__bridge void *)self) {
        block();
    } else {
        dispatch_sync(_databaseQueue, block);
    }
}

- (void)addMessage:(MKTextMessage *)msg withHeading:(NSString *)heading andSentBySelf:(BOOL)selfSent {
    NSError *err = nil;
    NSString *plainMsg = [msg plainTextString];
    plainMsg = [plainMsg stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray *imageDataArray = [[NSMutableArray alloc] initWithCapacity:[[msg embeddedImages] count]];
    for (NSString *dataUrl in [msg embeddedImages]) {
        NSData *imgData = [MUDataURL dataFromDataURL:dataUrl];
        if (imgData) {
            [imageDataArray addObject:imgData];
        }
    }

    NSDictionary *dict = [NSDictionary dictionaryWithObjectsAndKeys:
                          heading, @"heading",
                          plainMsg, @"msg",
                          [NSDate date], @"date",
                          [msg embeddedLinks], @"links",
                          imageDataArray, @"images",
                          [NSNumber numberWithBool:selfSent], @"selfsent",
                          nil];
    NSData *plist = [NSPropertyListSerialization dataWithPropertyList:dict format:NSPropertyListBinaryFormat_v1_0 options:0 error:&err];

    [self performDatabaseSync:^{
        [self->_db executeUpdate:@"INSERT INTO `msg` (`rendered`, `plist`) VALUES (?,?)", [NSNull null], plist ? plist : [NSNull null]];
        self->_count++;
    }];
}

- (void)clearMessageAtIndex:(NSInteger)row {
    [self performDatabaseSync:^{
        [self->_db executeUpdate:@"UPDATE `msg` SET `plist`=NULL, `rendered`=NULL WHERE `id`=?", [NSNumber numberWithInteger:row + 1]];
    }];
    [_msgCache removeObjectForKey:[NSNumber numberWithInteger:row + 1]];
}

- (MUTextMessage *)messageAtIndex:(NSInteger)row {
    MUTextMessage *cachedMessage = [_msgCache objectForKey:[NSNumber numberWithInteger:row + 1]];
    if (cachedMessage != nil) {
        return cachedMessage;
    }

    __block NSDictionary *dict = nil;
    [self performDatabaseSync:^{
        FMResultSet *result = [self->_db executeQuery:@"SELECT `plist` FROM `msg` WHERE `id` = ?", [NSNumber numberWithInteger:row + 1]];
        if ([result next]) {
            NSData *plistData = [result dataForColumnIndex:0];
            if (plistData) {
                dict = [NSPropertyListSerialization propertyListWithData:plistData options:0 format:nil error:nil];
            }
        }
        [result close];
    }];

    if (!dict) {
        return nil;
    }

    NSArray *imgDataArray = [dict objectForKey:@"images"];
    NSMutableArray *imagesArray = [[NSMutableArray alloc] initWithCapacity:[imgDataArray count]];
    for (NSData *data in imgDataArray) {
#if TARGET_OS_IOS
        [imagesArray addObject:[UIImage imageWithData:data]];
#else
        [imagesArray addObject:[[NSImage alloc] initWithData:data]];
#endif
    }

    MUTextMessage *txtMsg = [MUTextMessage textMessageWithHeading:[dict objectForKey:@"heading"]
                                                        andMessage:[dict objectForKey:@"msg"]
                                                  andEmbeddedLinks:[dict objectForKey:@"links"]
                                                 andEmbeddedImages:imagesArray
                                                  andTimestampDate:[dict objectForKey:@"date"]
                                                      isSentBySelf:[[dict objectForKey:@"selfsent"] boolValue]];
    [_msgCache setObject:txtMsg forKey:[NSNumber numberWithInteger:row + 1]];
    return txtMsg;
}

- (NSInteger)count {
    __block NSInteger count = 0;
    [self performDatabaseSync:^{
        count = self->_count;
    }];
    return count;
}

@end
