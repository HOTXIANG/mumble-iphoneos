// Real loopback UDP regression tests. No audio, external DNS, or remote servers.
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import "MKServerPinger.h"
#include <dispatch/dispatch.h>
#include <stdatomic.h>
#include <stdarg.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <fcntl.h>
#include <unistd.h>
#include <math.h>

static unsigned checks;
static unsigned destroyedPingers;
#define CHECK(value) do { ++checks; if (!(value)) { \
    fprintf(stderr, "%s:%d failed: %s\n", __FILE__, __LINE__, #value); exit(1); \
} } while (0)

// Standalone MumbleKit test binary has no Swift logger bridge.
void MumbleLogFormatted(int level, const char *category, const char *file,
                       const char *function, int line, NSString *format, ...) {
    (void)level; (void)category; (void)file; (void)function; (void)line;
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    fprintf(stderr, "%s\n", message.UTF8String);
    [message release];
}

static void pump(NSTimeInterval duration) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:duration];
    while ([until timeIntervalSinceNow] > 0) {
        @autoreleasepool {
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
    }
}

static id controller(void) {
    return [NSClassFromString(@"MKServerPingerController") performSelector:NSSelectorFromString(@"sharedController")];
}

static NSUInteger registrations(void) {
    NSUInteger count = 0;
    for (NSArray *subscribers in [[controller() valueForKey:@"pingers"] allValues]) count += subscribers.count;
    return count;
}

static BOOL hasSource(NSString *name) {
    Ivar variable = class_getInstanceVariable([controller() class], name.UTF8String);
    CHECK(variable != NULL);
    dispatch_source_t source = NULL;
    memcpy(&source, (const char *)(void *)controller() + ivar_getOffset(variable), sizeof(source));
    return source != NULL;
}

static void checkStopped(void) {
    CHECK(registrations() == 0);
    CHECK(!hasSource(@"_timer"));
    CHECK(!hasSource(@"_reader4"));
    CHECK(!hasSource(@"_reader6"));
    CHECK([[controller() valueForKey:@"sock4"] intValue] == -1);
    CHECK([[controller() valueForKey:@"sock6"] intValue] == -1);
}

@interface LoopbackServer : NSObject {
    int _socket;
    dispatch_source_t _reader;
}
@property(nonatomic, readonly) NSUInteger packets;
@property(nonatomic, readonly) uint16_t port;
@property(nonatomic) BOOL replyEnabled;
@property(nonatomic, readonly) NSMutableSet *sourcePorts;
@property(nonatomic, readonly) NSData *lastPacket;
@property(nonatomic, readonly) NSData *lastPeer;
- (void)sendReply:(NSData *)packet peer:(NSData *)peer;
- (void)close;
@end

@implementation LoopbackServer
- (id)init {
    if ((self = [super init])) {
        _socket = socket(AF_INET, SOCK_DGRAM, 0);
        CHECK(_socket >= 0);
        CHECK(fcntl(_socket, F_SETFL, O_NONBLOCK) == 0);
        struct sockaddr_in address = { 0 };
        address.sin_len = sizeof(address);
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        CHECK(bind(_socket, (struct sockaddr *)&address, sizeof(address)) == 0);
        socklen_t length = sizeof(address);
        CHECK(getsockname(_socket, (struct sockaddr *)&address, &length) == 0);
        _port = ntohs(address.sin_port);
        _sourcePorts = [[NSMutableSet alloc] init];
        _replyEnabled = YES;
        _reader = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)_socket, 0, dispatch_get_main_queue());
        CHECK(_reader != NULL);
        dispatch_source_set_event_handler(_reader, ^{
            for (;;) {
                UInt32 words[3];
                struct sockaddr_in peer = { 0 };
                socklen_t peerLength = sizeof(peer);
                ssize_t length = recvfrom(self->_socket, words, sizeof(words), 0, (struct sockaddr *)&peer, &peerLength);
                if (length < 0) break;
                CHECK(length == sizeof(words));
                CHECK(peer.sin_addr.s_addr == htonl(INADDR_LOOPBACK));
                ++self->_packets;
                [self->_sourcePorts addObject:@(ntohs(peer.sin_port))];
                [self->_lastPacket release];
                [self->_lastPeer release];
                self->_lastPacket = [[NSData alloc] initWithBytes:words length:sizeof(words)];
                self->_lastPeer = [[NSData alloc] initWithBytes:&peer length:peerLength];
                if (self->_replyEnabled) [self sendReply:self->_lastPacket peer:self->_lastPeer];
            }
        });
        int socket = _socket;
        dispatch_source_set_cancel_handler(_reader, ^{ close(socket); });
        dispatch_resume(_reader);
    }
    return self;
}
- (void)sendReply:(NSData *)packet peer:(NSData *)peer {
    CHECK(packet.length == 12);
    UInt32 response[6] = { 0 };
    memcpy(response, packet.bytes, packet.length);
    response[0] = htonl(0x010500);
    response[3] = htonl(2);
    response[4] = htonl(100);
    response[5] = htonl(72000);
    CHECK(sendto(_socket, response, sizeof(response), 0, peer.bytes, (socklen_t)peer.length) == sizeof(response));
}
- (void)close {
    if (_reader) { dispatch_source_cancel(_reader); dispatch_release(_reader); _reader = NULL; }
}
- (void)dealloc {
    [self close];
    [_sourcePorts release]; [_lastPacket release]; [_lastPeer release];
    [super dealloc];
}
@end

@interface TestPinger : MKServerPinger
@end
@implementation TestPinger
- (void)dealloc { ++destroyedPingers; [super dealloc]; }
@end

@interface ResultDelegate : NSObject<MKServerPingerDelegate>
@property(nonatomic) NSUInteger results;
@property(nonatomic, copy) void (^onReply)(void);
@end
@implementation ResultDelegate
- (void)serverPingerResult:(MKServerPingerResult *)result {
    CHECK([NSThread isMainThread]);
    CHECK(result->version == 0x010500 && result->cur_users == 2 && result->max_users == 100);
    CHECK(result->bandwidth == 72000 && isfinite(result->ping) && result->ping >= 0 && result->ping < 10);
    ++_results;
    if (_onReply) _onReply();
}
- (void)dealloc { [_onReply release]; [super dealloc]; }
@end

static TestPinger *newPinger(LoopbackServer *server, BOOL start) {
    return [[TestPinger alloc] initWithHostname:@"127.0.0.1" port:[NSString stringWithFormat:@"%u", server.port] startImmediately:start];
}

static void testDeferred(LoopbackServer *server) {
    NSUInteger packets = server.packets;
    unsigned destroyed = destroyedPingers;
    TestPinger *pinger = newPinger(server, NO);
    pump(1.15);
    CHECK(server.packets == packets);
    checkStopped();
    [pinger release];
    CHECK(destroyedPingers == destroyed + 1);
}

static void testSharedAddress(LoopbackServer *server) {
    NSMutableArray *pingers = [NSMutableArray array];
    NSMutableArray *delegates = [NSMutableArray array];
    [server.sourcePorts removeAllObjects];
    NSUInteger packets = server.packets;
    for (unsigned index = 0; index < 24; ++index) {
        TestPinger *pinger = newPinger(server, YES);
        ResultDelegate *delegate = [[ResultDelegate alloc] init];
        [pinger setDelegate:delegate];
        [pinger start]; [pinger start];
        [pingers addObject:pinger]; [delegates addObject:delegate];
        [pinger release]; [delegate release];
    }
    CHECK(registrations() == 24);
    CHECK(hasSource(@"_timer"));
    pump(1.35);
    CHECK(server.packets > packets && server.packets - packets <= 3);
    CHECK(server.sourcePorts.count == 1);
    NSUInteger expected = [(ResultDelegate *)delegates.firstObject results];
    CHECK(expected > 0);
    for (ResultDelegate *delegate in delegates) CHECK(delegate.results == expected);
    for (unsigned index = 0; index < 23; ++index) [(TestPinger *)pingers[index] stop];
    CHECK(registrations() == 1);
    NSUInteger previous = [(ResultDelegate *)delegates.lastObject results];
    pump(1.15);
    CHECK([(ResultDelegate *)delegates.lastObject results] > previous);
    for (unsigned index = 0; index < 23; ++index) CHECK([(ResultDelegate *)delegates[index] results] == expected);
    [(TestPinger *)pingers.lastObject stop];
    [(TestPinger *)pingers.lastObject stop];
    checkStopped();
    pump(.15); // Drain datagrams already handed to the kernel before stop.
    packets = server.packets;
    pump(1.2);
    CHECK(server.packets == packets);
}

static void testRestartAndBackgroundStop(LoopbackServer *server) {
    TestPinger *pinger = newPinger(server, NO);
    ResultDelegate *delegate = [[ResultDelegate alloc] init];
    for (unsigned cycle = 0; cycle < 6; ++cycle) {
        [pinger setDelegate:delegate];
        [pinger start]; [pinger start];
        CHECK(registrations() == 1);
        NSUInteger replies = delegate.results;
        pump(.15);
        CHECK(delegate.results > replies);
        [pinger stop]; [pinger stop];
        CHECK(pinger.delegate == nil);
        checkStopped();
        pump(.05);
    }
    [pinger setDelegate:delegate];
    [pinger start];
    atomic_bool *finished = calloc(1, sizeof(*finished));
    atomic_init(finished, false);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool { [pinger stop]; }
        atomic_store_explicit(finished, true, memory_order_release);
    });
    for (unsigned wait = 0; wait < 100 && !atomic_load_explicit(finished, memory_order_acquire); ++wait) pump(.02);
    CHECK(atomic_load_explicit(finished, memory_order_acquire));
    free(finished);
    checkStopped();
    NSUInteger replies = delegate.results;
    pump(1.2);
    CHECK(delegate.results == replies);
    [pinger release]; [delegate release];
}

static void testStopInsideCallback(LoopbackServer *server) {
    TestPinger *first = newPinger(server, NO);
    TestPinger *second = newPinger(server, NO);
    ResultDelegate *one = [[ResultDelegate alloc] init];
    ResultDelegate *two = [[ResultDelegate alloc] init];
    one.onReply = ^{ [first stop]; [second stop]; };
    [first setDelegate:one]; [second setDelegate:two];
    [first start]; [second start];
    pump(.25);
    CHECK(one.results == 1);
    CHECK(two.results == 0);
    checkStopped();
    one.onReply = nil;
    [first release]; [second release]; [one release]; [two release];
}

static void testWeakDelegate(LoopbackServer *server) {
    TestPinger *pinger = newPinger(server, NO);
    ResultDelegate *delegate = [[ResultDelegate alloc] init];
    [pinger setDelegate:delegate];
    [delegate release];
    CHECK(pinger.delegate == nil);
    [pinger start];
    pump(.15);
    [pinger stop]; [pinger release];
    checkStopped();
}

static void testDelayedReplyAfterRestart(LoopbackServer *server) {
    LoopbackServer *other = [[LoopbackServer alloc] init];
    TestPinger *keeper = newPinger(other, YES); // Keep the shared sockets open.
    TestPinger *pinger = newPinger(server, YES);
    ResultDelegate *delegate = [[ResultDelegate alloc] init];
    [pinger setDelegate:delegate];
    server.replyEnabled = NO;
    pump(.2);
    NSData *oldPacket = [server.lastPacket copy];
    NSData *peer = [server.lastPeer copy];
    CHECK(oldPacket.length == 12);
    [pinger stop];
    [pinger setDelegate:delegate];
    [pinger start];
    NSUInteger replies = delegate.results;
    [server sendReply:oldPacket peer:peer];
    pump(.2);
    CHECK(delegate.results == replies);
    server.replyEnabled = YES;
    pump(1.2);
    CHECK(delegate.results > replies);
    [pinger stop]; [keeper stop];
    [pinger release]; [keeper release]; [delegate release]; [oldPacket release]; [peer release];
    [other close]; [other release];
    pump(.05);
    checkStopped();
}

static void testIPv6Lifecycle(void) {
    int sock = socket(AF_INET6, SOCK_DGRAM, 0);
    CHECK(sock >= 0);
    CHECK(fcntl(sock, F_SETFL, O_NONBLOCK) == 0);
    struct sockaddr_in6 address = { 0 };
    address.sin6_len = sizeof(address);
    address.sin6_family = AF_INET6;
    address.sin6_addr = in6addr_loopback;
    CHECK(bind(sock, (struct sockaddr *)&address, sizeof(address)) == 0);
    socklen_t length = sizeof(address);
    CHECK(getsockname(sock, (struct sockaddr *)&address, &length) == 0);
    TestPinger *pinger = [[TestPinger alloc] initWithHostname:@"::1"
        port:[NSString stringWithFormat:@"%u", ntohs(address.sin6_port)] startImmediately:NO];
    ResultDelegate *delegate = [[ResultDelegate alloc] init];
    [pinger setDelegate:delegate];
    [pinger start];
    CHECK(registrations() == 1);
    pump(.2);
    UInt32 response[6] = { 0 };
    struct sockaddr_in6 peer = { 0 };
    length = sizeof(peer);
    CHECK(recvfrom(sock, response, sizeof(response), 0, (struct sockaddr *)&peer, &length) == 12);
    CHECK(IN6_IS_ADDR_LOOPBACK(&peer.sin6_addr));
    response[0] = htonl(0x010500);
    response[3] = htonl(2);
    response[4] = htonl(100);
    response[5] = htonl(72000);
    CHECK(sendto(sock, response, sizeof(response), 0, (struct sockaddr *)&peer, length) == sizeof(response));
    pump(.2);
    CHECK(delegate.results == 1);
    [pinger stop];
    checkStopped();
    pump(1.2);
    CHECK(recv(sock, response, sizeof(response), 0) == -1 && errno == EAGAIN);
    [pinger release]; [delegate release];
    close(sock);
}

int main(void) {
    @autoreleasepool {
        LoopbackServer *server = [[LoopbackServer alloc] init];
        testDeferred(server);
        testSharedAddress(server);
        testRestartAndBackgroundStop(server);
        testStopInsideCallback(server);
        testWeakDelegate(server);
        testDelayedReplyAfterRestart(server);
        [server close]; [server release];
        pump(.05);
        testIPv6Lifecycle();
    }
    printf("server pinger lifecycle: %u checks passed using loopback UDP only.\n", checks);
    return 0;
}
