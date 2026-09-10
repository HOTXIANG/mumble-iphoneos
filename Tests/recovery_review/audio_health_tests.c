// Native tests execute the production inline helpers without starting audio IO.
#include "MKAudioCallbackHealth.h"
#include "MKAudioDeviceIO.h"

#include <limits.h>
#include <pthread.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>

static unsigned long checks;
#define CHECK(condition) do { \
    ++checks; \
    if (!(condition)) { \
        fprintf(stderr, "%s:%d: failed: %s\n", __FILE__, __LINE__, #condition); \
        exit(EXIT_FAILURE); \
    } \
} while (0)

static void test_health_expiry(void) {
    const uint64_t second = 1000000000ULL;
    const uint64_t started = 10 * second;
    CHECK(!MKAudioHealthExpired(started, started, 0));
    CHECK(!MKAudioHealthExpired(started + 5 * second - 1, started, 0));
    CHECK(MKAudioHealthExpired(started + 5 * second, started, 0));
    CHECK(MKAudioHealthExpired(started + 6 * second, started, 0));

    // Recent input/output completion renews only that direction's deadline.
    const uint64_t input = started + 4 * second;
    const uint64_t output = started + 8 * second;
    const uint64_t now = started + 9 * second;
    CHECK(MKAudioHealthExpired(now, started, input));
    CHECK(!MKAudioHealthExpired(now, started, output));
    CHECK(!MKAudioHealthExpired(input + 5 * second - 1, started, input));
    CHECK(MKAudioHealthExpired(input + 5 * second, started, input));

    // Clock values ahead of the observer must not unsigned-underflow to expiry.
    CHECK(!MKAudioHealthExpired(started - 1, started, 0));
    CHECK(!MKAudioHealthExpired(input - 1, started, input));
    CHECK(!MKAudioHealthExpired(0, UINT64_MAX, 0));
    CHECK(!MKAudioHealthExpired(UINT64_MAX, started, UINT64_MAX - second));
    CHECK(MKAudioHealthExpired(UINT64_MAX, started, UINT64_MAX - 5 * second));
    CHECK(MKAudioHealthExpired(UINT64_MAX, started, 0));
}

static void test_health_record(void) {
    MKAudioCallbackHealth health;
    atomic_init(&health.inputCompleted, 0);
    atomic_init(&health.outputCompleted, 0);
    CHECK(atomic_is_lock_free(&health.inputCompleted));
    CHECK(atomic_is_lock_free(&health.outputCompleted));
    CHECK(atomic_load_explicit(&health.inputCompleted, memory_order_relaxed) == 0);
    const uint64_t before = MKAudioHealthNow();
    MKAudioHealthRecord(&health.inputCompleted);
    const uint64_t input = atomic_load_explicit(&health.inputCompleted, memory_order_relaxed);
    const uint64_t after = MKAudioHealthNow();
    CHECK(input != 0 && input >= before && input <= after);
    CHECK(atomic_load_explicit(&health.outputCompleted, memory_order_relaxed) == 0);
    MKAudioHealthRecord(&health.outputCompleted);
    const uint64_t output = atomic_load_explicit(&health.outputCompleted, memory_order_relaxed);
    CHECK(output >= input);
    CHECK(!MKAudioHealthExpired(MKAudioHealthNow(), before, input));
    CHECK(!MKAudioHealthExpired(MKAudioHealthNow(), before, output));
}

typedef struct {
    atomic_uint_fast64_t *completed;
    atomic_bool done;
} Writer;

static void *write_completions(void *context) {
    Writer *writer = context;
    for (unsigned i = 0; i < 100000; ++i) MKAudioHealthRecord(writer->completed);
    atomic_store_explicit(&writer->done, true, memory_order_release);
    return NULL;
}

static void test_concurrent_callback_health(void) {
    MKAudioCallbackHealth health;
    atomic_init(&health.inputCompleted, 0);
    atomic_init(&health.outputCompleted, 0);
    Writer input = { .completed = &health.inputCompleted };
    Writer output = { .completed = &health.outputCompleted };
    atomic_init(&input.done, false);
    atomic_init(&output.done, false);
    pthread_t input_thread, output_thread;
    CHECK(pthread_create(&input_thread, NULL, write_completions, &input) == 0);
    CHECK(pthread_create(&output_thread, NULL, write_completions, &output) == 0);
    uint64_t previous_input = 0, previous_output = 0;
    do {
        uint64_t current_input = atomic_load_explicit(&health.inputCompleted, memory_order_relaxed);
        uint64_t current_output = atomic_load_explicit(&health.outputCompleted, memory_order_relaxed);
        uint64_t now = MKAudioHealthNow();
        CHECK(current_input >= previous_input && current_input <= now);
        CHECK(current_output >= previous_output && current_output <= now);
        previous_input = current_input;
        previous_output = current_output;
    } while (!atomic_load_explicit(&input.done, memory_order_acquire) ||
             !atomic_load_explicit(&output.done, memory_order_acquire));
    CHECK(pthread_join(input_thread, NULL) == 0);
    CHECK(pthread_join(output_thread, NULL) == 0);
    CHECK(atomic_load_explicit(&health.inputCompleted, memory_order_relaxed) > 0);
    CHECK(atomic_load_explicit(&health.outputCompleted, memory_order_relaxed) > 0);
}

static void test_render_capacity(void) {
    short samples[96];
    AudioBufferList buffers = { .mNumberBuffers = 1,
        .mBuffers = {{ .mNumberChannels = 2, .mDataByteSize = sizeof(samples), .mData = samples }} };
    CHECK(MKAudioDeviceCanRender(&buffers, 48, 2));
    CHECK(!MKAudioDeviceCanRender(&buffers, 49, 2));
    CHECK(!MKAudioDeviceCanRender(&buffers, 48, 1));
    CHECK(!MKAudioDeviceCanRender(&buffers, 48, 0));
    CHECK(!MKAudioDeviceCanRender(&buffers, 0, 2));
    CHECK(!MKAudioDeviceCanRender(NULL, 48, 2));
    buffers.mNumberBuffers = 0;
    CHECK(!MKAudioDeviceCanRender(&buffers, 48, 2));
    buffers.mNumberBuffers = 2;
    CHECK(!MKAudioDeviceCanRender(&buffers, 48, 2));
    buffers.mNumberBuffers = 1;
    buffers.mBuffers[0].mData = NULL;
    CHECK(!MKAudioDeviceCanRender(&buffers, 48, 2));
    buffers.mBuffers[0].mData = samples;

    // Compare with wide arithmetic across mono/stereo and partial byte frames.
    for (UInt32 channels = 1; channels <= 8; ++channels) {
        buffers.mBuffers[0].mNumberChannels = channels;
        for (UInt32 bytes = 0; bytes <= sizeof(samples); ++bytes) {
            buffers.mBuffers[0].mDataByteSize = bytes;
            for (UInt32 frames = 0; frames <= 100; ++frames) {
                bool expected = frames > 0 && (uint64_t)frames * channels * sizeof(short) <= bytes;
                CHECK(MKAudioDeviceCanRender(&buffers, frames, channels) == expected);
            }
        }
    }
    // These calls never access mData: only the arithmetic guard is being tested.
    buffers.mBuffers[0].mDataByteSize = UINT32_MAX;
    buffers.mBuffers[0].mNumberChannels = UINT32_MAX;
    CHECK(!MKAudioDeviceCanRender(&buffers, UINT32_MAX, UINT32_MAX));
    CHECK(!MKAudioDeviceCanRender(&buffers, 1, UINT32_MAX));
    buffers.mBuffers[0].mNumberChannels = 2;
    CHECK(!MKAudioDeviceCanRender(&buffers, UINT32_MAX, 2));
    CHECK(MKAudioDeviceCanRender(&buffers, UINT32_MAX / 4, 2));
    CHECK(!MKAudioDeviceCanRender(&buffers, UINT32_MAX / 4 + 1, 2));
}

static void test_silence(void) {
    unsigned char first[34], second[50];
    memset(first, 0xA5, sizeof(first));
    memset(second, 0x5A, sizeof(second));
    const size_t size = offsetof(AudioBufferList, mBuffers) + 3 * sizeof(AudioBuffer);
    AudioBufferList *buffers = calloc(1, size);
    CHECK(buffers != NULL);
    buffers->mNumberBuffers = 3;
    buffers->mBuffers[0] = (AudioBuffer){ .mNumberChannels = 1, .mDataByteSize = 32, .mData = first + 1 };
    buffers->mBuffers[1] = (AudioBuffer){ .mNumberChannels = 1, .mDataByteSize = UINT32_MAX, .mData = NULL };
    buffers->mBuffers[2] = (AudioBuffer){ .mNumberChannels = 2, .mDataByteSize = 48, .mData = second + 1 };
    AudioUnitRenderActionFlags flags = kAudioUnitRenderAction_PreRender;
    MKAudioDeviceSilence(buffers, &flags);
    CHECK(flags == (kAudioUnitRenderAction_PreRender | kAudioUnitRenderAction_OutputIsSilence));
    CHECK(first[0] == 0xA5 && first[33] == 0xA5);
    CHECK(second[0] == 0x5A && second[49] == 0x5A);
    for (unsigned i = 1; i < 33; ++i) CHECK(first[i] == 0);
    for (unsigned i = 1; i < 49; ++i) CHECK(second[i] == 0);
    CHECK(buffers->mNumberBuffers == 3 && buffers->mBuffers[0].mDataByteSize == 32);
    CHECK(buffers->mBuffers[2].mNumberChannels == 2 && buffers->mBuffers[2].mDataByteSize == 48);

    // Missing/empty buffers and flags are permitted on callback underflow.
    MKAudioDeviceSilence(NULL, NULL);
    flags = 0;
    MKAudioDeviceSilence(NULL, &flags);
    CHECK(flags == kAudioUnitRenderAction_OutputIsSilence);
    buffers->mNumberBuffers = 0;
    MKAudioDeviceSilence(buffers, NULL);
    buffers->mNumberBuffers = 1;
    buffers->mBuffers[0].mDataByteSize = 0;
    first[1] = 0x37;
    MKAudioDeviceSilence(buffers, NULL);
    CHECK(first[1] == 0x37);
    free(buffers);
}

int main(void) {
    test_health_expiry();
    test_health_record();
    test_concurrent_callback_health();
    test_render_capacity();
    test_silence();
    printf("audio health/buffer helpers: PASS (%lu checks, 200000 concurrent timestamp writes)\n", checks);
    return EXIT_SUCCESS;
}
