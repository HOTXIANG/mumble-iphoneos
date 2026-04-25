//
//  ServerModelManager+Entry.swift
//  Mumble
//

import SwiftUI
import UserNotifications
import OSLog

extension ServerModelManager {
    func activate() {
        MumbleLogger.connection.debug("ServerModelManager: ACTIVATE - Activating model and notifications.")
        setupServerModel()
        setupNotifications()
        requestNotificationAccess()
    }

    func markAsRead() {
        // 1. 清除 App 内红点
        AppState.shared.unreadMessageCount = 0

        // 2. 清除 iOS 系统通知中心的推送
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
}
