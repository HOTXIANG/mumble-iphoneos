// Test-only route controller. This tool never opens an audio stream or microphone.
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

static const AudioObjectPropertySelector selectors[] = {
    kAudioHardwarePropertyDefaultInputDevice,
    kAudioHardwarePropertyDefaultOutputDevice,
    kAudioHardwarePropertyDefaultSystemOutputDevice,
};
static NSString *const keys[] = { @"input", @"output", @"systemOutput" };

static void fail(NSString *message) {
    fprintf(stderr, "mac_audio_route: %s\n", message.UTF8String);
    exit(EXIT_FAILURE);
}

static AudioObjectPropertyAddress address(AudioObjectPropertySelector selector,
                                          AudioObjectPropertyScope scope) {
    return (AudioObjectPropertyAddress) { selector, scope, kAudioObjectPropertyElementMain };
}

static AudioDeviceID defaultDevice(unsigned index) {
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress property = address(selectors[index], kAudioObjectPropertyScopeGlobal);
    OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &property, 0, NULL, &size, &device);
    if (status != noErr) fail([NSString stringWithFormat:@"Cannot read default %@ (%d).", keys[index], (int)status]);
    return device;
}

static NSString *deviceString(AudioDeviceID device, AudioObjectPropertySelector selector) {
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    AudioObjectPropertyAddress property = address(selector, kAudioObjectPropertyScopeGlobal);
    OSStatus status = AudioObjectGetPropertyData(device, &property, 0, NULL, &size, &value);
    if (status != noErr || !value) {
        fail([NSString stringWithFormat:@"Cannot read device %u string property %u (%d).", device, selector, (int)status]);
    }
    return CFBridgingRelease(value);
}

static UInt32 channelCount(AudioDeviceID device, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress property = address(kAudioDevicePropertyStreamConfiguration, scope);
    UInt32 size = 0;
    if (!AudioObjectHasProperty(device, &property)) return 0;
    OSStatus status = AudioObjectGetPropertyDataSize(device, &property, 0, NULL, &size);
    if (status != noErr) fail([NSString stringWithFormat:@"Cannot read device %u stream size (%d).", device, (int)status]);
    if (size == 0) return 0;
    if (size < offsetof(AudioBufferList, mBuffers) || size > 65536) fail(@"Invalid audio stream configuration size.");
    AudioBufferList *buffers = calloc(1, size);
    if (!buffers) fail(@"Cannot allocate stream configuration.");
    UInt32 capacity = size;
    status = AudioObjectGetPropertyData(device, &property, 0, NULL, &size, buffers);
    if (status != noErr || size > capacity || size < offsetof(AudioBufferList, mBuffers) ||
        buffers->mNumberBuffers > (size - offsetof(AudioBufferList, mBuffers)) / sizeof(AudioBuffer)) {
        free(buffers);
        fail([NSString stringWithFormat:@"Cannot read valid stream configuration for device %u (%d).", device, (int)status]);
    }
    uint64_t channels = 0;
    for (UInt32 index = 0; index < buffers->mNumberBuffers; ++index) channels += buffers->mBuffers[index].mNumberChannels;
    free(buffers);
    if (channels > UINT32_MAX) fail(@"Invalid audio channel count.");
    return (UInt32)channels;
}

static NSString *transportName(UInt32 transport) {
    switch (transport) {
        case kAudioDeviceTransportTypeBuiltIn: return @"builtIn";
        case kAudioDeviceTransportTypeUSB: return @"usb";
        case kAudioDeviceTransportTypeBluetooth: return @"bluetooth";
        case kAudioDeviceTransportTypeBluetoothLE: return @"bluetoothLE";
        case kAudioDeviceTransportTypeAggregate: return @"aggregate";
        case kAudioDeviceTransportTypeAutoAggregate: return @"autoAggregate";
        case kAudioDeviceTransportTypeVirtual: return @"virtual";
        default: return @"other";
    }
}

static NSArray<NSDictionary *> *deviceList(void) {
    AudioObjectPropertyAddress property = address(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal);
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &property, 0, NULL, &size);
    if (status != noErr || size == 0 || size % sizeof(AudioDeviceID)) fail(@"Cannot enumerate audio devices.");
    AudioDeviceID *devices = calloc(1, size);
    if (!devices) fail(@"Cannot allocate audio device list.");
    UInt32 capacity = size;
    status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &property, 0, NULL, &size, devices);
    if (status != noErr || size > capacity || size % sizeof(AudioDeviceID)) {
        free(devices);
        fail(@"Audio devices changed during enumeration; retry the command.");
    }
    NSMutableArray *result = [NSMutableArray array];
    for (UInt32 index = 0; index < size / sizeof(AudioDeviceID); ++index) {
        AudioDeviceID device = devices[index];
        UInt32 transport = 0;
        UInt32 transportSize = sizeof(transport);
        AudioObjectPropertyAddress transportProperty = address(kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal);
        status = AudioObjectGetPropertyData(device, &transportProperty, 0, NULL, &transportSize, &transport);
        if (status != noErr) { free(devices); fail(@"Cannot read audio device transport."); }
        [result addObject:@{
            @"id": @(device), @"uid": deviceString(device, kAudioDevicePropertyDeviceUID),
            @"name": deviceString(device, kAudioObjectPropertyName),
            @"transport": transportName(transport), @"transportCode": @(transport),
            @"inputChannels": @(channelCount(device, kAudioDevicePropertyScopeInput)),
            @"outputChannels": @(channelCount(device, kAudioDevicePropertyScopeOutput))
        }];
    }
    free(devices);
    return result;
}

static NSDictionary *deviceWithID(NSArray<NSDictionary *> *devices, AudioDeviceID identifier) {
    for (NSDictionary *device in devices) if ([device[@"id"] unsignedIntValue] == identifier) return device;
    return nil;
}

static NSDictionary *snapshot(void) {
    NSArray<NSDictionary *> *devices = deviceList();
    NSMutableDictionary *defaults = [NSMutableDictionary dictionary];
    for (unsigned index = 0; index < 3; ++index) {
        AudioDeviceID identifier = defaultDevice(index);
        NSDictionary *device = deviceWithID(devices, identifier);
        if (identifier != kAudioObjectUnknown && !device) fail(@"Default audio device changed during enumeration; retry the command.");
        defaults[keys[index]] = device ?: (id)[NSNull null];
    }
    return @{ @"schemaVersion": @1, @"devices": devices, @"defaults": defaults };
}

static NSData *jsonData(id object) {
    NSError *error;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
    if (!data) fail(error.localizedDescription);
    return data;
}

static void printJSON(id object) {
    NSData *data = jsonData(object);
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
}

static void saveSnapshot(NSString *path) {
    NSMutableDictionary *state = [snapshot() mutableCopy];
    state[@"savedAt"] = [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]];
    for (unsigned index = 0; index < 3; ++index) {
        NSString *key = keys[index];
        if (state[@"defaults"][key] == [NSNull null]) fail([NSString stringWithFormat:@"Cannot save an unset default %@ for restoration.", key]);
    }
    NSData *data = jsonData(state);
    // Never overwrite the only record of the original route on a retry.
    int descriptor = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (descriptor < 0) fail([NSString stringWithFormat:@"Cannot create %@: %s", path, strerror(errno)]);
    NSUInteger written = 0;
    while (written < data.length) {
        ssize_t result = write(descriptor, (const char *)data.bytes + written, data.length - written);
        if (result < 0 && errno == EINTR) continue;
        if (result <= 0) {
            close(descriptor);
            unlink(path.fileSystemRepresentation);
            fail(@"Cannot write route restoration state.");
        }
        written += (NSUInteger)result;
    }
    if (fsync(descriptor) != 0) { close(descriptor); fail(@"Cannot flush route restoration state."); }
    if (close(descriptor) != 0) fail(@"Cannot close route restoration state.");
    printJSON(@{ @"saved": path, @"defaults": state[@"defaults"] });
}

static BOOL setDefault(unsigned index, AudioDeviceID identifier, NSString **error) {
    AudioObjectPropertyAddress property = address(selectors[index], kAudioObjectPropertyScopeGlobal);
    OSStatus status = AudioObjectSetPropertyData(kAudioObjectSystemObject, &property, 0, NULL, sizeof(identifier), &identifier);
    if (status != noErr) {
        *error = [NSString stringWithFormat:@"Cannot set default %@ to device %u (%d).", keys[index], identifier, (int)status];
        return NO;
    }
    for (unsigned attempt = 0; attempt < 50; ++attempt) {
        AudioDeviceID actual = kAudioObjectUnknown;
        UInt32 size = sizeof(actual);
        status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &property, 0, NULL, &size, &actual);
        if (status == noErr && actual == identifier) return YES;
        usleep(20000);
    }
    *error = [NSString stringWithFormat:@"Default %@ did not settle on device %u.", keys[index], identifier];
    return NO;
}

static void applyDefaults(AudioDeviceID targets[3]) {
    AudioDeviceID originals[3];
    for (unsigned index = 0; index < 3; ++index) {
        originals[index] = defaultDevice(index);
        if (originals[index] == targets[index]) continue;
        AudioObjectPropertyAddress property = address(selectors[index], kAudioObjectPropertyScopeGlobal);
        Boolean settable = false;
        OSStatus status = AudioObjectIsPropertySettable(kAudioObjectSystemObject, &property, &settable);
        if (status != noErr || !settable) fail([NSString stringWithFormat:@"Default %@ is not settable (%d).", keys[index], (int)status]);
        if (originals[index] == kAudioObjectUnknown) fail(@"Cannot safely restore an unset original device if a switch fails.");
    }
    for (unsigned index = 0; index < 3; ++index) {
        if (originals[index] == targets[index]) continue;
        NSString *error = nil;
        if (setDefault(index, targets[index], &error)) continue;
        // Roll back all attempted properties, including one which timed out.
        for (int rollback = (int)index; rollback >= 0; --rollback) {
            if (originals[rollback] == targets[rollback]) continue;
            NSString *rollbackError = nil;
            if (!setDefault((unsigned)rollback, originals[rollback], &rollbackError)) {
                fprintf(stderr, "Rollback failed: %s\n", rollbackError.UTF8String);
            }
        }
        fail(error);
    }
    printJSON(snapshot());
}

static void selectBuiltin(void) {
    NSArray<NSDictionary *> *devices = deviceList();
    AudioDeviceID targets[3] = { 0, 0, defaultDevice(2) };
    for (unsigned index = 0; index < 2; ++index) {
        NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
        NSString *channels = index == 0 ? @"inputChannels" : @"outputChannels";
        for (NSDictionary *device in devices) {
            if ([device[@"transportCode"] unsignedIntValue] == kAudioDeviceTransportTypeBuiltIn &&
                [device[channels] unsignedIntValue] > 0) [candidates addObject:device];
        }
        if (candidates.count != 1) fail([NSString stringWithFormat:@"Expected exactly one built-in %@ device, found %lu. No devices changed.", keys[index], (unsigned long)candidates.count]);
        targets[index] = [candidates.firstObject[@"id"] unsignedIntValue];
    }
    // The app uses default output, not the system alert output. Preserve alerts.
    applyDefaults(targets);
}

static void restoreSnapshot(NSString *path) {
    NSError *error;
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:&error];
    if (!data) fail(error.localizedDescription);
    id state = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![state isKindOfClass:[NSDictionary class]] || ![state[@"schemaVersion"] isEqual:@1] ||
        ![state[@"defaults"] isKindOfClass:[NSDictionary class]]) fail(@"Invalid route restoration file.");
    NSArray<NSDictionary *> *devices = deviceList();
    AudioDeviceID targets[3] = { 0 };
    for (unsigned index = 0; index < 3; ++index) {
        id entry = state[@"defaults"][keys[index]];
        if (![entry isKindOfClass:[NSDictionary class]] || ![entry[@"uid"] isKindOfClass:[NSString class]] ||
            [entry[@"uid"] length] == 0) fail(@"Missing saved device UID.");
        NSMutableArray<NSDictionary *> *matches = [NSMutableArray array];
        for (NSDictionary *device in devices) if ([device[@"uid"] isEqual:entry[@"uid"]]) [matches addObject:device];
        if (matches.count != 1) fail([NSString stringWithFormat:@"Saved %@ device %@ is missing or ambiguous. No devices changed.", keys[index], entry[@"uid"]]);
        NSString *channels = index == 0 ? @"inputChannels" : @"outputChannels";
        if ([matches.firstObject[channels] unsignedIntValue] == 0) fail(@"Saved device no longer provides the required input/output channels.");
        targets[index] = [matches.firstObject[@"id"] unsignedIntValue];
    }
    applyDefaults(targets);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "list") == 0) printJSON(snapshot());
        else if (argc == 3 && strcmp(argv[1], "save") == 0) saveSnapshot([NSString stringWithUTF8String:argv[2]]);
        else if (argc == 2 && strcmp(argv[1], "builtin") == 0) selectBuiltin();
        else if (argc == 3 && strcmp(argv[1], "restore") == 0) restoreSnapshot([NSString stringWithUTF8String:argv[2]]);
        else {
            fprintf(stderr, "usage: %s list | save <jsonpath> | builtin | restore <jsonpath>\n", argv[0]);
            return 2;
        }
    }
    return EXIT_SUCCESS;
}
