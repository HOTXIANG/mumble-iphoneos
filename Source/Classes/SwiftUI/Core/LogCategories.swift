//
//  LogCategories.swift
//  Mumble
//
//  Created by Claude on 2026/3/4.
//

import Foundation
import OSLog

// MARK: - Log Categories

/// 日志分类枚举，用于区分不同模块的日志输出
enum LogCategory: String, CaseIterable {
    /// 连接状态相关
    case connection = "Connection"
    /// 音频引擎相关
    case audio = "Audio"
    /// 数据库操作相关
    case database = "Database"
    /// 证书管理相关
    case certificate = "Certificate"
    /// 通知系统相关
    case notification = "Notification"
    /// UI 状态相关
    case ui = "UI"
}

// MARK: - Logger Extension

extension Logger {
    /// 连接状态日志
    static let connection = Logger(subsystem: "com.mumble.Mumble", category: LogCategory.connection.rawValue)

    /// 音频引擎日志
    static let audio = Logger(subsystem: "com.mumble.Mumble", category: LogCategory.audio.rawValue)

    /// 数据库操作日志
    static let database = Logger(subsystem: "com.mumble.Mumble", category: LogCategory.database.rawValue)

    /// 证书管理日志
    static let certificate = Logger(subsystem: "com.mumble.Mumble", category: LogCategory.certificate.rawValue)

    /// 通知系统日志
    static let notification = Logger(subsystem: "com.mumble.Mumble", category: LogCategory.notification.rawValue)

    /// UI 状态日志
    static let ui = Logger(subsystem: "com.mumble.Mumble", category: LogCategory.ui.rawValue)
}