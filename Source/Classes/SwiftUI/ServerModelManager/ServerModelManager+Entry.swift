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

        // SystemMute 和 AudioRoute 只在实际连接到服务器后才激活，
        // 避免在欢迎界面插入耳机时触发麦克风激活
        if serverModel != nil {
            setupSystemMute()
            #if os(iOS)
            setupAudioRouteObservation()
            #endif
        }
    }

    func markAsRead() {
        // 1. 清除 App 内红点
        AppState.shared.unreadMessageCount = 0

        // 2. 清除 iOS 系统通知中心的推送
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
}
