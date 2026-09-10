#import <Foundation/Foundation.h>
#import "MKConnectionTransport.h"
#include "../../Source/Classes/MUConnectionRecoveryPolicy.h"
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>

#define CHECK(condition) do { if (!(condition)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #condition); abort(); } } while (0)

@interface FaultOutputStream : NSOutputStream {
@public
    NSMutableData *received;
    NSArray *writeSizes;
    NSUInteger writeIndex;
    BOOL writable;
}
@end
@implementation FaultOutputStream
- (id)init {
    if ((self = [super init])) { received = [[NSMutableData alloc] init]; writable = YES; }
    return self;
}
- (void)dealloc { [received release]; [writeSizes release]; [super dealloc]; }
- (BOOL)hasSpaceAvailable { return writable; }
- (NSInteger)write:(const uint8_t *)buffer maxLength:(NSUInteger)length {
    NSInteger requested = writeIndex < [writeSizes count] ? [[writeSizes objectAtIndex:writeIndex++] integerValue] : (NSInteger)length;
    if (requested <= 0) return requested;
    NSUInteger count = MIN((NSUInteger)requested, length);
    [received appendBytes:buffer length:count];
    return count;
}
@end

@interface FaultInputStream : NSInputStream {
@public
    NSData *source;
    NSUInteger available;
    NSUInteger cursor;
    NSUInteger chunkSize;
    NSInteger terminalRead;
}
@end
@implementation FaultInputStream
- (id)init {
    if ((self = [super init])) { chunkSize = NSUIntegerMax; terminalRead = NSIntegerMin; }
    return self;
}
- (void)dealloc { [source release]; [super dealloc]; }
- (BOOL)hasBytesAvailable { return cursor < available || terminalRead != NSIntegerMin; }
- (NSInteger)read:(uint8_t *)buffer maxLength:(NSUInteger)length {
    if (cursor == available) return terminalRead;
    NSUInteger count = MIN(MIN(length, available - cursor), chunkSize);
    memcpy(buffer, (const uint8_t *)[source bytes] + cursor, count);
    cursor += count;
    return count;
}
@end

static NSData *Payload(NSString *string) { return [string dataUsingEncoding:NSUTF8StringEncoding]; }

static void TestShortAndZeroWrites(void) {
    MKConnectionWriteQueue queue = {0};
    FaultOutputStream *output = [[[FaultOutputStream alloc] init] autorelease];
    output->writeSizes = [@[@1, @2, @0, @1, @0, @3, @2] retain];
    CHECK(MKConnectionEnqueueFrame(&queue, 0x1234, Payload(@"ABC")));
    CHECK(MKConnectionEnqueueFrame(&queue, 0x0001, [NSData data]));
    NSUInteger bytes; uint32_t frames;
    CHECK(MKConnectionFlushFrames(&queue, output, &bytes, &frames));
    CHECK(bytes == 3 && frames == 0 && queue.offset == 3 && queue.pendingBytes == 12);
    // Enqueue while the first header is incomplete: frames must not interleave.
    CHECK(MKConnectionEnqueueFrame(&queue, 0xabcd, Payload(@"Z")));
    CHECK(MKConnectionFlushFrames(&queue, output, &bytes, &frames));
    CHECK(bytes == 1 && frames == 0 && queue.offset == 4);
    CHECK(MKConnectionFlushFrames(&queue, output, &bytes, &frames));
    CHECK(frames == 3 && queue.pendingBytes == 0 && queue.offset == 0);
    const uint8_t expected[] = {0x12,0x34,0,0,0,3,'A','B','C', 0,1,0,0,0,0, 0xab,0xcd,0,0,0,1,'Z'};
    CHECK([output->received isEqualToData:[NSData dataWithBytes:expected length:sizeof(expected)]]);
    MKConnectionResetWriteQueue(&queue);
}

static void TestBackpressureAndWriteError(void) {
    MKConnectionWriteQueue queue = {0};
    FaultOutputStream *output = [[[FaultOutputStream alloc] init] autorelease];
    output->writable = NO;
    CHECK(MKConnectionEnqueueFrame(&queue, 3, Payload(@"ping")));
    NSUInteger bytes; uint32_t frames;
    CHECK(MKConnectionFlushFrames(&queue, output, &bytes, &frames));
    CHECK(bytes == 0 && frames == 0 && queue.pendingBytes == 10);
    output->writable = YES;
    output->writeSizes = [@[@2, @-1] retain];
    CHECK(!MKConnectionFlushFrames(&queue, output, &bytes, &frames));
    CHECK(bytes == 2 && queue.offset == 2 && queue.pendingBytes == 8);
    MKConnectionResetWriteQueue(&queue);
    CHECK(queue.frames == nil && queue.pendingBytes == 0 && queue.offset == 0);
    CHECK(MKConnectionEnqueueFrame(&queue, 1, Payload(@"new")));
    CHECK(MKConnectionFlushFrames(&queue, output, &bytes, &frames));
    CHECK(bytes == 9 && frames == 1); // no tail carried across reconnect
    MKConnectionResetWriteQueue(&queue);
}

static void TestQueueLimits(void) {
    MKConnectionWriteQueue queue = {0};
    NSData *maximum = [NSMutableData dataWithLength:MKConnectionMaximumFrameLength];
    CHECK(MKConnectionEnqueueFrame(&queue, 1, maximum));
    CHECK(!MKConnectionEnqueueFrame(&queue, 1, maximum)); // frame headers count toward capacity
    CHECK(MKConnectionEnqueueFrame(&queue, 2, [NSMutableData dataWithLength:MKConnectionMaximumFrameLength - 12]));
    CHECK(queue.pendingBytes == MKConnectionMaximumQueuedBytes);
    CHECK(!MKConnectionEnqueueFrame(&queue, 0, [NSData data]));
    MKConnectionResetWriteQueue(&queue);
    CHECK(!MKConnectionEnqueueFrame(&queue, 0, [NSMutableData dataWithLength:MKConnectionMaximumFrameLength + 1]));
}

static void TestFragmentationAtEveryBoundary(void) {
    const uint8_t wire[] = {0xab,0xcd,0,0,0,3,'o','n','e', 0,5,0,0,0,0, 0,1,0,0,0,3,'t','w','o'};
    for (NSUInteger chunk = 1; chunk <= sizeof(wire); ++chunk) {
        MKConnectionReadState state = {0};
        FaultInputStream *input = [[[FaultInputStream alloc] init] autorelease];
        input->source = [[NSData alloc] initWithBytes:wire length:sizeof(wire)];
        input->chunkSize = chunk;
        NSMutableArray *types = [NSMutableArray array], *payloads = [NSMutableArray array];
        for (NSUInteger available = 0; available <= sizeof(wire); ++available) {
            input->available = available;
            CHECK(MKConnectionReadFrames(&state, input, ^BOOL(uint16_t type, NSData *payload) {
                [types addObject:@(type)]; [payloads addObject:[[payload copy] autorelease]]; return YES;
            }) == MKConnectionReadDrained);
        }
        CHECK(([types isEqualToArray:@[@0xabcd, @5, @1]]));
        CHECK(([payloads isEqualToArray:@[Payload(@"one"), [NSData data], Payload(@"two")]]));
        CHECK(state.headerLength == 0 && state.payload == nil);
        MKConnectionResetReadState(&state);
    }
}

static void TestReadTerminationAndLimits(void) {
    const uint8_t wire[] = {0,1,0,0,0,3,'x','y','z'};
    for (NSUInteger end = 0; end < sizeof(wire); ++end) {
        MKConnectionReadState state = {0};
        FaultInputStream *input = [[[FaultInputStream alloc] init] autorelease];
        input->source = [[NSData alloc] initWithBytes:wire length:sizeof(wire)];
        input->available = end; input->terminalRead = 0;
        CHECK(MKConnectionReadFrames(&state, input, ^BOOL(uint16_t type, NSData *payload) {
            CHECK(NO); return NO;
        }) == MKConnectionReadEOF);
        MKConnectionResetReadState(&state);
        input->cursor = 0; input->terminalRead = -1;
        CHECK(MKConnectionReadFrames(&state, input, ^BOOL(uint16_t type, NSData *payload) {
            CHECK(NO); return NO;
        }) == MKConnectionReadError);
        MKConnectionResetReadState(&state);
    }
    const uint8_t oversized[] = {0,1,0,0x80,0,1};
    MKConnectionReadState state = {0};
    FaultInputStream *input = [[[FaultInputStream alloc] init] autorelease];
    input->source = [[NSData alloc] initWithBytes:oversized length:6]; input->available = 6;
    CHECK(MKConnectionReadFrames(&state, input, ^BOOL(uint16_t t, NSData *p) { CHECK(NO); return NO; }) == MKConnectionReadOversized);
    CHECK(state.payload == nil); // reject before allocation
    MKConnectionResetReadState(&state);
    uint8_t maximum[] = {0,1,0,0x80,0,0};
    [input->source release]; input->source = [[NSData alloc] initWithBytes:maximum length:6]; input->cursor = 0;
    CHECK(MKConnectionReadFrames(&state, input, ^BOOL(uint16_t t, NSData *p) { CHECK(NO); return NO; }) == MKConnectionReadDrained);
    CHECK(state.payloadLength == MKConnectionMaximumFrameLength && [state.payload length] == MKConnectionMaximumFrameLength);
    MKConnectionResetReadState(&state);
}

static void TestBurstFairnessAndCancellation(void) {
    MKConnectionReadState state = {0};
    FaultInputStream *input = [[[FaultInputStream alloc] init] autorelease];
    input->source = [[NSMutableData alloc] initWithLength:6 * 130]; input->available = [input->source length];
    __block NSUInteger delivered = 0;
    BOOL (^receive)(uint16_t, NSData *) = ^BOOL(uint16_t type, NSData *payload) { ++delivered; return YES; };
    CHECK(MKConnectionReadFrames(&state, input, receive) == MKConnectionReadContinue && delivered == 64);
    CHECK(MKConnectionReadFrames(&state, input, receive) == MKConnectionReadContinue && delivered == 128);
    CHECK(MKConnectionReadFrames(&state, input, receive) == MKConnectionReadDrained && delivered == 130);
    input->cursor = 0;
    CHECK(MKConnectionReadFrames(&state, input, ^BOOL(uint16_t type, NSData *payload) { ++delivered; return NO; }) == MKConnectionReadDrained);
    CHECK(delivered == 131 && input->cursor == 6);
    MKConnectionResetReadState(&state);
}

static void TestBidirectionalPingHealth(void) {
    MKConnectionPingState udp = {0}, tcp = {0};
    const uint64_t second = 1000000;
    MKConnectionRecordPing(&udp, 100, second);
    MKConnectionRecordPing(&tcp, 200, second);
    CHECK(!MKConnectionAcceptPingReply(&udp, 999, 2 * second, 8 * second)); // never sent
    CHECK(!MKConnectionAcceptPingReply(&udp, 200, 2 * second, 8 * second)); // TCP/tunnel is a different path
    CHECK(MKConnectionAcceptPingReply(&udp, 100, 2 * second, 8 * second));
    CHECK(!MKConnectionAcceptPingReply(&udp, 100, 3 * second, 8 * second)); // duplicate
    MKConnectionRecordPing(&udp, 101, 3 * second);
    CHECK(MKConnectionAcceptPingReply(&udp, 101, 4 * second, 8 * second));
    CHECK(MKConnectionAcceptPingReply(&tcp, 200, 4 * second, 30 * second));
    // Downlink data has no path to update ping state: uplink loss must expire.
    CHECK(!MKConnectionDeadlineExpired(11 * second, udp.lastReplyUsec, 8 * second));
    CHECK(MKConnectionDeadlineExpired(12 * second, udp.lastReplyUsec, 8 * second));
    CHECK(MKConnectionDeadlineExpired(34 * second, tcp.lastReplyUsec, 30 * second));
    MKConnectionRecordPing(&udp, 102, 5 * second);
    CHECK(!MKConnectionAcceptPingReply(&udp, 102, 13 * second, 8 * second)); // stale echo
    CHECK(udp.lastReplyUsec == 4 * second);
    MKConnectionRecordPing(&udp, 103, 14 * second);
    CHECK(MKConnectionAcceptPingReply(&udp, 103, 15 * second, 8 * second)); // recovery
    MKConnectionRecordPing(&udp, 104, 16 * second);
    MKConnectionRecordPing(&udp, 105, 17 * second);
    CHECK(MKConnectionAcceptPingReply(&udp, 105, 18 * second, 8 * second));
    CHECK(!MKConnectionAcceptPingReply(&udp, 104, 19 * second, 8 * second)); // reordered older echo cannot extend health
    memset(&udp, 0, sizeof(udp));
    CHECK(!MKConnectionAcceptPingReply(&udp, 105, 20 * second, 8 * second)); // prior socket/attempt
    CHECK(!MKConnectionDeadlineExpired(second, 0, second));
    CHECK(!MKConnectionDeadlineExpired(second, 2 * second, second));
    MKConnectionRecordPing(&udp, 0, second);
    CHECK(MKConnectionAcceptPingReply(&udp, 0, 2 * second, 8 * second)); // timestamp zero is valid
    for (uint64_t i = 1; i <= 17; ++i) MKConnectionRecordPing(&udp, i, 3 * second);
    CHECK(!MKConnectionAcceptPingReply(&udp, 1, 4 * second, 8 * second)); // bounded window eviction
    CHECK(MKConnectionAcceptPingReply(&udp, 17, 4 * second, 8 * second));
}

int main(void) {
    @autoreleasepool {
        uint32_t failures = 0;
        const double expectedDelays[] = { 5, 15, 30, 60, 120, 300, 300 };
        for (NSUInteger i = 0; i < 7; ++i) {
            // A successful join followed by failure after 3 seconds must not
            // reset backoff and create a server login/ban loop.
            failures = MURecoveryFailureCount(failures, 100, 103);
            CHECK(MURecoveryMinimumDelay(failures) == expectedDelays[i]);
        }
        CHECK(MURecoveryFailureCount(failures, 100, 159) == 6);
        CHECK(MURecoveryFailureCount(failures, 100, 160) == 1);
        CHECK(MURecoveryFailureCount(failures, 0, 200) == 6);
        CHECK(MURecoveryScheduledDelay(.25, 200, 105) == 95); // path restoration cannot bypass cooldown
        CHECK(MURecoveryScheduledDelay(.25, 200, 201) == .25);
        CHECK(MURecoveryScheduledDelay(30, 200, 190) == 30);
        TestShortAndZeroWrites();
        TestBackpressureAndWriteError();
        TestQueueLimits();
        TestFragmentationAtEveryBoundary();
        TestReadTerminationAndLimits();
        TestBurstFairnessAndCancellation();
        TestBidirectionalPingHealth();
        puts("PASS: native transport framing, backpressure, read termination, limits, fairness, and bidirectional ping health");
    }
    return 0;
}
