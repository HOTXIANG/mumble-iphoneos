//
//  MumbleLogger.h
//  Mumble
//
//  统一日志系统 ObjC 桥接层
//  所有日志通过 MumbleLogBridge() C 函数路由到 Swift LogManager
//  支持 5 级日志：verbose(0) / debug(1) / info(2) / warning(3) / error(4)
//

#ifndef MumbleLogger_h
#define MumbleLogger_h

#pragma mark - Log Level Constants

#define MU_LOG_LEVEL_VERBOSE 0
#define MU_LOG_LEVEL_DEBUG   1
#define MU_LOG_LEVEL_INFO    2
#define MU_LOG_LEVEL_WARNING 3
#define MU_LOG_LEVEL_ERROR   4

#pragma mark - C Bridge Declaration

/// Swift 侧 @_cdecl 导出的 C 函数
/// MumbleLogFormatted 通过 dlsym 动态查找此符号
/// MumbleKit 独立构建时自动回退到 os_log

#ifdef __OBJC__

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// ObjC 格式化辅助函数（在 .m 文件中实现）
extern void MumbleLogFormatted(int level, const char *category,
                               const char *file, const char *function, int line,
                               NSString *format, ...) NS_FORMAT_FUNCTION(6, 7);

#pragma mark - Application Layer Macros (MU*)
/// 用法：MULogInfo(Connection, @"连接成功: %@", hostname);

#define MULogVerbose(category, format, ...) \
    MumbleLogFormatted(MU_LOG_LEVEL_VERBOSE, #category, __FILE__, __FUNCTION__, __LINE__, format, ##__VA_ARGS__)

#define MULogDebug(category, format, ...) \
    MumbleLogFormatted(MU_LOG_LEVEL_DEBUG, #category, __FILE__, __FUNCTION__, __LINE__, format, ##__VA_ARGS__)

#define MULogInfo(category, format, ...) \
    MumbleLogFormatted(MU_LOG_LEVEL_INFO, #category, __FILE__, __FUNCTION__, __LINE__, format, ##__VA_ARGS__)

#define MULogWarning(category, format, ...) \
    MumbleLogFormatted(MU_LOG_LEVEL_WARNING, #category, __FILE__, __FUNCTION__, __LINE__, format, ##__VA_ARGS__)

#define MULogError(category, format, ...) \
    MumbleLogFormatted(MU_LOG_LEVEL_ERROR, #category, __FILE__, __FUNCTION__, __LINE__, format, ##__VA_ARGS__)

#pragma mark - MumbleKit Layer Macros (MK*)
/// 用法：MKLogInfo(Audio, @"音频引擎启动: sampleRate=%f", rate);

#define MKLogVerbose(category, format, ...) \
    MumbleLogFormatted(MU_LOG_LEVEL_VERBOSE, #category, __FILE__, __FUNCTION__, __LINE__, format, ##__VA_ARGS__)

#define MKLogDebug(category, format, ...) \
    MumbleLogFormatted(MU_LOG_LEVEL_DEBUG, #category, __FILE__, __FUNCTION__, __LINE__, format, ##__VA_ARGS__)

#define MKLogInfo(category, format, ...) \
    MumbleLogFormatted(MU_LOG_LEVEL_INFO, #category, __FILE__, __FUNCTION__, __LINE__, format, ##__VA_ARGS__)

#define MKLogWarning(category, format, ...) \
    MumbleLogFormatted(MU_LOG_LEVEL_WARNING, #category, __FILE__, __FUNCTION__, __LINE__, format, ##__VA_ARGS__)

#define MKLogError(category, format, ...) \
    MumbleLogFormatted(MU_LOG_LEVEL_ERROR, #category, __FILE__, __FUNCTION__, __LINE__, format, ##__VA_ARGS__)

NS_ASSUME_NONNULL_END

#endif /* __OBJC__ */

#endif /* MumbleLogger_h */
