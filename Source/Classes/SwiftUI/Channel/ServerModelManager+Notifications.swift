//
//  ServerModelManager+Notifications.swift
//  Mumble
//

import SwiftUI
import UserNotifications
import AudioToolbox

#if os(macOS)
import AppKit
#endif
#if os(iOS)
import UIKit
#endif

extension ServerModelManager {
    func requestNotificationAccess() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if granted {
                print("🔔 Notifications authorized")
            } else if let error = error {
                print("🚫 Notifications permission error: \(error.localizedDescription)")
            }
        }
    }

    func sendLocalNotification(title: String, body: String) {
        #if os(iOS)
        // iOS: 前台直接播放音效（不弹系统通知），后台发系统通知
        if UIApplication.shared.applicationState == .active {
            AudioServicesPlayAlertSound(1000)
            return
        }
        #endif
        // macOS: 始终发送系统通知（前台也发，由 willPresent delegate 控制展示方式和音效）
        // iOS 后台: 也发送系统通知
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Failed to schedule notification: \(error)")
            }
        }
    }

    var currentNotificationTitle: String {
        if let currentChannelName = serverModel?.connectedUser()?.channel()?.channelName() {
            return currentChannelName
        }
        return serverName ?? "Mumble"
    }

    func setupNotifications() {
        // 1. 先清理旧的，防止叠加
        tokenHolder.removeAll()

        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("MUConnectionOpenedNotification"), object: nil)

        let center = NotificationCenter.default

        // 2. 注册并保存令牌
        tokenHolder.add(center.addObserver(forName: ServerModelNotificationManager.rebuildModelNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.rebuildModelArray() }
        })

        tokenHolder.add(center.addObserver(forName: ServerModelNotificationManager.userStateUpdatedNotification, object: nil, queue: nil) { [weak self] notification in
            guard let userInfo = notification.userInfo, let userSession = userInfo["userSession"] as? UInt else { return }
            Task { @MainActor in self?.updateUserBySession(userSession) }
        })

        tokenHolder.add(center.addObserver(forName: ServerModelNotificationManager.userTalkStateChangedNotification, object: nil, queue: nil) { [weak self] notification in
            guard let userInfo = notification.userInfo, let userSession = userInfo["userSession"] as? UInt, let talkState = userInfo["talkState"] as? MKTalkState else { return }
            Task { @MainActor in self?.updateUserTalkingState(userSession: userSession, talkState: talkState) }
        })

        tokenHolder.add(center.addObserver(forName: ServerModelNotificationManager.channelRenamedNotification, object: nil, queue: nil) { [weak self] notification in
            guard let userInfo = notification.userInfo, let channelId = userInfo["channelId"] as? UInt, let newName = userInfo["newName"] as? String else { return }
            Task { @MainActor in self?.updateChannelName(channelId: channelId, newName: newName) }
        })

        tokenHolder.add(center.addObserver(forName: ServerModelNotificationManager.userMovedNotification, object: nil, queue: nil) { [weak self] notification in
            guard let userInfo = notification.userInfo, let user = userInfo["user"] as? MKUser, let channel = userInfo["channel"] as? MKChannel else { return }
            let mover = userInfo["mover"] as? MKUser
            let userTransfer = UnsafeTransfer(value: user)
            let channelTransfer = UnsafeTransfer(value: channel)
            let moverTransfer = mover.map { UnsafeTransfer(value: $0) }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let safeUser = userTransfer.value
                let safeChannel = channelTransfer.value
                let safeMover = moverTransfer?.value
                let movingUserSession = safeUser.session()
                let movingUserName = safeUser.userName() ?? "Unknown"
                let destChannelName = safeChannel.channelName() ?? "Unknown Channel"
                let destChannelId = safeChannel.channelId()
                if let connectedUser = self.serverModel?.connectedUser() {
                    if movingUserSession == connectedUser.session() {
                        // 如果是通过密码进入的频道，标记为密码频道（橙色锁）
                        if let pendingId = self.pendingPasswordChannelId, pendingId == destChannelId {
                            self.channelsWithPassword.insert(destChannelId)
                            self.pendingPasswordChannelId = nil
                        }

                        // 区分自己移动和被管理员移动
                        let movedBySelf = (safeMover == nil || safeMover?.session() == connectedUser.session())
                        if movedBySelf {
                            self.addSystemNotification("You moved to channel \(destChannelName)", category: .userMoved, suppressPush: true)
                        } else {
                            let moverName = safeMover?.userName() ?? "admin"
                            self.addSystemNotification("You were moved to channel \(destChannelName) by \(moverName)", category: .movedByAdmin)
                        }

                        // 更新 Handoff Activity 的频道信息
                        HandoffManager.shared.updateActivityChannel(
                            channelId: Int(destChannelId),
                            channelName: destChannelName
                        )
                    } else {
                        let myCurrentChannelId = connectedUser.channel()?.channelId()
                        if let userIndex = self.userIndexMap[movingUserSession] {
                            var originChannelId: UInt?
                            let userItem = self.modelItems[userIndex]
                            for i in stride(from: userIndex - 1, through: 0, by: -1) {
                                let item = self.modelItems[i]
                                if item.type == .channel && item.indentLevel < userItem.indentLevel {
                                    if let ch = item.object as? MKChannel { originChannelId = ch.channelId() }
                                    break
                                }
                            }
                            let isLeavingMyChannel = (originChannelId == myCurrentChannelId)
                            let isEnteringMyChannel = (destChannelId == myCurrentChannelId)
                            if isLeavingMyChannel || isEnteringMyChannel {
                                self.addSystemNotification("\(movingUserName) moved to \(destChannelName)", category: .userMoved)
                            }
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
                self.rebuildModelArray()
            }
        })

        tokenHolder.add(center.addObserver(forName: ServerModelNotificationManager.userJoinedNotification, object: nil, queue: nil) { [weak self] notification in
            guard let userInfo = notification.userInfo, let user = userInfo["user"] as? MKUser else { return }
            let userTransfer = UnsafeTransfer(value: user)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let safeUser = userTransfer.value
                self.applySavedUserPreferences(user: safeUser)
                let userName = safeUser.userName() ?? "Unknown User"
                let category: SystemNotifyCategory = self.isUserInSameChannelAsMe(safeUser) ? .userJoinedSameChannel : .userJoinedOtherChannels
                self.addSystemNotification("\(userName) connected", category: category)
                self.rebuildModelArray()
            }
        })

        tokenHolder.add(center.addObserver(forName: ServerModelNotificationManager.userLeftNotification, object: nil, queue: nil) { [weak self] notification in
            guard let userInfo = notification.userInfo, let user = userInfo["user"] as? MKUser else { return }
            let userTransfer = UnsafeTransfer(value: user)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let safeUser = userTransfer.value
                let userName = safeUser.userName() ?? "Unknown User"
                let category: SystemNotifyCategory = self.isUserInSameChannelAsMe(safeUser) ? .userLeftSameChannel : .userLeftOtherChannels
                self.addSystemNotification("\(userName) disconnected", category: category)
                let session = safeUser.session()
                // 清除离开用户的监听状态
                for (channelId, var listeners) in self.channelListeners {
                    listeners.remove(session)
                    if listeners.isEmpty {
                        self.channelListeners.removeValue(forKey: channelId)
                    } else {
                        self.channelListeners[channelId] = listeners
                    }
                }
            }
        })

        // 核心修复：消息去重 + 监听器管理
        tokenHolder.add(center.addObserver(forName: ServerModelNotificationManager.textMessageReceivedNotification, object: nil, queue: nil) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let message = userInfo["message"] as? MKTextMessage,
                  let user = userInfo["user"] as? MKUser else { return }

            let senderName = user.userName() ?? "Unknown"
            let plainText = (message.plainTextString() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let imageData = message.embeddedImages().compactMap { self?.dataFromDataURLString($0 as? String ?? "") }
            let senderSession = user.session()

            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let connectedUserSession = self.serverModel?.connectedUser()?.session()

                if senderSession == connectedUserSession {
                    print("🚫 Ignoring echoed message from self to prevent duplicate.")
                    return
                }

                self.handleReceivedMessage(
                    senderName: senderName,
                    plainText: plainText,
                    imageData: imageData,
                    senderSession: senderSession,
                    connectedUserSession: connectedUserSession
                )

                #if os(macOS)
                // macOS 分栏模式：前台即已读，只在非活跃窗口时累计未读
                if !NSApplication.shared.isActive {
                    AppState.shared.unreadMessageCount += 1
                } else {
                    // 前台活跃时不累计未读数；延迟清理通知中心，让横幅有时间显示
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
                    }
                }
                #else
                if AppState.shared.currentTab != .messages {
                    AppState.shared.unreadMessageCount += 1
                }
                #endif
            }
        })

        // 私聊消息接收
        tokenHolder.add(center.addObserver(forName: ServerModelNotificationManager.privateMessageReceivedNotification, object: nil, queue: nil) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let message = userInfo["message"] as? MKTextMessage,
                  let user = userInfo["user"] as? MKUser else { return }

            let senderName = user.userName() ?? "Unknown"
            let plainText = (message.plainTextString() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let imageData = message.embeddedImages().compactMap { self?.dataFromDataURLString($0 as? String ?? "") }
            let senderSession = user.session()

            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let connectedUserSession = self.serverModel?.connectedUser()?.session()

                // 忽略自己发给自己的回显
                if senderSession == connectedUserSession {
                    return
                }

                let images = imageData.compactMap { PlatformImage(data: $0) }

                let pmMessage = ChatMessage(
                    type: .privateMessage,
                    senderName: senderName,
                    attributedMessage: self.attributedString(from: plainText),
                    images: images,
                    timestamp: Date(),
                    isSentBySelf: false,
                    privatePeerName: senderName
                )
                self.messages.append(pmMessage)

                // 发送通知
                let defaults = UserDefaults.standard
                let notifyEnabled: Bool = {
                    if let v = defaults.object(forKey: "NotificationNotifyPrivateMessages") as? Bool { return v }
                    return defaults.object(forKey: "NotificationNotifyUserMessages") as? Bool ?? true
                }()
                if notifyEnabled {
                    let bodyText = plainText.isEmpty ? "[Image]" : plainText
                    self.sendLocalNotification(title: "PM from \(senderName)", body: bodyText)
                }

                #if os(macOS)
                if !NSApplication.shared.isActive {
                    AppState.shared.unreadMessageCount += 1
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
                    }
                }
                #else
                if AppState.shared.currentTab != .messages {
                    AppState.shared.unreadMessageCount += 1
                }
                #endif
            }
        })

        // 权限拒绝通知
        tokenHolder.add(center.addObserver(forName: ServerModelNotificationManager.permissionDeniedNotification, object: nil, queue: nil) { [weak self] notification in
            let reason = notification.userInfo?["reason"] as? String
            let permRaw = notification.userInfo?["permission"] as? UInt32
            let channel = notification.userInfo?["channel"] as? MKChannel
            let channelTransfer = channel.map { UnsafeTransfer(value: $0) }
            Task { @MainActor [weak self] in
                guard let self = self else { return }

                // 检测是否为 Enter 权限被拒绝
                let isEnterDenied = permRaw.map { ($0 & MKPermissionEnter.rawValue) != 0 } ?? false
                let deniedChannelId = channelTransfer?.value.channelId()
                let isUserInitiated = deniedChannelId != nil && deniedChannelId == self.userInitiatedJoinChannelId

                // ACL 扫描期间抑制后台扫描的 permission denied（但不抑制用户主动加入的）
                if self.isScanningACLs && !isUserInitiated { return }

                if isEnterDenied, let ct = channelTransfer {
                    let ch = ct.value
                    // 清除主动加入标记
                    if isUserInitiated { self.userInitiatedJoinChannelId = nil }
                    // 弹出密码提示框
                    self.passwordPromptChannel = ch
                    self.pendingPasswordInput = ""
                    self.addSystemNotification("Access denied. You may try entering a password.")
                } else if let reason = reason {
                    self.addSystemNotification("Permission denied: \(reason)")
                } else {
                    self.addSystemNotification("Permission denied")
                }
            }
        })

        // ACL 接收通知 - 检测频道是否有密码保护
        tokenHolder.add(center.addObserver(forName: ServerModelNotificationManager.aclReceivedNotification, object: nil, queue: nil) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let accessControl = userInfo["accessControl"] as? MKAccessControl,
                  let channel = userInfo["channel"] as? MKChannel else { return }
            let channelTransfer = UnsafeTransfer(value: channel)
            let aclTransfer = UnsafeTransfer(value: accessControl)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.updatePasswordStatus(for: channelTransfer.value, from: aclTransfer.value)
            }
        })

        // 新频道添加时自动扫描其权限
        tokenHolder.add(center.addObserver(forName: ServerModelNotificationManager.channelAddedNotification, object: nil, queue: nil) { [weak self] notification in
            guard let channel = notification.userInfo?["channel"] as? MKChannel else { return }
            let channelTransfer = UnsafeTransfer(value: channel)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // 请求权限查询（所有用户可用）
                self.serverModel?.requestPermission(for: channelTransfer.value)
                // 管理员还请求 ACL（用于区分密码和权限限制）
                if let connectedUser = self.serverModel?.connectedUser(), connectedUser.isAuthenticated() {
                    self.serverModel?.requestAccessControl(for: channelTransfer.value)
                }
            }
        })

        // PermissionQuery 结果 - 更新频道权限和限制状态后刷新 UI
        tokenHolder.add(center.addObserver(forName: ServerModelNotificationManager.permissionQueryResultNotification, object: nil, queue: nil) { [weak self] notification in
            guard let channel = notification.userInfo?["channel"] as? MKChannel,
                  let permissions = notification.userInfo?["permissions"] as? UInt32 else { return }
            let channelId = channel.channelId()
            let hasEnter = (permissions & MKPermissionEnter.rawValue) != 0
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // 存储此频道的完整权限位
                self.channelPermissions[channelId] = permissions
                // 记录用户有权进入的频道
                if hasEnter {
                    self.channelsUserCanEnter.insert(channelId)
                } else {
                    self.channelsUserCanEnter.remove(channelId)
                }
                self.rebuildModelArray()
            }
        })

        // QueryUsers 结果：离线注册用户名解析（UserID -> Name）
        tokenHolder.add(center.addObserver(forName: ServerModelNotificationManager.aclUserNamesResolvedNotification, object: nil, queue: nil) { [weak self] notification in
            let raw = notification.userInfo?["userNamesById"]
            var resolved: [Int: String] = [:]
            if let typed = raw as? [NSNumber: String] {
                for (key, value) in typed {
                    resolved[key.intValue] = value
                }
            } else if let dict = raw as? NSDictionary {
                for (key, value) in dict {
                    if let idNum = key as? NSNumber, let name = value as? String {
                        resolved[idNum.intValue] = name
                    }
                }
            }
            guard !resolved.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                for (id, name) in resolved {
                    self.aclUserNamesById[id] = name
                    self.pendingACLUserNameQueries.remove(id)
                }
            }
        })

        // 监听频道变更通知（来自服务器回传的 UserState）
        tokenHolder.add(center.addObserver(forName: NSNotification.Name("MKListeningChannelAddNotification"), object: nil, queue: nil) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let user = userInfo["user"] as? MKUser,
                  let addChannels = userInfo["addChannels"] as? [NSNumber] else { return }
            let userTransfer = UnsafeTransfer(value: user)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let u = userTransfer.value
                let session = u.session()
                let isMyself = (session == MUConnectionController.shared()?.serverModel?.connectedUser()?.session())

                for channelIdNum in addChannels {
                    let channelId = channelIdNum.uintValue

                    // 如果是自己，且 listeningChannels 中没有此频道（说明我们已经 stopListening 了），
                    // 跳过服务器的延迟回传，防止竞态条件导致监听行重新出现
                    if isMyself && !self.listeningChannels.contains(channelId) {
                        // 服务器确认添加监听 → 同步到 listeningChannels
                        self.listeningChannels.insert(channelId)
                    }

                    var listeners = self.channelListeners[channelId] ?? Set()
                    listeners.insert(session)
                    self.channelListeners[channelId] = listeners
                }
                // 检查是否有人开始监听我所在的频道 → 通知
                if let myChannel = MUConnectionController.shared()?.serverModel?.connectedUser()?.channel(),
                   !isMyself {
                    for channelIdNum in addChannels {
                        if channelIdNum.uintValue == myChannel.channelId() {
                            let userName = u.userName() ?? "Someone"
                            self.addSystemNotification("\(userName) started listening to your channel", category: .channelListening)
                        }
                    }
                }
                self.rebuildModelArray()
            }
        })

        tokenHolder.add(center.addObserver(forName: NSNotification.Name("MKListeningChannelRemoveNotification"), object: nil, queue: nil) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let user = userInfo["user"] as? MKUser,
                  let removeChannels = userInfo["removeChannels"] as? [NSNumber] else { return }
            let userTransfer = UnsafeTransfer(value: user)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let u = userTransfer.value
                let session = u.session()
                let isMyself = (session == MUConnectionController.shared()?.serverModel?.connectedUser()?.session())

                for channelIdNum in removeChannels {
                    let channelId = channelIdNum.uintValue
                    self.channelListeners[channelId]?.remove(session)
                    if self.channelListeners[channelId]?.isEmpty == true {
                        self.channelListeners.removeValue(forKey: channelId)
                    }
                    // 如果是自己被服务器移除监听（管理员操作或频道删除），同步更新 listeningChannels
                    if isMyself {
                        self.listeningChannels.remove(channelId)
                    }
                }
                // 检查是否有人停止监听我所在的频道 → 通知
                if let myChannel = MUConnectionController.shared()?.serverModel?.connectedUser()?.channel(),
                   !isMyself {
                    for channelIdNum in removeChannels {
                        if channelIdNum.uintValue == myChannel.channelId() {
                            let userName = u.userName() ?? "Someone"
                            self.addSystemNotification("\(userName) stopped listening to your channel", category: .channelListening)
                        }
                    }
                }
                self.rebuildModelArray()
            }
        })

        // 音频设置即将变更 → 保存当前闭麦状态，防止系统回调在 restart 期间覆盖
        center.addObserver(self, selector: #selector(handlePreferencesAboutToChange), name: NSNotification.Name("MumblePreferencesChanged"), object: nil)

        // 音频引擎重启后恢复闭麦/不听状态（修改音频设置时 MKAudio.restart() 会重置音频输入）
        tokenHolder.add(center.addObserver(forName: NSNotification.Name.MKAudioDidRestart, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.restoreMuteDeafenStateAfterAudioRestart()
            }
        })

        center.addObserver(self, selector: #selector(handleConnectionOpened), name: NSNotification.Name("MUConnectionOpenedNotification"), object: nil)
    }

    @objc func handleConnectionOpened(_ notification: Notification) {
        print("✅ Connection Opened - Triggering Restore")

        let userInfo = notification.userInfo

        Task { @MainActor in
            // 设置服务器显示名称
            if let extractedDisplayName = userInfo?["displayName"] as? String {
                AppState.shared.serverDisplayName = extractedDisplayName
            }

            if let welcomeText = userInfo?["welcomeMessage"] as? String, !welcomeText.isEmpty {
                // 这里也使用带返回值的添加方法，但通常欢迎语不需要发通知
                self.appendNotificationMessage(text: welcomeText, senderName: "Server")
            }

            self.setupServerModel()

            // 连接初期立即开始抑制 permission denied
            // （ACL 扫描和初始权限同步期间，服务器会发送大量 PermissionDenied）
            self.isScanningACLs = true

            Task.detached(priority: .userInitiated) {
                // 稍微等待 UI 动画完成 (例如进入频道的 Push 动画)
                try? await Task.sleep(nanoseconds: 600_000_000) // 0.6s

                // 回到主线程执行具体的恢复逻辑
                await MainActor.run {
                    print("♻️ [Async] Restoring user preferences...")
                    self.restoreAllUserPreferences()

                    // 初始进入时的状态同步
                    if let user = self.serverModel?.connectedUser(), user.isSelfMuted() {
                        print("🔒 [Async] Initial Sync: Enforcing System Mute")
                        self.systemMuteManager.setSystemMute(true)
                    }
                }

                // 延迟 2s 后扫描频道权限（确保频道树已完全构建）
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s
                await MainActor.run {
                    print("🔐 [Async] Scanning channel permissions...")
                    self.scanAllChannelPermissions()
                }

                // 延迟 1s 后恢复之前的监听（确保频道树和权限扫描已完成）
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
                await MainActor.run {
                    self.reRegisterListeningChannels()
                }
            }
        }
    }

    /// 系统通知分类，每类对应一个独立的 UserDefaults 开关
    enum SystemNotifyCategory: String {
        case userJoinedSameChannel    = "NotifyUserJoinedSameChannel"
        case userLeftSameChannel      = "NotifyUserLeftSameChannel"
        case userJoinedOtherChannels  = "NotifyUserJoinedOtherChannels"
        case userLeftOtherChannels    = "NotifyUserLeftOtherChannels"
        case userMoved        = "NotifyUserMoved"
        case muteDeafen       = "NotifyMuteDeafen"
        case movedByAdmin     = "NotifyMovedByAdmin"
        case channelListening = "NotifyChannelListening"

        var defaultEnabled: Bool {
            switch self {
            case .userJoinedSameChannel, .userLeftSameChannel, .userMoved, .movedByAdmin, .channelListening:
                return true
            case .userJoinedOtherChannels, .userLeftOtherChannels, .muteDeafen:
                return false
            }
        }
    }

    /// 添加系统消息到聊天区域，并根据分类开关决定是否发送系统推送通知
    /// - Parameters:
    ///   - text: 消息文本
    ///   - category: 通知分类（nil 则不推送）
    ///   - suppressPush: 为 true 时只在聊天区域显示，不发送系统推送（用于自己的操作）
    func addSystemNotification(_ text: String, category: SystemNotifyCategory? = nil, suppressPush: Bool = false) {
        let didAppend = appendNotificationMessage(text: text, senderName: "System")

        guard didAppend, !suppressPush else { return }

        // 如果指定了分类，检查该分类的独立开关（默认开启）
        // 如果未指定分类（如 "Connected to server"），不发送推送
        if let category = category {
            let shouldNotify = UserDefaults.standard.object(forKey: category.rawValue) as? Bool ?? category.defaultEnabled
            if shouldNotify {
                sendLocalNotification(title: currentNotificationTitle, body: text)
            }
        }
    }

    func isUserInSameChannelAsMe(_ user: MKUser) -> Bool {
        guard let myChannelId = serverModel?.connectedUser()?.channel()?.channelId() else {
            return false
        }
        if let directUserChannelId = user.channel()?.channelId() {
            return directUserChannelId == myChannelId
        }
        guard let inferredUserChannelId = inferredChannelId(forUserSession: user.session()) else {
            return false
        }
        return inferredUserChannelId == myChannelId
    }

    func inferredChannelId(forUserSession session: UInt) -> UInt? {
        guard let userIndex = userIndexMap[session],
              userIndex > 0,
              userIndex < modelItems.count else {
            return nil
        }
        let userItem = modelItems[userIndex]
        for i in stride(from: userIndex - 1, through: 0, by: -1) {
            let item = modelItems[i]
            if item.type == .channel && item.indentLevel < userItem.indentLevel {
                return (item.object as? MKChannel)?.channelId()
            }
        }
        return nil
    }

    // 新增：一个用于将纯文本转换为 AttributedString 的辅助函数
    func attributedString(from plainText: String) -> AttributedString {
        do {
            // 使用 Markdown 解析器来自动识别链接
            // `inlineOnlyPreservingWhitespace` 选项能最好地保留原始文本的格式
            return try AttributedString(markdown: plainText, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        } catch {
            // 如果 Markdown 解析失败，则返回一个普通的字符串
            print("Could not parse markdown: \(error)")
            return AttributedString(plainText)
        }
    }

    // 替换为系统级、更健壮的 Data URI 解析方法
    nonisolated func dataFromDataURLString(_ dataURLString: String) -> Data? {
        guard dataURLString.hasPrefix("data:"), let commaRange = dataURLString.range(of: ",") else {
            return nil
        }

        var base64String = String(dataURLString[commaRange.upperBound...])

        // 1. 移除所有空白和换行符
        base64String = base64String.components(separatedBy: .whitespacesAndNewlines).joined()

        // 2. 进行 URL 解码 (以防万一)
        base64String = base64String.removingPercentEncoding ?? base64String

        return Data(base64Encoded: base64String, options: .ignoreUnknownCharacters)
    }

    @discardableResult
    func appendUserMessage(senderName: String, text: String, isSentBySelf: Bool, images: [PlatformImage] = []) -> Bool {
        let newMessage = ChatMessage(
            id: UUID(),
            type: .userMessage,
            senderName: senderName,
            attributedMessage: attributedString(from: text),
            images: images,
            timestamp: Date(),
            isSentBySelf: isSentBySelf
        )
        messages.append(newMessage)
        return true
    }

    @discardableResult
    func appendNotificationMessage(text: String, senderName: String) -> Bool {
        if let lastMsg = messages.last {
            let isSameContent = (lastMsg.attributedMessage.description == text) || (lastMsg.attributedMessage.description == attributedString(from: text).description)
            if lastMsg.senderName == senderName && isSameContent {
                return false
            }
        }

        let newMessage = ChatMessage(
            id: UUID(),
            type: .notification,
            senderName: senderName,
            attributedMessage: attributedString(from: text),
            images: [],
            timestamp: Date(),
            isSentBySelf: false
        )
        messages.append(newMessage)
        return true
    }

    func handleReceivedMessage(senderName: String, plainText: String, imageData: [Data], senderSession: UInt, connectedUserSession: UInt?) {
        let images = imageData.compactMap { PlatformImage(data: $0) }

        let didAppend = appendUserMessage(
            senderName: senderName,
            text: plainText,
            isSentBySelf: senderSession == connectedUserSession,
            images: images
        )

        // 只有当消息真的被添加了 (didAppend == true)，才处理后续通知
        if didAppend {
            let isSentBySelf = (senderSession == connectedUserSession)
            let defaults = UserDefaults.standard
            let notifyEnabled: Bool = {
                if let v = defaults.object(forKey: "NotificationNotifyNormalUserMessages") as? Bool { return v }
                return defaults.object(forKey: "NotificationNotifyUserMessages") as? Bool ?? true
            }()

            // 只有不是自己发的、且开启了通知，才发通知
            if !isSentBySelf && notifyEnabled {
                let bodyText = plainText.isEmpty ? "[Image]" : plainText
                let notificationBody = "\(senderName): \(bodyText)"
                sendLocalNotification(title: currentNotificationTitle, body: notificationBody)
            }
        }
    }
}
