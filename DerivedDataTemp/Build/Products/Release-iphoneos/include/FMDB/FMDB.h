#ifndef FMDB_FMDB_H
#define FMDB_FMDB_H

#import <Foundation/Foundation.h>

FOUNDATION_EXPORT double FMDBVersionNumber;
FOUNDATION_EXPORT const unsigned char FMDBVersionString[];

#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wquoted-include-in-framework-header"
#endif

#import "FMDatabase.h"
#import "FMResultSet.h"
#import "FMDatabaseAdditions.h"
#import "FMDatabaseQueue.h"
#import "FMDatabasePool.h"

#if __has_include("FMDatabase+SQLCipher.h")
#import "FMDatabase+SQLCipher.h"
#endif

#if defined(__clang__)
#pragma clang diagnostic pop
#endif

#endif /* FMDB_FMDB_H */
