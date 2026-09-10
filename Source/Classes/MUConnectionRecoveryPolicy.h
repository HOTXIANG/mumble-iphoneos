// Automatic retries must not become a rapid login loop after brief joins.
#include <stdint.h>

static inline double MURecoveryMinimumDelay(uint32_t consecutiveFailures) {
    const double delays[] = { 5, 15, 30, 60, 120, 300 };
    uint32_t index = consecutiveFailures ? consecutiveFailures - 1 : 0;
    return delays[index < 6 ? index : 5];
}

static inline uint32_t MURecoveryFailureCount(uint32_t previous, double joinedAt, double now) {
    if (joinedAt > 0 && now >= joinedAt && now - joinedAt >= 60) return 1;
    return previous < 6 ? previous + 1 : 6;
}

static inline double MURecoveryScheduledDelay(double requested, double earliest, double now) {
    double remaining = earliest > now ? earliest - now : 0;
    return requested > remaining ? requested : remaining;
}
