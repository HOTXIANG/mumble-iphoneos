#import <Foundation/Foundation.h>

FOUNDATION_EXPORT double FMDBVersionNumber;
FOUNDATION_EXPORT const unsigned char FMDBVersionString[];

#if __has_include(<fmdb/FMDatabase.h>)
#import <fmdb/FMDatabase.h>
#import <fmdb/FMResultSet.h>
#import <fmdb/FMDatabaseAdditions.h>
#import <fmdb/FMDatabaseQueue.h>
#import <fmdb/FMDatabasePool.h>
#elif __has_include(<FMDB/FMDatabase.h>)
#import <FMDB/FMDatabase.h>
#import <FMDB/FMResultSet.h>
#import <FMDB/FMDatabaseAdditions.h>
#import <FMDB/FMDatabaseQueue.h>
#import <FMDB/FMDatabasePool.h>
#else
#import "FMDatabase.h"
#import "FMResultSet.h"
#import "FMDatabaseAdditions.h"
#import "FMDatabaseQueue.h"
#import "FMDatabasePool.h"
#endif

#if __has_include(<fmdb/FMDatabase+SQLCipher.h>)
#import <fmdb/FMDatabase+SQLCipher.h>
#elif __has_include(<FMDB/FMDatabase+SQLCipher.h>)
#import <FMDB/FMDatabase+SQLCipher.h>
#elif __has_include("FMDatabase+SQLCipher.h")
#import "FMDatabase+SQLCipher.h"
#endif
