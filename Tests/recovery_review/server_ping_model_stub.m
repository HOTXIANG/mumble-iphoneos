#import "server_ping_model_stub.h"

@interface MUPingerCreationGate ()
@property(atomic, readwrite) BOOL entered;
@property(atomic, readwrite) BOOL completed;
@property(nonatomic, strong) dispatch_semaphore_t semaphore;
@end

@implementation MUPingerCreationGate
- (instancetype)init {
    if ((self = [super init])) _semaphore = dispatch_semaphore_create(0);
    return self;
}
- (void)releaseCreation { dispatch_semaphore_signal(self.semaphore); }
@end

static NSMutableArray<MUPingerCreationGate *> *queuedGates;
static NSMutableArray<MKServerPinger *> *createdPingers;

@interface MKServerPinger () {
    __weak id<MKServerPingerDelegate> _testDelegate;
}
@property(atomic, readwrite) NSUInteger startCount;
@property(atomic, readwrite) NSUInteger stopCount;
@property(atomic, readwrite) NSUInteger nonNilDelegateCount;
@property(atomic, readwrite) BOOL active;
@property(atomic, readwrite) BOOL startedInInitializer;
@end

@implementation MKServerPinger
- (id)initWithHostname:(NSString *)hostname port:(NSString *)port {
    return [self initWithHostname:hostname port:port startImmediately:YES];
}
- (id)initWithHostname:(NSString *)hostname port:(NSString *)port startImmediately:(BOOL)startImmediately {
    (void)hostname;
    (void)port;
    if ((self = [super init])) {
        MUPingerCreationGate *gate;
        @synchronized (MKServerPinger.class) {
            if (!createdPingers) createdPingers = [NSMutableArray array];
            [createdPingers addObject:self];
            gate = queuedGates.firstObject;
            if (gate) [queuedGates removeObjectAtIndex:0];
        }
        if (gate) {
            gate.entered = YES;
            dispatch_semaphore_wait(gate.semaphore, DISPATCH_TIME_FOREVER);
        }
        self.startedInInitializer = startImmediately;
        if (startImmediately) [self start];
        gate.completed = YES;
    }
    return self;
}
- (id<MKServerPingerDelegate>)delegate { return _testDelegate; }
- (void)setDelegate:(id<MKServerPingerDelegate>)delegate {
    _testDelegate = delegate;
    if (delegate) self.nonNilDelegateCount += 1;
}
- (void)start {
    self.startCount += 1;
    self.active = YES;
}
- (void)stop {
    // Match MKServerPinger.stop: stopping also detaches its weak delegate.
    _testDelegate = nil;
    self.stopCount += 1;
    self.active = NO;
}
@end

void MUTestPingerReset(void) {
    @synchronized (MKServerPinger.class) {
        NSCAssert(queuedGates.count == 0, @"A test left an unconsumed constructor gate");
        queuedGates = [NSMutableArray array];
        createdPingers = [NSMutableArray array];
    }
}
MUPingerCreationGate *MUTestPingerGateNextCreation(void) {
    MUPingerCreationGate *gate = [[MUPingerCreationGate alloc] init];
    @synchronized (MKServerPinger.class) {
        if (!queuedGates) queuedGates = [NSMutableArray array];
        [queuedGates addObject:gate];
    }
    return gate;
}
NSUInteger MUTestPingerCount(void) {
    @synchronized (MKServerPinger.class) { return createdPingers.count; }
}
MKServerPinger *MUTestPingerAtIndex(NSUInteger index) {
    @synchronized (MKServerPinger.class) { return createdPingers[index]; }
}
