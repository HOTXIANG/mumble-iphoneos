//
//  MumbleLogger.m
//  Mumble
//
//  Created by Claude on 2026/3/4.
//

#import "MumbleLogger.h"
#import <os/log.h>

// 初始化日志分类
os_log_t OS_LOG_CATEGORY_connection = nil;
os_log_t OS_LOG_CATEGORY_audio = nil;
os_log_t OS_LOG_CATEGORY_database = nil;
os_log_t OS_LOG_CATEGORY_certificate = nil;
os_log_t OS_LOG_CATEGORY_notification = nil;
os_log_t OS_LOG_CATEGORY_ui = nil;

__attribute__((constructor))
static void MumbleLoggerInit(void) {
    OS_LOG_CATEGORY_connection = os_log_create("com.mumble.Mumble", "Connection");
    OS_LOG_CATEGORY_audio = os_log_create("com.mumble.Mumble", "Audio");
    OS_LOG_CATEGORY_database = os_log_create("com.mumble.Mumble", "Database");
    OS_LOG_CATEGORY_certificate = os_log_create("com.mumble.Mumble", "Certificate");
    OS_LOG_CATEGORY_notification = os_log_create("com.mumble.Mumble", "Notification");
    OS_LOG_CATEGORY_ui = os_log_create("com.mumble.Mumble", "UI");
}