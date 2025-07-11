// 文件: ServerModelNotificationManager.swift (已更新)

import Foundation

class ServerModelNotificationManager {
    nonisolated(unsafe) static let shared = ServerModelNotificationManager()
    private init() {}
    
    // --- 核心修改 1：添加一个用于接收新消息的通知名称 ---
    static let textMessageReceivedNotification = Notification.Name("ServerModelTextMessageReceived")
    
    static let userStateUpdatedNotification = Notification.Name("ServerModelUserStateUpdated")
    static let rebuildModelNotification = Notification.Name("ServerModelShouldRebuild")
    static let userTalkStateChangedNotification = Notification.Name("ServerModelUserTalkStateChanged")
    static let channelRenamedNotification = Notification.Name("ServerModelChannelRenamed")
    
    // --- 核心修改 2：添加一个发送新消息通知的方法 ---
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
    
    // --- 核心修改 3：实现 MumbleKit 接收消息的委托方法 ---
    func serverModel(_ model: MKServerModel, textMessageReceived msg: MKTextMessage, from user: MKUser) {
            print("✅ DEBUG: Correct delegate method 'textMessageReceived:fromUser:' called.")
            ServerModelNotificationManager.shared.postTextMessageReceived(msg, from: user)
        }
    
    // --- 所有其他委托方法保持不变，但为了代码整洁，将它们分门别类 ---
    // 列表重建相关的通知
    func serverModel(_ model: MKServerModel, joinedServerAs user: MKUser) { ServerModelNotificationManager.shared.postRebuildNotification() }
    func serverModel(_ model: MKServerModel, userJoined user: MKUser) { ServerModelNotificationManager.shared.postRebuildNotification() }
    func serverModel(_ model: MKServerModel, userLeft user: MKUser) { ServerModelNotificationManager.shared.postRebuildNotification() }
    func serverModel(_ model: MKServerModel, userDisconnected user: MKUser) { ServerModelNotificationManager.shared.postRebuildNotification() }
    func serverModel(_ model: MKServerModel, userMoved user: MKUser, to channel: MKChannel, by mover: MKUser?) { ServerModelNotificationManager.shared.postRebuildNotification() }
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
