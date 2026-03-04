//
//  NotificationConstants.swift
//  Mumble
//
//  Created by Claude on 2026/3/4.
//

import Foundation

// MARK: - Notification Names
// 注意：主要的连接通知已在 AppState.swift 中定义
// 此文件仅包含 ServerModelManager 相关的通知名称

extension Notification.Name {
    // MARK: - Certificate Notifications

    /// 证书已创建
    static let muCertificateCreated = Notification.Name("MUCertificateCreatedNotification")

    // MARK: - Handoff Notifications

    /// Handoff 已被另一设备继续
    static let mumbleHandoffContinued = Notification.Name("MumbleHandoffContinuedNotification")

    /// 收到 Handoff 请求
    static let mumbleHandoffReceived = Notification.Name("MumbleHandoffReceivedNotification")

    /// 请求恢复用户偏好
    static let mumbleHandoffRestoreUserPreferences = Notification.Name("MumbleHandoffRestoreUserPreferencesNotification")
}