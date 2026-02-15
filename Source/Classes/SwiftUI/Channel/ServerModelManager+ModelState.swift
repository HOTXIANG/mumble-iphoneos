//
//  ServerModelManager+ModelState.swift
//  Mumble
//

import SwiftUI

extension ServerModelManager {
    func updateUserBySession(_ session: UInt) {
        guard let index = userIndexMap[session],
              index < modelItems.count,
              let user = modelItems[index].object as? MKUser else {
            return
        }

        // 检测 mute/deafen 状态变化，生成系统消息
        let currentMuted = user.isSelfMuted()
        let currentDeafened = user.isSelfDeafened()

        if let prev = previousMuteStates[session] {
            // 判断是否需要通知：自己的变化始终通知，他人的变化只在同频道时通知
            let isSelf = serverModel?.connectedUser()?.session() == session
            let isInSameChannel: Bool = {
                guard let myChannelId = serverModel?.connectedUser()?.channel()?.channelId(),
                      let theirChannelId = user.channel()?.channelId() else { return false }
                return myChannelId == theirChannelId
            }()

            if isSelf || isInSameChannel {
                let displayName = isSelf ? "You" : (user.userName() ?? "Unknown")

                if prev.isSelfDeafened != currentDeafened {
                    // 不听状态变化（优先级高于闭麦，因为 deafen 隐含 mute）
                    let action = currentDeafened ? "deafened" : "undeafened"
                    addSystemNotification("\(displayName) \(action)", category: .muteDeafen, suppressPush: isSelf)
                } else if prev.isSelfMuted != currentMuted {
                    // 闭麦状态变化
                    let action = currentMuted ? "muted" : "unmuted"
                    addSystemNotification("\(displayName) \(action)", category: .muteDeafen, suppressPush: isSelf)
                }
            }
        }
        previousMuteStates[session] = (isSelfMuted: currentMuted, isSelfDeafened: currentDeafened)

        // 更新 item 的状态
        updateUserItemState(
            item: modelItems[index],
            user: user
        )

        // 手动发送通知，告诉所有观察者（比如 ChannelListView）：“我变了，快刷新！”
        objectWillChange.send()
    }

    func updateUserTalkingState(userSession: UInt, talkState: MKTalkState) {
        guard let index = userIndexMap[userSession], index < modelItems.count else {
            return
        }
        let item = modelItems[index]

        let isServerMuted = item.state?.isMutedByServer ?? false
        let isSelfMuted = item.state?.isSelfMuted ?? false
        let isSelfDeafened = item.state?.isSelfDeafened ?? false

        // 如果是因为这些硬性原因导致无法说话，才强制设为 passive
        if isServerMuted || isSelfMuted || isSelfDeafened {
            item.talkingState = .passive
        } else {
            // 如果只是本地屏蔽 (isLocallyMuted)，继续根据 talkState 更新 UI
            switch talkState.rawValue {
            case 1, 2, 3:
                item.talkingState = .talking
            default:
                item.talkingState = .passive
            }
        }
        objectWillChange.send()
        updateLiveActivity()
    }

    private func updateUserItemState(item: ChannelNavigationItem, user: MKUser) {
        let state = UserState(
            isAuthenticated: user.isAuthenticated(),
            isSelfDeafened: user.isSelfDeafened(),
            isSelfMuted: user.isSelfMuted(),
            isMutedByServer: user.isMuted(),
            isDeafenedByServer: user.isDeafened(),
            isLocallyMuted: user.isLocalMuted(),
            isSuppressed: user.isSuppressed(),
            isPrioritySpeaker: user.isPrioritySpeaker()
        )
        item.state = state

        // 初始化 mute/deafen 状态追踪（首次见到用户时记录，不触发通知）
        if previousMuteStates[user.session()] == nil {
            previousMuteStates[user.session()] = (
                isSelfMuted: user.isSelfMuted(),
                isSelfDeafened: user.isSelfDeafened()
            )
        }

        updateUserTalkingState(
            userSession: user.session(),
            talkState: user.talkState()
        )

        if let connectedUser = serverModel?.connectedUser(),
           connectedUser.session() == user.session() {
            item.isConnectedUser = true
            // 同步认证状态到 AppState，供 macOS 菜单栏等全局 UI 使用
            AppState.shared.isUserAuthenticated = user.isAuthenticated()
        } else {
            item.isConnectedUser = false
        }
    }

    func updateChannelName(channelId: UInt, newName: String) {
        if let index = channelIndexMap[channelId],
           index < modelItems.count {
            let item = modelItems[index]
            let newItem = ChannelNavigationItem(
                title: newName,
                subtitle: item.subtitle,
                type: item.type,
                indentLevel: item.indentLevel,
                object: item.object
            )
            modelItems[index] = newItem
        }
        updateLiveActivity()
    }

    func rebuildModelArray() {
        guard let serverModel = serverModel else {
            return
        }

        modelItems = []
        userIndexMap = [:]
        channelIndexMap = [:]

        if viewMode == .server {
            if let rootChannel = serverModel.rootChannel() {
                addChannelTreeToModel(channel: rootChannel, indentLevel: 0)
            }
        } else if let connectedUser = serverModel.connectedUser(),
                  let currentChannel = connectedUser.channel(),
                  let usersArray = currentChannel.users(),
                  let users = usersArray as? [MKUser] {
            for (index, user) in users.enumerated() {
                applySavedUserPreferences(user: user)

                let userName = user.userName() ?? "Unknown User"
                let item = ChannelNavigationItem(
                    title: userName,
                    subtitle: "in \(currentChannel.channelName() ?? "Unknown Channel")",
                    type: .user,
                    indentLevel: 0,
                    object: user
                )
                updateUserItemState(item: item, user: user)
                modelItems.append(item)
                userIndexMap[user.session()] = index
            }
        }

        updateLiveActivity()
    }

    private func addChannelTreeToModel(channel: MKChannel, indentLevel: Int) {
        let channelName = channel.channelName() ?? "Unknown Channel"
        let channelDescription = channel.channelDescription()
        let channelItem = ChannelNavigationItem(
            title: channelName,
            subtitle: channelDescription,
            type: .channel,
            indentLevel: indentLevel,
            object: channel
        )

        if let connectedUser = serverModel?.connectedUser(),
           let userChannel = connectedUser.channel(),
           userChannel.channelId() == channel.channelId() {
            channelItem.isConnectedUserChannel = true
        }

        if let usersArray = channel.users(),
           let rawUsers = usersArray as? [MKUser] {
            channelItem.userCount = rawUsers.count
            channelIndexMap[channel.channelId()] = modelItems.count
            modelItems.append(channelItem)

            for user in rawUsers {
                // 顺便确保配置被应用 (之前的修复)
                applySavedUserPreferences(user: user)

                let userName = user.userName() ?? "Unknown User"
                let userItem = ChannelNavigationItem(
                    title: userName,
                    subtitle: "in \(channelName)",
                    type: .user,
                    indentLevel: indentLevel + 1,
                    object: user
                )
                updateUserItemState(item: userItem, user: user)
                userIndexMap[user.session()] = modelItems.count
                modelItems.append(userItem)
            }
        } else {
            // 没有用户的情况
            channelItem.userCount = 0
            channelIndexMap[channel.channelId()] = modelItems.count
            modelItems.append(channelItem)
        }

        if let channelsArray = channel.channels(),
           let subChannels = channelsArray as? [MKChannel] {
            for subChannel in subChannels {
                addChannelTreeToModel(channel: subChannel, indentLevel: indentLevel + 1)
            }
        }
    }

    func joinChannel(_ channel: MKChannel) {
        serverModel?.join(channel)
    }

    var connectedUserState: UserState? {
        guard let connectedUserItem = modelItems.first(where: { $0.isConnectedUser }) else {
            return nil
        }
        return connectedUserItem.state
    }

    func toggleChannelCollapse(_ channelId: Int) {
        if collapsedChannelIds.contains(channelId) {
            collapsedChannelIds.remove(channelId)
        } else {
            collapsedChannelIds.insert(channelId)
        }
    }

    func isChannelCollapsed(_ channelId: Int) -> Bool {
        collapsedChannelIds.contains(channelId)
    }

    // 辅助方法：获取排序后的子频道
    func getSortedSubChannels(for channel: MKChannel) -> [MKChannel] {
        guard let subChannels = channel.channels() as? [MKChannel] else { return [] }
        return subChannels.sorted { c1, c2 in
            if c1.position() != c2.position() {
                return c1.position() < c2.position()
            }
            return (c1.channelName() ?? "") < (c2.channelName() ?? "")
        }
    }

    // 辅助方法：获取排序后的用户
    func getSortedUsers(for channel: MKChannel) -> [MKUser] {
        guard let users = channel.users() as? [MKUser] else { return [] }

        let validatedUsers = users.filter { user in
            user.channel()?.channelId() == channel.channelId()
        }

        return validatedUsers.sorted { u1, u2 in
            (u1.userName() ?? "") < (u2.userName() ?? "")
        }
    }
}
