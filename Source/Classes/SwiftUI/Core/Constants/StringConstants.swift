//
//  StringConstants.swift
//  Mumble
//
//  Created by Claude on 2026/3/4.
//

import Foundation

// MARK: - String Constants

/// 字符串常量，集中管理硬编码字符串
enum StringConstants {
    // MARK: - UserDefaults Keys

    enum UserDefaultsKey {
        /// 最后连接的服务器
        static let lastServer = "MULastConnectedServer"
        /// 音频预处理设置
        static let audioPreprocess = "MUPreprocessAudio"
        /// Handoff 偏好配置
        static let handoffPreferredProfile = "HandoffPreferredProfileKey"
        /// Handoff 同步本地音频设置
        static let handoffSyncLocalAudio = "HandoffSyncLocalAudioSettings"
    }

    // MARK: - Keychain

    enum Keychain {
        /// Keychain 服务标识
        static let service = "MumbleKeychainService"
    }

    // MARK: - Handoff

    enum Handoff {
        /// Handoff Activity 类型
        static let activityType = "info.mumble.Mumble.serverConnection"
    }

    // MARK: - Database

    enum Database {
        /// 数据库文件名
        static let fileName = "mumble.sqlite"
    }

    // MARK: - App Info

    enum App {
        /// Bundle ID
        static let bundleIdentifier = "com.mumble.Mumble"
    }
}