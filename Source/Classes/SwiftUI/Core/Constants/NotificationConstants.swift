//
//  NotificationConstants.swift
//  Mumble
//
//  Created by Claude on 2026/3/4.
//

import Foundation

// MARK: - Notification Names

extension Notification.Name {
    // MARK: - Connection Notifications

    /// 连接已建立
    static let muConnectionOpened = Notification.Name("MUConnectionOpenedNotification")

    /// 连接已关闭
    static let muConnectionClosed = Notification.Name("MUConnectionClosedNotification")

    /// 正在连接
    static let muConnectionConnecting = Notification.Name("MUConnectionConnectingNotification")

    /// 连接错误
    static let muConnectionError = Notification.Name("MUConnectionErrorNotification")

    /// 显示消息
    static let muAppShowMessage = Notification.Name("MUAppShowMessageNotification")

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

    // MARK: - Preferences Notifications

    /// 偏好设置已更改
    static let mumblePreferencesChanged = Notification.Name("MumblePreferencesChanged")
}