//
//  ServerModelManager+Channels.swift
//  Mumble
//

import SwiftUI

extension ServerModelManager {
    // MARK: - User Movement

    /// 移动用户到指定频道
    func moveUser(_ user: MKUser, toChannel channel: MKChannel) {
        serverModel?.move(user, to: channel)
    }

    /// 通过 session ID 移动用户到指定频道 ID
    func moveUser(session: UInt, toChannelId channelId: UInt) {
        guard let user = getUserBySession(session),
              let channel = serverModel?.channel(withId: channelId) else { return }
        serverModel?.move(user, to: channel)
    }

    // MARK: - Channel Management

    /// 创建新频道
    func createChannel(name: String, parent: MKChannel, temporary: Bool) {
        serverModel?.createChannel(withName: name, parent: parent, temporary: temporary)
    }

    /// 删除频道
    func removeChannel(_ channel: MKChannel) {
        serverModel?.remove(channel)
    }

    /// 编辑频道属性
    func editChannel(_ channel: MKChannel, name: String?, description: String?, position: NSNumber?, maxUsers: NSNumber? = nil) {
        serverModel?.edit(channel, name: name, description: description, position: position, maxUsers: maxUsers)
    }

    // MARK: - ACL Management

    /// 请求频道的 ACL 数据
    func requestACL(for channel: MKChannel) {
        serverModel?.requestAccessControl(for: channel)
    }

    /// 设置频道的 ACL 数据
    func setACL(_ accessControl: MKAccessControl, for channel: MKChannel) {
        serverModel?.setAccessControl(accessControl, for: channel)
    }

    /// 请求离线已注册用户的用户名（用于 ACL 显示）
    func requestACLUserNames(for userIds: [Int]) {
        let uniqueIds = Set(userIds.filter { $0 >= 0 })
        let idsToQuery = uniqueIds.filter { aclUserNamesById[$0] == nil && !pendingACLUserNameQueries.contains($0) }
        guard !idsToQuery.isEmpty else { return }

        pendingACLUserNameQueries.formUnion(idsToQuery)
        let payload = idsToQuery.sorted().map { NSNumber(value: $0) }
        serverModel?.queryUserNames(forIds: payload)
    }

    /// ACL 专用：优先返回在线用户名，其次返回离线缓存，最后回退 User #id
    func aclUserDisplayName(for userId: Int) -> String {
        for item in modelItems {
            if item.type == .user, let user = item.object as? MKUser, Int(user.userId()) == userId {
                return user.userName() ?? "User #\(userId)"
            }
        }
        if let cached = aclUserNamesById[userId], !cached.isEmpty {
            return cached
        }
        return "User #\(userId)"
    }

    // MARK: - Password Channel Management

    /// 检测 ACL 中是否包含密码模式（deny Enter @all + grant Enter #token）
    func updatePasswordStatus(for channel: MKChannel, from accessControl: MKAccessControl) {
        let channelId = channel.channelId()
        guard let acls = accessControl.acls else {
            channelsWithPassword.remove(channelId)
            return
        }

        var hasDenyEnterAll = false
        var hasGrantEnterToken = false

        for item in acls {
            guard let aclItem = item as? MKChannelACL, !aclItem.inherited else { continue }
            if aclItem.group == "all" && (aclItem.deny.rawValue & MKPermissionEnter.rawValue) != 0 {
                hasDenyEnterAll = true
            }
            if let group = aclItem.group, group.hasPrefix("#") && !group.hasPrefix("#!"),
               (aclItem.grant.rawValue & MKPermissionEnter.rawValue) != 0 {
                hasGrantEnterToken = true
            }
        }

        if hasDenyEnterAll && hasGrantEnterToken {
            channelsWithPassword.insert(channelId)
        } else {
            channelsWithPassword.remove(channelId)
        }
    }

    /// 标记频道为有密码
    func markChannelHasPassword(_ channelId: UInt) {
        channelsWithPassword.insert(channelId)
    }

    /// 设置 access token 并尝试加入频道
    func submitPasswordAndJoin(channel: MKChannel, password: String) {
        var tokens = currentAccessTokens
        if !tokens.contains(password) {
            tokens.append(password)
        }
        currentAccessTokens = tokens
        serverModel?.setAccessTokens(tokens)

        pendingPasswordChannelId = channel.channelId()
        markUserInitiatedJoin(channelId: channel.channelId())

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.serverModel?.join(channel)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.pendingPasswordChannelId = nil
            }
        }
    }

    /// 标记用户主动加入某频道（外部调用）
    func markUserInitiatedJoin(channelId: UInt) {
        userInitiatedJoinChannelId = channelId
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            if self?.userInitiatedJoinChannelId == channelId {
                self?.userInitiatedJoinChannelId = nil
            }
        }
    }

    // MARK: - Channel Listening

    /// 重连后恢复之前保存的监听频道
    func reRegisterListeningChannels() {
        guard !savedListeningChannelIds.isEmpty else { return }
        print("🔄 Re-registering \(savedListeningChannelIds.count) listening channels after reconnect")
        for channelId in savedListeningChannelIds {
            if let channel = serverModel?.channel(withId: channelId) {
                startListening(to: channel)
                print("  👂 Re-registered listening on channel: \(channel.channelName() ?? "?")")
            } else {
                print("  ⚠️ Channel \(channelId) no longer exists, skipping")
            }
        }
        savedListeningChannelIds.removeAll()
    }

    /// 开始监听某频道（接收其音频，不加入）
    func startListening(to channel: MKChannel) {
        let channelId = channel.channelId()
        serverModel?.addListening(channel)
        listeningChannels.insert(channelId)
        if let mySession = serverModel?.connectedUser()?.session() {
            var listeners = channelListeners[channelId] ?? Set()
            listeners.insert(mySession)
            channelListeners[channelId] = listeners
        }
        if isChannelCollapsed(Int(channelId)) {
            toggleChannelCollapse(Int(channelId))
        }
        rebuildModelArray()
    }

    /// 停止监听某频道
    func stopListening(to channel: MKChannel) {
        let channelId = channel.channelId()
        serverModel?.removeListening(channel)
        listeningChannels.remove(channelId)
        if let mySession = serverModel?.connectedUser()?.session() {
            channelListeners[channelId]?.remove(mySession)
            if channelListeners[channelId]?.isEmpty == true {
                channelListeners.removeValue(forKey: channelId)
            }
        }
        rebuildModelArray()
    }

    /// 获取某频道的所有监听者用户对象
    func getListeners(for channel: MKChannel) -> [MKUser] {
        guard let sessions = channelListeners[channel.channelId()] else { return [] }
        return sessions.compactMap { session in
            serverModel?.user(withSession: session)
        }
    }

    // MARK: - Server-side Mute

    /// 服务器端静音某用户（管理员操作）
    func setServerMuted(_ muted: Bool, for user: MKUser) {
        serverModel?.setServerMuted(muted, for: user)
    }

    /// 服务器端耳聋某用户（管理员操作）
    /// - deafen 时同时 mute
    /// - undeafen 时如果用户在 deafen 之前没有被单独 mute，也同时 unmute
    func setServerDeafened(_ deafened: Bool, for user: MKUser) {
        let session = user.session()
        if deafened {
            wasMutedBeforeServerDeafen[session] = user.isMuted()
            serverModel?.setServerMuted(true, for: user)
            serverModel?.setServerDeafened(true, for: user)
        } else {
            serverModel?.setServerDeafened(false, for: user)
            let wasMuted = wasMutedBeforeServerDeafen[session] ?? false
            if !wasMuted {
                serverModel?.setServerMuted(false, for: user)
            }
            wasMutedBeforeServerDeafen.removeValue(forKey: session)
        }
    }
}
