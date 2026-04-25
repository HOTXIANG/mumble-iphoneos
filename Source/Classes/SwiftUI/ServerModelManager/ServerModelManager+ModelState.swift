//
//  ServerModelManager+ModelState.swift
//  Mumble
//

import SwiftUI
import QuartzCore

extension ServerModelManager {
    func requestModelRebuild(reason: String, debounce: TimeInterval = 0.08) {
        pendingModelRebuildWorkItem?.cancel()
        pendingModelRebuildReason = reason

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.rebuildModelArray(reason: self.pendingModelRebuildReason)
            self.pendingModelRebuildWorkItem = nil
        }
        pendingModelRebuildWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    func updateUserBySession(_ session: UInt) {
        guard let index = userIndexMap[session],
              index < modelItems.count,
              let user = modelItems[index].object as? MKUser else {
            return
        }
        if let channelId = user.channel()?.channelId() {
            lastKnownChannelIdByUserSession[session] = channelId
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
                let nameStr = displayName(for: user)
                let displayStr = isSelf
                    ? NSLocalizedString("You", comment: "")
                    : nameStr

                if prev.isSelfDeafened != currentDeafened {
                    // 不听状态变化（优先级高于闭麦，因为 deafen 隐含 mute）
                    let key = currentDeafened ? "%@ deafened" : "%@ undeafened"
                    addSystemNotification(
                        String(format: NSLocalizedString(key, comment: ""), displayStr),
                        category: .muteDeafen,
                        suppressPush: isSelf
                    )
                } else if prev.isSelfMuted != currentMuted {
                    // 闭麦状态变化
                    let key = currentMuted ? "%@ muted" : "%@ unmuted"
                    addSystemNotification(
                        String(format: NSLocalizedString(key, comment: ""), displayStr),
                        category: .muteDeafen,
                        suppressPush: isSelf
                    )
                }
            }
        }
        previousMuteStates[session] = (isSelfMuted: currentMuted, isSelfDeafened: currentDeafened)

        // 更新 item 的状态
        updateUserItemState(
            item: modelItems[index],
            user: user
        )

        // 不再触发全局 objectWillChange，避免频道树整体重绘导致菜单滚动位置丢失。
        // 用户行通过 userStateUpdatedNotification 做行级刷新。
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
        if !isBulkUpdatingModelItems {
            updateLiveActivity(syncHandoffAudioState: false)
        }
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
            isPrioritySpeaker: user.isPrioritySpeaker(),
            isRecording: user.isRecording()
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

    func rebuildModelArray(reason: String = "direct") {
        let startedAt = CACurrentMediaTime()
        guard let serverModel = serverModel else {
            return
        }

        isBulkUpdatingModelItems = true
        deferredAvatarRefreshSessions.removeAll(keepingCapacity: true)
        defer {
            isBulkUpdatingModelItems = false
        }

        modelItems = []
        userIndexMap = [:]
        channelIndexMap = [:]

        if viewMode == .server {
            if let rootChannel = serverModel.rootChannel() {
                let serverHost = serverModel.hostname() ?? ""
                
                // First, add pinned channels at the top level
                let pinnedIds = ChannelFilterManager.shared.getPinnedChannels(serverHost: serverHost)
                for pinnedId in pinnedIds.sorted() {
                    guard let pinnedChan = serverModel.channel(withId: UInt(pinnedId)),
                          pinnedChan.channelId() != rootChannel.channelId() else { continue }

                    // 如果其父频道也被置顶，则由父频道递归展示，避免重复
                    if let parent = pinnedChan.parent(),
                       pinnedIds.contains(parent.channelId()) {
                        continue
                    }

                    if !ChannelFilterManager.shared.isHidden(id: pinnedChan.channelId(), serverHost: serverHost) ||
                        UserDefaults.standard.bool(forKey: "ShowHiddenChannels") {
                        addChannelTreeToModel(channel: pinnedChan, indentLevel: 0, isTraversingPinnedTree: true)
                    }
                }
                
                // Then, add the normal tree
                addChannelTreeToModel(channel: rootChannel, indentLevel: 0, isTraversingPinnedTree: false)
            }
        } else if let connectedUser = serverModel.connectedUser(),
                  let currentChannel = connectedUser.channel(),
                  let usersArray = currentChannel.users(),
                  let users = usersArray as? [MKUser] {
            for (index, user) in users.enumerated() {
                deferAvatarRefreshAfterRebuild(for: user)

                let userName = displayName(for: user)
                let channelName = currentChannel.channelName() ?? NSLocalizedString("Unknown Channel", comment: "")
                let item = ChannelNavigationItem(
                    title: userName,
                    subtitle: String(format: NSLocalizedString("in %@", comment: ""), channelName),
                    type: .user,
                    indentLevel: 0,
                    object: user
                )
                updateUserItemState(item: item, user: user)
                modelItems.append(item)
                userIndexMap[user.session()] = index
                lastKnownChannelIdByUserSession[user.session()] = currentChannel.channelId()
            }
        }

        updateLiveActivity()
        scheduleDeferredAvatarRefresh()

        let elapsedMs = (CACurrentMediaTime() - startedAt) * 1000.0
        MumbleLogger.model.debug("PERF rebuild_model_array reason=\(reason) items=\(self.modelItems.count) elapsed_ms=\(String(format: "%.2f", elapsedMs))")
    }

    private func deferAvatarRefreshAfterRebuild(for user: MKUser) {
        deferredAvatarRefreshSessions.insert(user.session())
    }

    private func scheduleDeferredAvatarRefresh() {
        let sessions = Array(deferredAvatarRefreshSessions)
        deferredAvatarRefreshSessions.removeAll(keepingCapacity: true)
        guard !sessions.isEmpty else { return }

        pendingAvatarRefreshTask?.cancel()
        pendingAvatarRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }

            for (index, session) in sessions.enumerated() {
                if index > 0 && index % 8 == 0 {
                    try? await Task.sleep(nanoseconds: 40_000_000)
                }
                guard !Task.isCancelled else { return }
                if let user = self.serverModel?.user(withSession: session) {
                    self.updateAvatarCache(for: user)
                }
            }
            self.pendingAvatarRefreshTask = nil
        }
    }

    private func addChannelTreeToModel(channel: MKChannel, indentLevel: Int, isTraversingPinnedTree: Bool = false) {
        let serverHost = serverModel?.hostname() ?? ""
        let channelId = channel.channelId()
        
        // Skip hidden channels
        let showHidden = UserDefaults.standard.bool(forKey: "ShowHiddenChannels")
        if !showHidden && ChannelFilterManager.shared.isHidden(id: channelId, serverHost: serverHost) {
            return
        }
        
        // Skip pinned channels during normal traversal (to avoid duplicating them),
        // except when explicitly traversing the pinned tree itself.
        if !isTraversingPinnedTree && channel.parent() != nil && ChannelFilterManager.shared.isPinned(id: channelId, serverHost: serverHost) {
            return
        }

        let channelName = channel.channelName() ?? NSLocalizedString("Unknown Channel", comment: "")
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
                deferAvatarRefreshAfterRebuild(for: user)

                let userName = displayName(for: user)
                let userItem = ChannelNavigationItem(
                    title: userName,
                    subtitle: String(format: NSLocalizedString("in %@", comment: ""), channelName),
                    type: .user,
                    indentLevel: indentLevel + 1,
                    object: user
                )
                updateUserItemState(item: userItem, user: user)
                userIndexMap[user.session()] = modelItems.count
                lastKnownChannelIdByUserSession[user.session()] = channel.channelId()
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
                addChannelTreeToModel(channel: subChannel, indentLevel: indentLevel + 1, isTraversingPinnedTree: isTraversingPinnedTree)
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
        let serverHost = serverModel?.hostname() ?? ""
        let showHidden = UserDefaults.standard.bool(forKey: "ShowHiddenChannels")

        let visibleChannels = subChannels.filter { subChannel in
            showHidden || !ChannelFilterManager.shared.isHidden(id: subChannel.channelId(), serverHost: serverHost)
        }

        return visibleChannels.sorted { c1, c2 in
            let isPinned1 = ChannelFilterManager.shared.isPinned(id: c1.channelId(), serverHost: serverHost)
            let isPinned2 = ChannelFilterManager.shared.isPinned(id: c2.channelId(), serverHost: serverHost)
            if isPinned1 != isPinned2 {
                return isPinned1 && !isPinned2
            }
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
            self.displayName(for: u1) < self.displayName(for: u2)
        }
    }
}
