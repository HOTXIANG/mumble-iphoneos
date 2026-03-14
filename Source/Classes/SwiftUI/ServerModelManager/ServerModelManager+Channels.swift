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
    
    /// 移动频道到新的父频道
    func moveChannel(_ channel: MKChannel, to parent: MKChannel) {
        serverModel?.move(channel, toParent: parent)
    }

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
        let isAlreadyListening = listeningChannels.contains(channelId)
        let isPendingAdd = pendingListeningAdds.contains(channelId)
        let isPendingRemove = pendingListeningRemoves.contains(channelId)
        guard (!isAlreadyListening || isPendingRemove) && !isPendingAdd else { return }

        pendingListeningRemoves.remove(channelId)
        pendingListeningAdds.insert(channelId)

        if isChannelCollapsed(Int(channelId)) {
            toggleChannelCollapse(Int(channelId))
        }
        serverModel?.addListening(channel)
    }

    /// 停止监听某频道
    func stopListening(to channel: MKChannel) {
        let channelId = channel.channelId()
        let isListening = listeningChannels.contains(channelId)
        let isPendingAdd = pendingListeningAdds.contains(channelId)
        let isPendingRemove = pendingListeningRemoves.contains(channelId)
        guard (isListening || isPendingAdd) && !isPendingRemove else { return }

        pendingListeningAdds.remove(channelId)
        pendingListeningRemoves.insert(channelId)

        serverModel?.removeListening(channel)
    }

    /// 获取某频道的所有监听者用户对象
    func getListeners(for channel: MKChannel) -> [MKUser] {
        guard let sessions = channelListeners[channel.channelId()] else { return [] }
        return sessions.compactMap { session in
            serverModel?.user(withSession: session)
        }
    }

    func addListenerSession(_ session: UInt, to channelId: UInt) {
        var listeners = channelListeners[channelId] ?? Set()
        let inserted = listeners.insert(session).inserted
        if inserted || channelListeners[channelId] == nil {
            channelListeners[channelId] = listeners
        }
    }

    func removeListenerSession(_ session: UInt, from channelId: UInt) {
        guard var listeners = channelListeners[channelId] else { return }
        let removed = listeners.remove(session) != nil
        guard removed else { return }

        if listeners.isEmpty {
            channelListeners.removeValue(forKey: channelId)
        } else {
            channelListeners[channelId] = listeners
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

    // MARK: - Kick/Ban Operations

    /// 踢出用户（管理员操作，需要 Kick 权限）
    func kickUser(_ user: MKUser, reason: String? = nil) {
        serverModel?.kick(user, forReason: reason)
    }

    /// 封禁用户（管理员操作，需要 Ban 权限）
    func banUser(_ user: MKUser, reason: String? = nil) {
        serverModel?.ban(user, forReason: reason)
    }

    // MARK: - Channel Link Operations

    /// 链接两个频道（管理员操作，需要 LinkChannel 权限）
    func linkChannel(_ channel: MKChannel, to target: MKChannel) {
        serverModel?.linkChannel(channel, to: target)
    }

    /// 取消两个频道的链接
    func unlinkChannel(_ channel: MKChannel, from target: MKChannel) {
        serverModel?.unlinkChannel(channel, from: target)
    }

    /// 取消频道的所有链接
    func unlinkAllForChannel(_ channel: MKChannel) {
        serverModel?.unlinkAll(for: channel)
    }

    // MARK: - Priority Speaker

    /// 设置优先说话者状态（管理员操作）
    func setPrioritySpeaker(_ prioritySpeaker: Bool, for user: MKUser) {
        serverModel?.setPrioritySpeaker(prioritySpeaker, for: user)
    }

    // MARK: - User Comment Reset

    /// 重置其他用户的评论（管理员操作）
    func resetUserComment(for user: MKUser) {
        serverModel?.setSelfComment("")
    }

    // MARK: - Ban List Operations

    /// 请求服务器的封禁列表
    func requestBanList() {
        serverModel?.requestBanList()
    }

    /// 发送更新后的封禁列表到服务器
    func sendBanList(_ entries: [Any]) {
        serverModel?.sendBanList(entries)
    }

    // MARK: - Registered User List

    /// 请求注册用户列表
    func requestRegisteredUserList() {
        serverModel?.requestUserList()
    }

    // MARK: - User Stats

    /// 请求用户统计信息
    func requestUserStats(for user: MKUser) {
        serverModel?.requestStats(for: user)
    }

    // MARK: - User Texture

    /// 设置当前用户的头像
    func setSelfTexture(_ data: Data?) {
        guard let data else {
            serverModel?.setSelfTexture(nil)
            return
        }

        // Server can reject oversized texture payloads. Normalize to JPEG and
        // keep payload bounded for broad server compatibility.
        let normalized = normalizedTexturePayload(from: data) ?? data
        serverModel?.setSelfTexture(normalized)
    }

    /// 移除当前用户的头像
    func removeSelfTexture() {
        serverModel?.setSelfTexture(nil)
    }

    /// 获取用户头像（已缓存）
    func avatarImage(for session: UInt?) -> PlatformImage? {
        guard let session else { return nil }
        return userAvatars[session]
    }

    /// 按 session 触发头像加载（如果有 hash 但没有完整头像，会向服务器请求）
    func ensureAvatarLoaded(for session: UInt) {
        guard let user = serverModel?.user(withSession: session) else { return }
        updateAvatarCache(for: user)
    }

    /// 刷新/缓存用户头像（可安全重复调用）
    func updateAvatarCache(for user: MKUser) {
        let session = user.session()
        let textureData = objcData(from: user.texture())

        if let textureData, !textureData.isEmpty, let image = PlatformImage(data: textureData) {
            userAvatars[session] = image
            pendingAvatarFetchSessions.remove(session)
            return
        }

        let hasTextureHash = !(objcData(from: user.textureHash())?.isEmpty ?? true)
        if hasTextureHash {
            requestUserTextureIfNeeded(for: user)
        } else {
            userAvatars.removeValue(forKey: session)
            pendingAvatarFetchSessions.remove(session)
        }
    }

    private func requestUserTextureIfNeeded(for user: MKUser) {
        let session = user.session()
        guard !pendingAvatarFetchSessions.contains(session), let model = serverModel else { return }
        pendingAvatarFetchSessions.insert(session)

        let selector = NSSelectorFromString("requestTextureForUser:")
        if model.responds(to: selector) {
            _ = model.perform(selector, with: user)
        }
    }

    private func objcData(from raw: Any?) -> Data? {
        if let data = raw as? Data {
            return data
        }
        if let data = raw as? NSData {
            return data as Data
        }
        return nil
    }

    private func normalizedTexturePayload(from data: Data) -> Data? {
        guard let image = PlatformImage(data: data) else {
            return nil
        }

        let maxBytes = effectiveTextureUploadLimitBytes()
        if let direct = image.jpegData(compressionQuality: 0.92), direct.count <= maxBytes {
            return direct
        }

        #if os(iOS)
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        #else
        let pixelWidth = image.size.width
        let pixelHeight = image.size.height
        #endif
        let maxDim = max(pixelWidth, pixelHeight)

        var tiers: [CGFloat] = [maxDim]
        for dim in [1024, 768, 512, 384, 256] as [CGFloat] where dim < maxDim {
            tiers.append(dim)
        }

        for tier in tiers {
            let working = tier < maxDim ? resizeTextureImage(image: image, maxDimension: tier) : image

            var low: CGFloat = 0.2
            var high: CGFloat = 0.92
            var bestData: Data?

            for _ in 0..<8 {
                let quality = (low + high) / 2
                guard let encoded = working.jpegData(compressionQuality: quality) else {
                    break
                }
                if encoded.count <= maxBytes {
                    bestData = encoded
                    low = quality
                } else {
                    high = quality
                }
            }

            if let bestData {
                return bestData
            }
        }

        let fallback = resizeTextureImage(image: image, maxDimension: 256)
        return fallback.jpegData(compressionQuality: 0.25)
    }

    private func effectiveTextureUploadLimitBytes() -> Int {
        // Use a conservative fallback when server config is not available.
        let fallback = 64 * 1024
        guard let serverLimit = serverImageMessageLengthBytes, serverLimit > 0 else {
            return fallback
        }

        // Keep margin for protobuf framing and metadata, while preserving a floor.
        let withMargin = max(12 * 1024, serverLimit - 4 * 1024)
        return min(withMargin, 512 * 1024)
    }

    private func resizeTextureImage(image: PlatformImage, maxDimension: CGFloat) -> PlatformImage {
        #if os(iOS)
        let pixelW = image.size.width * image.scale
        let pixelH = image.size.height * image.scale
        #else
        let pixelW = image.size.width
        let pixelH = image.size.height
        #endif

        let currentMax = max(pixelW, pixelH)
        guard currentMax > maxDimension else { return image }

        let ratio = maxDimension / currentMax
        let newSize = CGSize(width: floor(pixelW * ratio), height: floor(pixelH * ratio))

        #if os(iOS)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: newSize))
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        #else
        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSColor.white.setFill()
        NSRect(origin: .zero, size: newSize).fill()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .sourceOver,
                   fraction: 1.0)
        newImage.unlockFocus()
        return newImage
        #endif
    }
}
