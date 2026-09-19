#import <Foundation/Foundation.h>

// Compile-time replacement for the transport boundary. No socket or DNS API is
// called: test-owned semaphores decide when a constructor returns to Swift.
typedef struct _MKServerPingerResult {
    UInt32 version;
    UInt32 cur_users;
    UInt32 max_users;
    UInt32 bandwidth;
    double ping;
} MKServerPingerResult;

@protocol MKServerPingerDelegate
- (void)serverPingerResult:(MKServerPingerResult *)result;
@end

@interface MUPingerCreationGate : NSObject
@property(atomic, readonly) BOOL entered;
@property(atomic, readonly) BOOL completed;
- (void)releaseCreation;
@end

@interface MKServerPinger : NSObject
- (id)initWithHostname:(NSString *)hostname port:(NSString *)port;
- (id)initWithHostname:(NSString *)hostname port:(NSString *)port startImmediately:(BOOL)startImmediately;
- (id<MKServerPingerDelegate>)delegate;
- (void)setDelegate:(id<MKServerPingerDelegate>)delegate;
- (void)start;
- (void)stop;
@property(atomic, readonly) NSUInteger startCount;
@property(atomic, readonly) NSUInteger stopCount;
@property(atomic, readonly) NSUInteger nonNilDelegateCount;
@property(atomic, readonly) BOOL active;
@property(atomic, readonly) BOOL startedInInitializer;
@end

FOUNDATION_EXPORT void MUTestPingerReset(void);
FOUNDATION_EXPORT MUPingerCreationGate *MUTestPingerGateNextCreation(void);
FOUNDATION_EXPORT NSUInteger MUTestPingerCount(void);
FOUNDATION_EXPORT MKServerPinger *MUTestPingerAtIndex(NSUInteger index);
