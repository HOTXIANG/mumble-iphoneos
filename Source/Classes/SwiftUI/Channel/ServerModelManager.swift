// 文件: ServerModelManager.swift (已添加 serverName 属性)

import SwiftUI

@MainActor
class ServerModelManager: ObservableObject {
    @Published var modelItems: [ChannelNavigationItem] = []
    @Published var viewMode: ViewMode = .server
    @Published var isConnected: Bool = false
    
    // --- 核心修改 1：添加 @Published 数组来存储聊天消息 ---
    @Published var messages: [ChatMessage] = []
    
    // --- 核心修改 1：添加一个新的 @Published 属性来存储服务器名称 ---
    @Published var serverName: String? = nil
    
    private var muteStateBeforeDeafen: Bool = false
    private var serverModel: MKServerModel?
    private var userIndexMap: [UInt: Int] = [:]
    private var channelIndexMap: [UInt: Int] = [:]
    private var delegateWrapper: ServerModelDelegateWrapper?
    
    enum ViewMode {
        case server,
             channel
    }
    
    init() {
        print(
            "✅ ServerModelManager: INIT (Lazy)"
        )
    }
    func activate() {
        print(
            "🚀 ServerModelManager: ACTIVATE - Activating model and notifications."
        ); setupServerModel(); setupNotifications()
    }
    nonisolated deinit {
        print(
            "🔴 ServerModelManager: DEINIT"
        ); NotificationCenter.default.removeObserver(
            self
        )
    }
    
    private func setupServerModel() {
        if let connectionController = MUConnectionController.shared(), let model = connectionController.serverModel {
            serverModel = model
            delegateWrapper = ServerModelDelegateWrapper()
            model
                .addDelegate(
                    delegateWrapper!
                )
            isConnected = true
            
            // --- 核心修改 2：在模型建立时，为 serverName 赋值 ---
            self.serverName = AppState.shared.serverDisplayName
            
            rebuildModelArray()
        }
    }
    
    func cleanup() {
        print(
            "🧹 ServerModelManager: CLEANUP"
        )
        if let wrapper = delegateWrapper {
            serverModel?
                .removeDelegate(
                    wrapper
                )
        }
        delegateWrapper = nil
        serverModel = nil
        modelItems = []
        userIndexMap = [:]
        channelIndexMap = [:]
        isConnected = false
        
        // --- 核心修改 3：在清理时，重置 serverName ---
        serverName = nil
    }
    
    private nonisolated func setupNotifications() {
        NotificationCenter.default
            .addObserver(
                forName: ServerModelNotificationManager.rebuildModelNotification,
                object: nil,
                queue: nil
            ) {
                [weak self] _ in Task {
                    @MainActor in self?
                        .rebuildModelArray()
                }
            }
        NotificationCenter.default
            .addObserver(
                forName: ServerModelNotificationManager.userStateUpdatedNotification,
                object: nil,
                queue: nil
            ) {
                [weak self] notification in guard let userInfo = notification.userInfo,
                                                  let userSession = userInfo["userSession"] as? UInt else {
                    return
                }; Task {
                    @MainActor in self?
                        .updateUserBySession(
                            userSession
                        )
                }
            }
        NotificationCenter.default
            .addObserver(
                forName: ServerModelNotificationManager.userTalkStateChangedNotification,
                object: nil,
                queue: nil
            ) {
                [weak self] notification in guard let userInfo = notification.userInfo,
                                                  let userSession = userInfo["userSession"] as? UInt,
                                                  let talkState = userInfo["talkState"] as? MKTalkState else {
                    return
                }; Task {
                    @MainActor in self?
                        .updateUserTalkingState(
                            userSession: userSession,
                            talkState: talkState
                        )
                }
            }
        NotificationCenter.default
            .addObserver(
                forName: ServerModelNotificationManager.channelRenamedNotification,
                object: nil,
                queue: nil
            ) {
                [weak self] notification in guard let userInfo = notification.userInfo,
                                                  let channelId = userInfo["channelId"] as? UInt,
                                                  let newName = userInfo["newName"] as? String else {
                    return
                }; Task {
                    @MainActor in self?
                        .updateChannelName(
                            channelId: channelId,
                            newName: newName
                        )
                }
            }
        // --- 核心修改 2：添加对新消息通知的监听 ---
        NotificationCenter.default.addObserver(
                    forName: ServerModelNotificationManager.textMessageReceivedNotification,
                    object: nil,
                    queue: nil
                ) { [weak self] notification in
                    guard let userInfo = notification.userInfo,
                          let message = userInfo["message"] as? MKTextMessage,
                          let user = userInfo["user"] as? MKUser else { return }
                    
                    let senderName = user.userName() ?? "Unknown"
                    // --- 核心修改 1：接收消息时，修剪文本 ---
                    let plainText = (message.plainTextString() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    let imageData = message.embeddedImages().compactMap { item -> Data? in
                        if let urlString = item as? String {
                            // 直接调用 dataFromDataURLString
                            return self?.dataFromDataURLString(urlString)
                        }
                        return nil
                    }
                    
                    let senderSession = user.session()
                    
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        let connectedUserSession = self.serverModel?.connectedUser()?.session()
                        self.handleReceivedMessage(
                            senderName: senderName,
                            plainText: plainText,
                            imageData: imageData,
                            senderSession: senderSession,
                            connectedUserSession: connectedUserSession
                        )
                    }
                }
    }
    
    // 替换为系统级、更健壮的 Data URI 解析方法
    private nonisolated func dataFromDataURLString(_ dataURLString: String) -> Data? {
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
    
    // --- 核心修改 3：添加处理和发送消息的新方法 ---
        
    private func handleReceivedMessage(
        senderName: String,
        plainText: String,
        imageData: [Data],
        senderSession: UInt,
        connectedUserSession: UInt?
    ) {
        let images = imageData.compactMap { data -> UIImage? in
            guard let image = UIImage(data: data) else {
                print(
                    "🔴 DEBUG (Image): UIImage(data:) returned nil for data of size \(data.count) bytes."
                )
                return nil
            }
            // 诊断点：如果 UIImage 成功创建，打印它的尺寸
            print(
                "✅✅✅ DEBUG (Image): Successfully created UIImage with size \(image.size)"
            )
            return image
        }
                
        print(
            "--- 🖼️ Image Parsing End. Found \(images.count) valid UIImages. 🖼️ ---"
        )
                
        let chatMessage = ChatMessage(
            id: UUID(),
            senderName: senderName,
            message: plainText,
            images: images,
            timestamp: Date(),
            isSentBySelf: senderSession == connectedUserSession
        )
        messages.append(chatMessage)
    }

    // --- 核心修改：修复 sendTextMessage 方法 ---
    func sendTextMessage(_ text: String) {
        guard let serverModel = serverModel, !text.isEmpty else { return }
          
        // --- 核心修改 2：发送消息前，先修剪文本 ---
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        
        // processedHTMLFromPlainTextMessage 会将纯文本转换为带 <p> 标签的 HTML
        let htmlMessage = MUTextMessageProcessor.processedHTML(
            fromPlainTextMessage: text
        )
            
        // 使用编译器提示的、正确的初始化方法
        let message = MKTextMessage(string: htmlMessage)
            
        if let userChannel = serverModel.connectedUser()?.channel() {
            serverModel.send(message, to: userChannel)
        }
            
        // 立即在UI上显示自己发送的消息，体验更流畅
        let selfMessage = ChatMessage(
            id: UUID(),
            senderName: serverModel.connectedUser()?.userName() ?? "Me",
            message: text,
            images: [],
            timestamp: Date(),
            isSentBySelf: true
        )
        messages.append(selfMessage)
    }
    
    func updateUserBySession(
        _ session: UInt
    ) {
        guard let index = userIndexMap[session], index < modelItems.count,
              let user = modelItems[index].object as? MKUser else {
            return
        }
        
        // 更新 item 的状态
        updateUserItemState(
            item: modelItems[index],
            user: user
        )
        
        // 手动发送通知，告诉所有观察者（比如 ChannelListView）：“我变了，快刷新！”
        objectWillChange
            .send()
    }
    func updateUserTalkingState(
        userSession: UInt,
        talkState: MKTalkState
    ) {
        guard let index = userIndexMap[userSession], index < modelItems.count else {
            return
        }
        let item = modelItems[index]
        if item.state?.isMutedOrDeafened == true {
            item.talkingState = .passive; return
        }
        switch talkState.rawValue {
        case 1,
            2,
            3: item.talkingState = .talking; default: item.talkingState = .passive
        }
        objectWillChange
            .send() // 同样，讲话状态变化也需要通知刷新
    }
    private func updateUserItemState(
        item: ChannelNavigationItem,
        user: MKUser
    ) {
        let state = UserState(
            isAuthenticated: user
                .isAuthenticated(),
            isSelfDeafened: user
                .isSelfDeafened(),
            isSelfMuted: user
                .isSelfMuted(),
            isMutedByServer: user
                .isMuted(),
            isDeafenedByServer: user
                .isDeafened(),
            isLocallyMuted: user
                .isLocalMuted(),
            isSuppressed: user
                .isSuppressed(),
            isPrioritySpeaker: user
                .isPrioritySpeaker()
        ); item.state = state; updateUserTalkingState(
            userSession: user
                .session(),
            talkState: user
                .talkState()
        ); if let connectedUser = serverModel?.connectedUser(),
              connectedUser
            .session() == user
            .session() {
            item.isConnectedUser = true
        } else {
            item.isConnectedUser = false
        }
    }
    func updateChannelName(
        channelId: UInt,
        newName: String
    ) {
        if let index = channelIndexMap[channelId],
           index < modelItems.count {
            let item = modelItems[index]; let newItem = ChannelNavigationItem(
                title: newName,
                subtitle: item.subtitle,
                type: item.type,
                indentLevel: item.indentLevel,
                object: item.object
            ); modelItems[index] = newItem
        }
    }
    func rebuildModelArray() {
        guard let serverModel = serverModel else {
            return
        }; modelItems = []; userIndexMap = [:]; channelIndexMap = [:]; if viewMode == .server {
            if let rootChannel = serverModel.rootChannel() {
                addChannelTreeToModel(
                    channel: rootChannel,
                    indentLevel: 0
                )
            }
        } else {
            if let connectedUser = serverModel.connectedUser(),
               let currentChannel = connectedUser.channel() {
                if let usersArray = currentChannel.users(),
                   let users = usersArray as? [MKUser] {
                    for (
                        index,
                        user
                    ) in users.enumerated() {
                        let userName = user.userName() ?? "Unknown User"; let item = ChannelNavigationItem(
                            title: userName,
                            subtitle: "in \(currentChannel.channelName() ?? "Unknown Channel")",
                            type: .user,
                            indentLevel: 0,
                            object: user
                        ); updateUserItemState(
                            item: item,
                            user: user
                        ); modelItems.append(
                            item
                        ); userIndexMap[user.session()] = index
                    }
                }
            }
        }
    }
    private func addChannelTreeToModel(
        channel: MKChannel,
        indentLevel: Int
    ) {
        let channelName = channel.channelName() ?? "Unknown Channel"; let channelDescription = channel.channelDescription(); let channelItem = ChannelNavigationItem(
            title: channelName,
            subtitle: channelDescription,
            type: .channel,
            indentLevel: indentLevel,
            object: channel
        ); if let connectedUser = serverModel?.connectedUser(),
              let userChannel = connectedUser.channel(),
              userChannel
            .channelId() == channel
            .channelId() {
            channelItem.isConnectedUserChannel = true
        }; var userCount = 0; if let usersArray = channel.users(),
                                 let users = usersArray as? [MKUser] {
            userCount = users.count; channelItem.userCount = userCount; channelIndexMap[channel.channelId()] = modelItems.count; modelItems
                .append(
                    channelItem
                ); for user in users {
                    let userName = user.userName() ?? "Unknown User"; let userItem = ChannelNavigationItem(
                        title: userName,
                        subtitle: "in \(channelName)",
                        type: .user,
                        indentLevel: indentLevel + 1,
                        object: user
                    ); updateUserItemState(
                        item: userItem,
                        user: user
                    ); userIndexMap[user.session()] = modelItems.count; modelItems.append(
                        userItem
                    )
                }
        } else {
            channelItem.userCount = 0; channelIndexMap[channel.channelId()] = modelItems.count; modelItems
                .append(
                    channelItem
                )
        }; if let channelsArray = channel.channels(),
              let subChannels = channelsArray as? [MKChannel] {
            for subChannel in subChannels {
                addChannelTreeToModel(
                    channel: subChannel,
                    indentLevel: indentLevel + 1
                )
            }
        }
    }
    func joinChannel(
        _ channel: MKChannel
    ) {
        serverModel?
            .join(
                channel
            )
    }
    func toggleMode() {
        viewMode = (
            viewMode == .server
        ) ? .channel : .server; rebuildModelArray()
    }
    func toggleSelfMute() {
        guard let user = serverModel?.connectedUser() else {
            return
        }
        // 当用户听障时，不允许单独取消静音
        if user
            .isSelfDeafened() {
            return
        }
        serverModel?
            .setSelfMuted(
                !user.isSelfMuted(),
                andSelfDeafened: user.isSelfDeafened()
            )
        updateUserBySession(
            user.session()
        )
    }
    func toggleSelfDeafen() {
        guard let user = serverModel?.connectedUser() else {
            return
        }
        
        // 判断当前是否处于听障状态
        let currentlyDeafened = user.isSelfDeafened()
        
        if currentlyDeafened {
            // 如果是，说明用户想要【取消听障】
            // 我们将使用【之前保存的】静音状态来恢复
            serverModel?
                .setSelfMuted(
                    self.muteStateBeforeDeafen,
                    andSelfDeafened: false
                )
        } else {
            // 如果否，说明用户想要【开启听障】
            // 我们先【保存】当前的静音状态
            self.muteStateBeforeDeafen = user
                .isSelfMuted()
            // 然后强制进入静音和听障状态
            serverModel?
                .setSelfMuted(
                    true,
                    andSelfDeafened: true
                )
        }
        
        // 无论哪种情况，都立刻主动刷新UI
        updateUserBySession(
            user.session()
        )
    }
    var connectedUserState: UserState? {
        guard let connectedUserItem = modelItems.first(
            where: {
                $0.isConnectedUser
            }) else {
            return nil
        }; return connectedUserItem.state
    }
}
