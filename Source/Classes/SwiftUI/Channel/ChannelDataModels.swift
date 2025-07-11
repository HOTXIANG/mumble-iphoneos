// 文件: ChannelDataModels.swift (已修复)

import SwiftUI

// 1. 我们需要重新引入一个简化的讲话状态枚举
enum TalkingState {
    case passive
    case talking
    // MumbleKit 中还有 a, 但为了简化UI，我们只区分“在讲话”和“没讲话”
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

// 新的消息数据模型，用于 SwiftUI 视图
struct ChatMessage: Identifiable, Equatable {
    // --- 核心修改：确保 id 属性存在 ---
    let id: UUID
    
    let senderName: String
    let message: String
    let images: [UIImage]
    let timestamp: Date
    let isSentBySelf: Bool
}
