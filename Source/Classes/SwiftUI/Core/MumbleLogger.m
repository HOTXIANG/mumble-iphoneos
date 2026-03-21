//
//  MumbleLogger.m
//  Mumble
//
//  统一日志系统 ObjC 格式化辅助函数
//  当 Swift MumbleLogBridge 不可用时（MumbleKit 独立构建），回退到 os_log
//

#import "MumbleLogger.h"
#import <os/log.h>
#import <dlfcn.h>

/// 函数指针类型，对应 Swift 侧 @_cdecl 导出的 MumbleLogBridge
typedef void (*MumbleLogBridgeFn)(int level, const char *category,
                                  const char *message,
                                  const char *file,
                                  const char *function,
                                  int line);

/// 延迟解析 MumbleLogBridge 符号
static MumbleLogBridgeFn _ResolvedBridge(void) {
    static MumbleLogBridgeFn fn = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fn = (MumbleLogBridgeFn)dlsym(RTLD_DEFAULT, "MumbleLogBridge");
    });
    return fn;
}

static os_log_t _MumbleLogFallback(const char *category) {
    static NSMutableDictionary *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary new];
    });

    NSString *key = [NSString stringWithUTF8String:category];
    os_log_t log = (os_log_t)cache[key];
    if (!log) {
        log = os_log_create("cn.hotxiang.Mumble", category);
        cache[key] = (id)log;
    }
    return log;
}

static os_log_type_t _MumbleLogTypeFromLevel(int level) {
    switch (level) {
        case MU_LOG_LEVEL_VERBOSE: return OS_LOG_TYPE_DEBUG;
        case MU_LOG_LEVEL_DEBUG:   return OS_LOG_TYPE_DEBUG;
        case MU_LOG_LEVEL_INFO:    return OS_LOG_TYPE_INFO;
        case MU_LOG_LEVEL_WARNING: return OS_LOG_TYPE_DEFAULT;
        case MU_LOG_LEVEL_ERROR:   return OS_LOG_TYPE_ERROR;
        default:                   return OS_LOG_TYPE_DEFAULT;
    }
}

void MumbleLogFormatted(int level, const char *category,
                        const char *file, const char *function, int line,
                        NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    MumbleLogBridgeFn bridge = _ResolvedBridge();
    if (bridge) {
        // Swift LogManager 可用（主应用内运行）
        bridge(level, category, msg.UTF8String, file, function, line);
    } else {
        // 回退：直接使用 os_log（MumbleKit 独立构建）
        os_log_with_type(_MumbleLogFallback(category),
                         _MumbleLogTypeFromLevel(level),
                         "%{public}@", msg);
    }
}
