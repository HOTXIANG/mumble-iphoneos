// 文件: ServerModelNotificationManager.swift (已更新)

import Foundation

class ServerModelNotificationManager {
    nonisolated(unsafe) static let shared = ServerModelNotificationManager()
    private init() {}
    
    // --- 核心修改 1：添加一个新的通知名称 ---
    static let userMovedNotification = Notification.Name("ServerModelUserMovedNotification")
    
    static let textMessageReceivedNotification = Notification.Name("ServerModelTextMessageReceived")
    static let userStateUpdatedNotification = Notification.Name("ServerModelUserStateUpdated")
    static let rebuildModelNotification = Notification.Name("ServerModelShouldRebuild")
    static let userTalkStateChangedNotification = Notification.Name("ServerModelUserTalkStateChanged")
    static let channelRenamedNotification = Notification.Name("ServerModelChannelRenamed")
    static let userJoinedNotification = Notification.Name("ServerModelUserJoinedNotification")
    static let userLeftNotification = Notification.Name("ServerModelUserLeftNotification")
    static let privateMessageReceivedNotification = Notification.Name("ServerModelPrivateMessageReceived")
    static let userCommentChangedNotification = Notification.Name("ServerModelUserCommentChanged")
    static let channelDescriptionChangedNotification = Notification.Name("ServerModelChannelDescriptionChanged")
    static let aclReceivedNotification = Notification.Name("ServerModelACLReceived")
    static let permissionDeniedNotification = Notification.Name("ServerModelPermissionDenied")
    static let channelAddedNotification = Notification.Name("ServerModelChannelAdded")
    static let channelRemovedNotification = Notification.Name("ServerModelChannelRemoved")
    static let permissionQueryResultNotification = Notification.Name("ServerModelPermissionQueryResult")
    
    // --- 核心修改 2：添加一个发送新通知的方法 ---
    func postUserMoved(user: MKUser, to channel: MKChannel, by mover: MKUser? = nil) {
        var userInfo: [String: Any] = ["user": user, "channel": channel]
        if let mover = mover { userInfo["mover"] = mover }
        NotificationCenter.default.post(name: Self.userMovedNotification, object: nil, userInfo: userInfo)
    }
    
    func postUserJoined(user: MKUser) {
        let userInfo: [String: Any] = ["user": user]
        NotificationCenter.default.post(name: Self.userJoinedNotification, object: nil, userInfo: userInfo)
    }
    
    func postUserLeft(user: MKUser) {
        let userInfo: [String: Any] = ["user": user]
        NotificationCenter.default.post(name: Self.userLeftNotification, object: nil, userInfo: userInfo)
    }
    
    func postTextMessageReceived(_ message: MKTextMessage, from user: MKUser) {
        let userInfo: [String: Any] = ["message": message, "user": user]
        NotificationCenter.default.post(name: Self.textMessageReceivedNotification, object: nil, userInfo: userInfo)
    }

    func postUserStateUpdated(userSession: UInt) { NotificationCenter.default.post(name: Self.userStateUpdatedNotification, object: nil, userInfo: ["userSession": userSession]) }
    func postRebuildNotification() { NotificationCenter.default.post(name: Self.rebuildModelNotification, object: nil) }
    func postUserTalkStateChanged(userSession: UInt, talkState: MKTalkState) { let userInfo: [String: Any] = ["userSession": userSession, "talkState": talkState]; NotificationCenter.default.post(name: Self.userTalkStateChangedNotification, object: nil, userInfo: userInfo) }
    func postChannelRenamed(channelId: UInt, newName: String) { let userInfo: [String: Any] = ["channelId": channelId, "newName": newName]; NotificationCenter.default.post(name: Self.channelRenamedNotification, object: nil, userInfo: userInfo) }
    
    func postUserCommentChanged(userSession: UInt) {
        NotificationCenter.default.post(name: Self.userCommentChangedNotification, object: nil, userInfo: ["userSession": userSession])
    }
    
    func postChannelDescriptionChanged(channelId: UInt) {
        NotificationCenter.default.post(name: Self.channelDescriptionChangedNotification, object: nil, userInfo: ["channelId": channelId])
    }
    
    func postPrivateMessageReceived(_ message: MKTextMessage, from user: MKUser) {
        let userInfo: [String: Any] = ["message": message, "user": user]
        NotificationCenter.default.post(name: Self.privateMessageReceivedNotification, object: nil, userInfo: userInfo)
    }
    
    func postACLReceived(_ accessControl: MKAccessControl, for channel: MKChannel) {
        let userInfo: [String: Any] = ["accessControl": accessControl, "channel": channel]
        NotificationCenter.default.post(name: Self.aclReceivedNotification, object: nil, userInfo: userInfo)
    }
    
    func postPermissionQueryResult(permissions: UInt32, for channel: MKChannel) {
        let userInfo: [String: Any] = ["permissions": permissions, "channel": channel]
        NotificationCenter.default.post(name: Self.permissionQueryResultNotification, object: nil, userInfo: userInfo)
    }
    
    func postPermissionDenied(permission: MKPermission, user: MKUser?, channel: MKChannel?) {
        var userInfo: [String: Any] = ["permission": permission.rawValue]
        if let user = user { userInfo["user"] = user }
        if let channel = channel { userInfo["channel"] = channel }
        NotificationCenter.default.post(name: Self.permissionDeniedNotification, object: nil, userInfo: userInfo)
    }
    
    func postPermissionDeniedForReason(_ reason: String?) {
        var userInfo: [String: Any] = [:]
        if let reason = reason { userInfo["reason"] = reason }
        NotificationCenter.default.post(name: Self.permissionDeniedNotification, object: nil, userInfo: userInfo)
    }
    
    func postChannelAdded(_ channel: MKChannel) {
        let userInfo: [String: Any] = ["channel": channel]
        NotificationCenter.default.post(name: Self.channelAddedNotification, object: nil, userInfo: userInfo)
    }
    
    func postChannelRemoved(_ channel: MKChannel) {
        let userInfo: [String: Any] = ["channel": channel]
        NotificationCenter.default.post(name: Self.channelRemovedNotification, object: nil, userInfo: userInfo)
    }
}

@objc class ServerModelDelegateWrapper: NSObject, MKServerModelDelegate {
    
    // --- 核心修改 3：让 userMoved 委托方法发送新的、专用的通知 ---
    func serverModel(_ model: MKServerModel, userMoved user: MKUser, to channel: MKChannel, by mover: MKUser?) {
        // 先发送移动通知，用于在聊天框显示提示（包含 mover 信息）
        ServerModelNotificationManager.shared.postUserMoved(user: user, to: channel, by: mover)
        // 再发送重建通知，用于更新频道列表UI
        ServerModelNotificationManager.shared.postRebuildNotification()
    }
    
    func serverModel(_ model: MKServerModel, textMessageReceived msg: MKTextMessage, from user: MKUser) {
            print("✅ DEBUG: Correct delegate method 'textMessageReceived:fromUser:' called.")
            ServerModelNotificationManager.shared.postTextMessageReceived(msg, from: user)
        }
    
    func serverModel(_ model: MKServerModel, userJoined user: MKUser) {
        ServerModelNotificationManager.shared.postUserJoined(user: user)
        ServerModelNotificationManager.shared.postRebuildNotification()
    }
    
    func serverModel(_ model: MKServerModel, userLeft user: MKUser) {
        ServerModelNotificationManager.shared.postUserLeft(user: user)
        ServerModelNotificationManager.shared.postRebuildNotification()
    }
    
    func serverModel(_ model: MKServerModel, userDisconnected user: MKUser) {
        ServerModelNotificationManager.shared.postRebuildNotification()
    }
    
    // --- 所有其他委托方法保持不变，但为了代码整洁，将它们分门别类 ---
    // 列表重建相关的通知
    func serverModel(_ model: MKServerModel, joinedServerAs user: MKUser) { ServerModelNotificationManager.shared.postRebuildNotification() }
    func serverModel(_ model: MKServerModel, channelAdded channel: MKChannel) {
        ServerModelNotificationManager.shared.postChannelAdded(channel)
        ServerModelNotificationManager.shared.postRebuildNotification()
    }
    func serverModel(_ model: MKServerModel, channelRemoved channel: MKChannel) {
        ServerModelNotificationManager.shared.postChannelRemoved(channel)
        ServerModelNotificationManager.shared.postRebuildNotification()
    }
    func serverModel(_ model: MKServerModel, channelMoved channel: MKChannel) { ServerModelNotificationManager.shared.postRebuildNotification() }
    func serverModel(_ model: MKServerModel, userRenamed user: MKUser) { ServerModelNotificationManager.shared.postRebuildNotification() }
    
    // 用户状态更新相关的通知
    func serverModel(_ model: MKServerModel, userSelfMuteDeafenStateChanged user: MKUser) { ServerModelNotificationManager.shared.postUserStateUpdated(userSession: user.session()) }
    func serverModel(_ model: MKServerModel, userMuteStateChanged user: MKUser) { ServerModelNotificationManager.shared.postUserStateUpdated(userSession: user.session()) }
    func serverModel(_ model: MKServerModel, userAuthenticatedStateChanged user: MKUser) { ServerModelNotificationManager.shared.postUserStateUpdated(userSession: user.session()) }
    func serverModel(_ model: MKServerModel, userPrioritySpeakerChanged user: MKUser) { ServerModelNotificationManager.shared.postUserStateUpdated(userSession: user.session()) }
    
    // 讲话状态更新相关的通知
    func serverModel(_ model: MKServerModel, userTalkStateChanged user: MKUser) { ServerModelNotificationManager.shared.postUserTalkStateChanged(userSession: user.session(), talkState: user.talkState()) }
    
    // 频道重命名相关的通知
    func serverModel(_ model: MKServerModel, channelRenamed channel: MKChannel) { ServerModelNotificationManager.shared.postChannelRenamed(channelId: channel.channelId(), newName: channel.channelName() ?? "") }
    
    // 用户评论 / 频道简介变化通知
    func serverModel(_ model: MKServerModel, userCommentChanged user: MKUser) {
        ServerModelNotificationManager.shared.postUserCommentChanged(userSession: user.session())
    }
    
    func serverModel(_ model: MKServerModel, channelDescriptionChanged channel: MKChannel) {
        ServerModelNotificationManager.shared.postChannelDescriptionChanged(channelId: channel.channelId())
    }
    
    func serverModel(_ model: MKServerModel, privateMessageReceived msg: MKTextMessage, from user: MKUser) {
        ServerModelNotificationManager.shared.postPrivateMessageReceived(msg, from: user)
    }
    
    // ACL 相关
    func serverModel(_ model: MKServerModel, didReceive accessControl: MKAccessControl, for channel: MKChannel) {
        ServerModelNotificationManager.shared.postACLReceived(accessControl, for: channel)
    }
    
    // 权限拒绝相关
    func serverModel(_ model: MKServerModel, permissionDenied perm: MKPermission, for user: MKUser, in channel: MKChannel) {
        ServerModelNotificationManager.shared.postPermissionDenied(permission: perm, user: user, channel: channel)
    }
    
    func serverModel(_ model: MKServerModel, permissionDeniedForReason reason: String?) {
        ServerModelNotificationManager.shared.postPermissionDeniedForReason(reason)
    }
    
    // Permission Query 结果
    func serverModel(_ model: MKServerModel, permissionQueryResult permissions: UInt32, for channel: MKChannel) {
        ServerModelNotificationManager.shared.postPermissionQueryResult(permissions: permissions, for: channel)
    }
}
