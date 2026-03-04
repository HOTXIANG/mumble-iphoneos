//
//  MumbleLogger.h
//  Mumble
//
//  Created by Claude on 2026/3/4.
//

#import <Foundation/Foundation.h>
#import <os/log.h>

NS_ASSUME_NONNULL_BEGIN

/// ObjC 日志宏定义，与 Swift Logger 对应
/// 使用方式：MULogInfo(@"connection", @"连接成功");
/// 分类：connection, audio, database, certificate, notification, ui

#pragma mark - 日志宏

/// 信息级别日志
#define MULogInfo(category, format, ...) \
    os_log_info(OS_LOG_CATEGORY_##category, format, ##__VA_ARGS__)

/// 错误级别日志
#define MULogError(category, format, ...) \
    os_log_error(OS_LOG_CATEGORY_##category, format, ##__VA_ARGS__)

/// 调试级别日志
#define MULogDebug(category, format, ...) \
    os_log_debug(OS_LOG_CATEGORY_##category, format, ##__VA_ARGS__)

#pragma mark - 日志分类

// 预定义日志分类
extern os_log_t OS_LOG_CATEGORY_connection;
extern os_log_t OS_LOG_CATEGORY_audio;
extern os_log_t OS_LOG_CATEGORY_database;
extern os_log_t OS_LOG_CATEGORY_certificate;
extern os_log_t OS_LOG_CATEGORY_notification;
extern os_log_t OS_LOG_CATEGORY_ui;

NS_ASSUME_NONNULL_END