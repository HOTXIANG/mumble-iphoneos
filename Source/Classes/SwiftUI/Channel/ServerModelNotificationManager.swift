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
    
    // --- 核心修改 2：添加一个发送新通知的方法 ---
    func postUserMoved(user: MKUser, to channel: MKChannel) {
        let userInfo: [String: Any] = ["user": user, "channel": channel]
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
}

@objc class ServerModelDelegateWrapper: NSObject, MKServerModelDelegate {
    
    // --- 核心修改 3：让 userMoved 委托方法发送新的、专用的通知 ---
    func serverModel(_ model: MKServerModel, userMoved user: MKUser, to channel: MKChannel, by mover: MKUser?) {
        // 先发送移动通知，用于在聊天框显示提示
        ServerModelNotificationManager.shared.postUserMoved(user: user, to: channel)
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
    func serverModel(_ model: MKServerModel, channelAdded channel: MKChannel) { ServerModelNotificationManager.shared.postRebuildNotification() }
    func serverModel(_ model: MKServerModel, channelRemoved channel: MKChannel) { ServerModelNotificationManager.shared.postRebuildNotification() }
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
}
