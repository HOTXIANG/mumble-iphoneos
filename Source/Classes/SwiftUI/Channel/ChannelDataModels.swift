// 文件: ChannelDataModels.swift (已修复)

import SwiftUI

// 1. 我们需要重新引入一个简化的讲话状态枚举
enum TalkingState {
    case passive
    case talking
    // MumbleKit 中还有 a, 但为了简化UI，我们只区分"在讲话"和"没讲话"
}

// 2. UserState 结构体保持不变
struct UserState {
    let isAuthenticated: Bool; let isSelfDeafened: Bool; let isSelfMuted: Bool; let isMutedByServer: Bool; let isDeafenedByServer: Bool; let isLocallyMuted: Bool; let isSuppressed: Bool; let isPrioritySpeaker: Bool
    var isMutedOrDeafened: Bool {
        isSelfMuted || isMutedByServer || isLocallyMuted || isSuppressed || isSelfDeafened || isDeafenedByServer
    }
}

// 3. ChannelNavigationItem 中添加 talkingState 属性
class ChannelNavigationItem: ObservableObject, Identifiable {
    let id = UUID(); let title: String; let subtitle: String?; let type: ItemType; let indentLevel: Int; let object: Any
    
    @Published var isConnectedUserChannel: Bool = false
    @Published var isConnectedUser: Bool = false
    @Published var userCount: Int = 0
    @Published var state: UserState? = nil
    
    // --- 核心修改：添加 talkingState 属性 ---
    @Published var talkingState: TalkingState = .passive
    
    enum ItemType {
        case channel,
             user
    }
    
    init(
        title: String,
        subtitle: String?,
        type: ItemType,
        indentLevel: Int,
        object: Any
    ) {
        self.title = title; self.subtitle = subtitle; self.type = type; self.indentLevel = indentLevel; self.object = object
    }
    
    var isChannel: Bool {
        return type == .channel
    }; var isUser: Bool {
        return type == .user
    }
    var objectId: UInt {
        if let channel = object as? MKChannel {
            return channel.channelId()
        } else if let user = object as? MKUser {
            return user.session()
        }; return 0
    }
}

// ChannelNavigationConfig 保持不变
struct ChannelNavigationConfig: NavigationConfigurable {
    let onMenu: () -> Void; let onModeSwitch: () -> Void; var title: String {
        return "Mumble Channel"
    }; var leftBarItems: [NavigationBarItem] {
        return [NavigationBarItem(
            systemImage: "chevron.left",
            action: onModeSwitch
        )]
    }; var rightBarItems: [NavigationBarItem] {
        return [NavigationBarItem(
            systemImage: "line.horizontal.3",
            action: onMenu
        )]
    }
}

// 1. 定义一个新的枚举来表示消息的类型
enum ChatMessageType {
    case userMessage      // 普通的用户聊天消息
    case notification     // 系统通知，例如"加入频道"
    case privateMessage   // 私聊消息
}

// 2. 为 ChatMessage 结构体添加一个新的 type 属性
struct ChatMessage: Identifiable, Equatable {
    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id
    }
    
    let id: UUID
    let type: ChatMessageType
    let senderName: String
    let attributedMessage: AttributedString
    let images: [PlatformImage]
    let timestamp: Date
    let isSentBySelf: Bool
    /// 私聊对方的名称（收到时为发送者名，发出时为接收者名）
    let privatePeerName: String?
    
    init(id: UUID = UUID(), type: ChatMessageType, senderName: String, attributedMessage: AttributedString, images: [PlatformImage] = [], timestamp: Date = Date(), isSentBySelf: Bool, privatePeerName: String? = nil) {
        self.id = id
        self.type = type
        self.senderName = senderName
        self.attributedMessage = attributedMessage
        self.images = images
        self.timestamp = timestamp
        self.isSentBySelf = isSentBySelf
        self.privatePeerName = privatePeerName
    }
    
    // 为了方便，我们保留一个纯文本的计算属性
    var plainTextMessage: String {
        return attributedMessage.description
    }
}
