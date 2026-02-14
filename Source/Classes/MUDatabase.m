// Copyright 2009-2011 The 'Mumble for iOS' Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import "MUDatabase.h"
#import "MUFavouriteServer.h"

static FMDatabase *db = nil;

@interface MUDatabase ()
+ (NSString *) filePath;
+ (void) moveOldDatabases;
+ (id) nilToNull:(id)obj;
@end

@implementation MUDatabase

+ (NSString *) filePath {
    NSArray *libraryDirectories = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory,
                                                                      NSUserDomainMask,
                                                                      YES);
    NSString *library = [libraryDirectories objectAtIndex:0];
    [[NSFileManager defaultManager] createDirectoryAtPath:library withIntermediateDirectories:YES attributes:nil error:nil];
    return [library stringByAppendingPathComponent:@"mumble.sqlite"];
}

+ (void) moveOldDatabases {
    NSArray *documentDirectories = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                                       NSUserDomainMask,
                                                                       YES);
    NSString *docs = [documentDirectories objectAtIndex:0];
    
    NSError *err = nil;
    NSFileManager *manager = [NSFileManager defaultManager];
    
    // Hide the SQLite database from the iTunes document inspector.
    NSString *oldPath = [docs stringByAppendingPathComponent:@"mumble.sqlite"];
    NSString *newPath = [docs stringByAppendingPathComponent:@".mumble.sqlite"];
    if (![manager fileExistsAtPath:newPath] && [manager fileExistsAtPath:oldPath]) {
        if (![manager moveItemAtPath:oldPath toPath:newPath error:&err]) {
            NSLog(@"MUDatabase: unable to move file to new spot (mumble.sqlite -> .mumble.sqlite)");
        }
    }

    // Attempt to move an old database to the new location.
    NSString *correctPath = [MUDatabase filePath];
    if (![manager fileExistsAtPath:correctPath]) {
        oldPath = newPath;
        newPath = correctPath;
        if (![manager fileExistsAtPath:newPath] && [manager fileExistsAtPath:oldPath]) {
            if (![manager moveItemAtPath:oldPath toPath:newPath error:&err]) {
                NSLog(@"MUDatabase: Unable to move file to new spot (~/Documents -> ~/Library)");
            }
        }
    }
}

+ (id) nilToNull:(id)obj {
    return obj ? obj : [NSNull null];
}

// Initialize the database.
+ (void) initializeDatabase {
    NSLog(@"Initializing database with SQLite version: %@", [FMDatabase sqliteLibVersion]);

    // Attempt to move old databases if we find ones
    // in our old locations.
    [MUDatabase moveOldDatabases];
    
    NSString *dbPath = [MUDatabase filePath];
    db = [[FMDatabase alloc] initWithPath:dbPath];
    if (!db)
        return;

    if ([db open]) {
        NSLog(@"MUDatabase: Initialized database at %@", dbPath);
    } else {
        NSLog(@"MUDatabase: Could not open database at %@", dbPath);
        db = nil;
        return;
    }

    [db executeUpdate:@"CREATE TABLE IF NOT EXISTS `favourites` "
                      @"(`id` INTEGER PRIMARY KEY AUTOINCREMENT,"
                      @" `name` TEXT,"
                      @" `hostname` TEXT,"
                      @" `port` INTEGER DEFAULT 64738,"
                      @" `username` TEXT,"
                      @" `password` TEXT)"];
    
    BOOL columnExists = NO;
    FMResultSet *rs = [db executeQuery:@"PRAGMA table_info(favourites)"];
    while ([rs next]) {
        NSString *columnName = [rs stringForColumn:@"name"];
        if ([@"certificate_ref" isEqualToString:columnName]) {
            columnExists = YES;
            break;
        }
    }
    [rs close];
    
    if (!columnExists) {
        NSLog(@"MUDatabase: Upgrading table 'favourites' adding column 'certificate_ref'...");
        if (![db executeUpdate:@"ALTER TABLE `favourites` ADD COLUMN `certificate_ref` BLOB"]) {
            NSLog(@"MUDatabase: Failed to add column certificate_ref: %@", [db lastErrorMessage]);
        }
    }
    
    // 检查并添加 hidden 列（用于软删除有证书的 profile）
    BOOL hiddenColumnExists = NO;
    FMResultSet *rs2 = [db executeQuery:@"PRAGMA table_info(favourites)"];
    while ([rs2 next]) {
        NSString *columnName = [rs2 stringForColumn:@"name"];
        if ([@"hidden" isEqualToString:columnName]) {
            hiddenColumnExists = YES;
            break;
        }
    }
    [rs2 close];
    
    if (!hiddenColumnExists) {
        NSLog(@"MUDatabase: Upgrading table 'favourites' adding column 'hidden'...");
        if (![db executeUpdate:@"ALTER TABLE `favourites` ADD COLUMN `hidden` INTEGER DEFAULT 0"]) {
            NSLog(@"MUDatabase: Failed to add column hidden: %@", [db lastErrorMessage]);
        }
    }

    [db executeUpdate:@"CREATE TABLE IF NOT EXISTS `cert` "
                      @"(`id` INTEGER PRIMARY KEY AUTOINCREMENT,"
                      @" `hostname` TEXT,"
                      @" `port` INTEGER,"
                      @" `digest` TEXT)"];
    [db executeUpdate:@"CREATE UNIQUE INDEX IF NOT EXISTS `cert_host_port`"
                      @" on `cert`(`hostname`,`port`)"];
    [db executeUpdate:@"CREATE TABLE IF NOT EXISTS `usernames` "
                      @"(`id` INTEGER PRIMARY KEY AUTOINCREMENT,"
                      @" `hostname` TEXT,"
                      @" `port` INTEGER,"
                      @" `username` TEXT)"];
    [db executeUpdate:@"CREATE UNIQUE INDEX IF NOT EXISTS `usernames_host_port`"
                      @" on `usernames`(`hostname`,`port`)"];
    [db executeUpdate:@"CREATE TABLE IF NOT EXISTS `tokens` "
                      @"(`id` INTEGER PRIMARY KEY AUTOINCREMENT,"
                      @" `hostname` TEXT,"
                      @" `port` INTEGER,"
                      @" `tokens` BLOB)"];
    [db executeUpdate:@"CREATE UNIQUE INDEX IF NOT EXISTS `tokens_host_port`"
                      @" on `tokens`(`hostname`,`port`)"];
    [db executeUpdate:@"VACUUM"];

    if ([db hadError]) {
        NSLog(@"MUDatabase: Error: %@ (Code: %i)", [db lastErrorMessage], [db lastErrorCode]);
    }
}

// Tear down the database
+ (void) teardown {
    [db close];
    db = nil;
}

// Store a single favourite
+ (void) storeFavourite:(MUFavouriteServer *)favServ {
    if (!db) return;

    if ([favServ hasPrimaryKey]) {
        [db executeUpdate:@"UPDATE `favourites` SET `name`=?, `hostname`=?, `port`=?, `username`=?, `password`=?, `certificate_ref`=?, `hidden`=? WHERE `id`=?",
            [self nilToNull:[favServ displayName]],
            [self nilToNull:[favServ hostName]],
            [NSNumber numberWithUnsignedInteger:[favServ port]],
            [self nilToNull:[favServ userName]],
            [self nilToNull:[favServ password]],
            [self nilToNull:[favServ certificateRef]],
            [NSNumber numberWithBool:[favServ isHidden]],
            [NSNumber numberWithInteger:[favServ primaryKey]]];
    } else {
        [db executeUpdate:@"INSERT INTO `favourites` (`name`, `hostname`, `port`, `username`, `password`, `certificate_ref`, `hidden`) VALUES (?, ?, ?, ?, ?, ?, ?)",
            [self nilToNull:[favServ displayName]],
            [self nilToNull:[favServ hostName]],
            [NSNumber numberWithUnsignedInteger:[favServ port]],
            [self nilToNull:[favServ userName]],
            [self nilToNull:[favServ password]],
            [self nilToNull:[favServ certificateRef]],
            [NSNumber numberWithBool:[favServ isHidden]]];

        FMResultSet *res = [db executeQuery:@"SELECT last_insert_rowid()"];
        if ([res next]) {
            [favServ setPrimaryKey:[res intForColumnIndex:0]];
        }
        [res close];
    }
}

// Delete a particular favourite
+ (void) deleteFavourite:(MUFavouriteServer *)favServ {
    NSAssert([favServ hasPrimaryKey], @"Cannot delete a FavouriteServer not originated from the database.");
    [db executeUpdate:@"DELETE FROM `favourites` WHERE `id`=?", [NSNumber numberWithInteger:[favServ primaryKey]]];
}

// Save favourites
+ (void) storeFavourites:(NSArray *)favourites {
    [db beginTransaction];
    for (MUFavouriteServer *favServ in favourites) {
        [MUDatabase storeFavourite:favServ];
    }
    [db commit];
}

// Fetch all favourites (包括 hidden，用于连接时匹配证书)
+ (NSMutableArray *) fetchAllFavourites {
    NSMutableArray *favs = [[NSMutableArray alloc] init];
    if (!db) return favs;
    
    FMResultSet *res = [db executeQuery:@"SELECT `id`, `name`, `hostname`, `port`, `username`, `password`, `certificate_ref`, `hidden` FROM `favourites`"];
    while ([res next]) {
        MUFavouriteServer *fs = [[MUFavouriteServer alloc] init];
        [fs setPrimaryKey:[res intForColumnIndex:0]];
        [fs setDisplayName:[res stringForColumnIndex:1]];
        [fs setHostName:[res stringForColumnIndex:2]];
        [fs setPort:[res intForColumnIndex:3]];
        [fs setUserName:[res stringForColumnIndex:4]];
        [fs setPassword:[res stringForColumnIndex:5]];
        [fs setCertificateRef:[res dataForColumnIndex:6]];
        [fs setIsHidden:[res boolForColumnIndex:7]];
        [favs addObject:fs];
    }
    [res close];
    return favs;
}

// Fetch only visible favourites (不包括 hidden，用于 UI 显示)
+ (NSMutableArray *) fetchVisibleFavourites {
    NSMutableArray *favs = [[NSMutableArray alloc] init];
    if (!db) return favs;
    
    FMResultSet *res = [db executeQuery:@"SELECT `id`, `name`, `hostname`, `port`, `username`, `password`, `certificate_ref`, `hidden` FROM `favourites` WHERE `hidden` = 0 OR `hidden` IS NULL"];
    while ([res next]) {
        MUFavouriteServer *fs = [[MUFavouriteServer alloc] init];
        [fs setPrimaryKey:[res intForColumnIndex:0]];
        [fs setDisplayName:[res stringForColumnIndex:1]];
        [fs setHostName:[res stringForColumnIndex:2]];
        [fs setPort:[res intForColumnIndex:3]];
        [fs setUserName:[res stringForColumnIndex:4]];
        [fs setPassword:[res stringForColumnIndex:5]];
        [fs setCertificateRef:[res dataForColumnIndex:6]];
        [fs setIsHidden:NO];
        [favs addObject:fs];
    }
    [res close];
    return favs;
}

// 删除所有引用了指定证书 persistent ref 的 hidden profiles
+ (void) deleteHiddenFavouritesWithCertificateRef:(NSData *)certRef {
    if (!db || !certRef) return;
    [db executeUpdate:@"DELETE FROM `favourites` WHERE `hidden` = 1 AND `certificate_ref` = ?", certRef];
}

#pragma mark -
#pragma mark Certificate verification

+ (void) storeDigest:(NSString *)hash forServerWithHostname:(NSString *)hostname port:(NSInteger)port {
    [db executeUpdate:@"REPLACE INTO `cert` (`hostname`,`port`,`digest`) VALUES (?,?,?)",
           hostname, [NSNumber numberWithInteger:port], hash];

}

+ (NSString *) digestForServerWithHostname:(NSString *)hostname port:(NSInteger)port {
    FMResultSet *result = [db executeQuery:@"SELECT `digest` FROM `cert` WHERE `hostname` = ? AND `port` = ?",
                                 hostname, [NSNumber numberWithInteger:port]];
    if ([result next]) {
        return [result stringForColumnIndex:0];
    }
    return nil;
}

#pragma mark -
#pragma mark Username rememberer

+ (void) storeUsername:(NSString *)username forServerWithHostname:(NSString *)hostname port:(NSInteger)port {
    [db executeUpdate:@"REPLACE INTO `usernames` (`hostname`,`port`,`username`) VALUES (?,?,?)",
        hostname, [NSNumber numberWithInteger:port], username];
}

+ (NSString *) usernameForServerWithHostname:(NSString *)hostname port:(NSInteger)port {
    FMResultSet *result = [db executeQuery:@"SELECT `username` FROM `usernames` WHERE `hostname` = ? AND `port` = ?",
                           hostname, [NSNumber numberWithInteger:port]];
    if ([result next]) {
        return [result stringForColumnIndex:0];
    }
    return nil;
}

#pragma mark -
#pragma mark Access tokens

+ (void) storeAccessTokens:(NSArray *)tokens forServerWithHostname:(NSString *)hostname port:(NSInteger)port {
    NSData *tokensJSON = nil;
    if (tokens != nil) {
        NSError *err = nil;
        tokensJSON = [NSJSONSerialization dataWithJSONObject:tokens options:0 error:&err];
        if (err != nil) {
            NSLog(@"MUDatabase#storeAccessTokens:forServerWithHostname:port: %@", err);
            return;
        }
    }
    [db executeUpdate:@"REPLACE INTO `tokens` (`hostname`,`port`,`tokens`) VALUES (?,?,?)",
        hostname, [NSNumber numberWithInteger:port], tokensJSON];
}

+ (NSArray *) accessTokensForServerWithHostname:(NSString *)hostname port:(NSInteger)port {
    FMResultSet *result = [db executeQuery:@"SELECT `tokens` FROM `tokens` WHERE `hostname` = ? AND `port` = ?",
                           hostname, [NSNumber numberWithInteger:port]];
    if ([result next]) {
        NSError *err = nil;
        NSData *tokensJSON = [result dataForColumnIndex:0];
        NSArray *tokens = [NSJSONSerialization JSONObjectWithData:tokensJSON options:0 error:&err];
        if (err != nil) {
            NSLog(@"MUDatabase#accessTokensForServerWithHostname:port: %@", err);
            return nil;
        }
        return tokens;
    }
    return nil;
}

@end
