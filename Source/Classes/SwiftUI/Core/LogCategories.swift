//
//  LogCategories.swift
//  Mumble
//
//  Created by Claude on 2026/3/4.
//

import Foundation
import OSLog

// MARK: - Log Categories
// 注意：Logger 扩展已在 AppState.swift 中定义
// 此文件仅包含 LogCategory 枚举定义，供其他模块参考

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