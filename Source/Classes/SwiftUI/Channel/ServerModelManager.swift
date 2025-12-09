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
    deinit {
        print(
            "🔴 ServerModelManager: DEINIT"
        ); NotificationCenter.default.removeObserver(
            self
        )
    }
    
    private func setupServerModel() {
        guard let connectionController = MUConnectionController.shared(),
              let model = connectionController.serverModel else {
            return
        }
        
        serverModel = model
        delegateWrapper = ServerModelDelegateWrapper()
        model.addDelegate(delegateWrapper!)
        isConnected = true
        
        // ✅ 极简逻辑：直接去 Recent 列表里查名字
        // 因为 connectionOpened 已经执行过了，Recent 列表此刻肯定是最新的
        let currentHost = model.hostname() ?? ""
        let currentPort = Int(model.port())
        
        if let savedName = RecentServerManager.shared.getDisplayName(hostname: currentHost, port: currentPort) {
            print("📖 ServerModelManager: Resolved name from Recents: '\(savedName)'")
            self.serverName = savedName
        } else {
            // 理论上不应该进这里，除非 Recent 保存慢了，那就兜底显示域名
            self.serverName = currentHost
        }
        
        rebuildModelArray()
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
        
        NotificationCenter.default.addObserver(
            forName: ServerModelNotificationManager.userMovedNotification,
            object: nil,
            queue: nil // 在后台队列接收
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let user = userInfo["user"] as? MKUser,
                  let channel = userInfo["channel"] as? MKChannel else { return }
            
            // 1. 在进入异步任务前，提取所有需要的数据为“值类型”
            let movingUserSession = user.session()
            let newChannelName = channel.channelName() ?? "Unknown Channel"
            
            // 2. 将这些安全的值传递进主线程任务
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                
                // 在安全的上下文里获取 connectedUserSession
                let connectedUserSession = self.serverModel?.connectedUser().session()
                
                // 只有当移动的用户是当前用户时，才显示通知
                if movingUserSession == connectedUserSession {
                    self.addChannelJoinNotification(channelName: newChannelName)
                }
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
            let plainText = (message.plainTextString() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let imageData = message.embeddedImages().compactMap { self?.dataFromDataURLString($0 as? String ?? "") }
            let senderSession = user.session()
            
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let connectedUserSession = self.serverModel?.connectedUser()?.session()
                
                // 1. 先调用 handleReceivedMessage，它会创建并添加 chatMessage 到数组
                self.handleReceivedMessage(
                    senderName: senderName,
                    plainText: plainText,
                    imageData: imageData,
                    senderSession: senderSession,
                    connectedUserSession: connectedUserSession
                )
                
                // 2. 现在，我们可以安全地检查刚刚被添加的消息
                // 我们只需要判断这次消息是不是自己发送的即可
                let isSentBySelf = (senderSession == connectedUserSession)
                if AppState.shared.currentTab != .messages && !isSentBySelf {
                    AppState.shared.unreadMessageCount += 1
                }
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("MUConnectionOpenedNotification"),
            object: nil,
            queue: nil
        ) { [weak self] notification in
            
            let userInfo = notification.userInfo
            let extractedDisplayName = userInfo?["displayName"] as? String
            
            Task { @MainActor [weak self] in
                if let name = extractedDisplayName {
                    AppState.shared.serverDisplayName = name
                }
                
                self?.cleanup()
                self?.setupServerModel()
            }
        }
    }
    
    // 新增：一个用于将纯文本转换为 AttributedString 的辅助函数
        private func attributedString(from plainText: String) -> AttributedString {
            do {
                // 使用 Markdown 解析器来自动识别链接
                // `inlineOnlyPreservingWhitespace` 选项能最好地保留原始文本的格式
                return try AttributedString(markdown: plainText, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            } catch {
                // 如果 Markdown 解析失败，则返回一个普通的字符串
                print("Could not parse markdown: \(error)")
                return AttributedString(plainText)
            }
        }
    
    // --- 核心修改 2：添加一个创建系统通知的新方法 ---
        private func addChannelJoinNotification(channelName: String) {
            let text = "You have joined the channel: \(channelName)"
            let notificationMessage = ChatMessage(
                id: UUID(),
                type: .notification, // 类型为系统通知
                senderName: "System", // 发送者为系统
                attributedMessage: AttributedString(text),
                images: [],
                timestamp: Date(),
                isSentBySelf: false
            )
            messages.append(notificationMessage)
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
            type: .userMessage,
            senderName: senderName,
            attributedMessage: attributedString(from: plainText),
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
            fromPlainTextMessage: trimmedText
        )
            
        // 使用编译器提示的、正确的初始化方法
        let message = MKTextMessage(string: htmlMessage)
            
        if let userChannel = serverModel.connectedUser()?.channel() {
            serverModel.send(message, to: userChannel)
        }
            
        // 立即在UI上显示自己发送的消息，体验更流畅
        let selfMessage = ChatMessage(
            id: UUID(),
            type: .userMessage,
            senderName: serverModel.connectedUser()?.userName() ?? "Me",
            attributedMessage: attributedString(from: trimmedText),
            images: [],
            timestamp: Date(),
            isSentBySelf: true
        )
        messages.append(selfMessage)
    }
    
    func sendImageMessage(image: UIImage) async {
        guard let serverModel = serverModel else { return }
        
        // 将 CPU 密集型任务（压缩和编码）放到后台线程执行
                let compressedData = await Task.detached(priority: .userInitiated) {
                    let maxSizeInBytes = 60 * 1024 // Mumble 消息大小上限
                    return self.compressImage(image, toTargetSizeInBytes: maxSizeInBytes)
                }.value
                
                guard let imageData = compressedData else {
                    print("🔴 Error: Could not convert compressed UIImage to JPEG data.")
                    return
                }
                
                let base64String = imageData.base64EncodedString()
                let dataURI = "data:image/jpeg;base64,\(base64String)"
                let htmlMessage = "<img src=\"\(dataURI)\" />"
                let message = MKTextMessage(string: htmlMessage)
                
                if let userChannel = serverModel.connectedUser()?.channel() {
                    serverModel.send(message, to: userChannel)
                }
                
                // 立即在UI上显示自己发送的图片 (UI更新会自动回到主线程)
                let finalImage = UIImage(data: imageData) ?? image
        let selfMessage = ChatMessage(
            id: UUID(),
            type: .userMessage,
            senderName: serverModel
                .connectedUser()?
                .userName() ?? "Me",
            attributedMessage: AttributedString(""),
            images: [finalImage],
            timestamp: Date(),
            isSentBySelf: true
        )
                messages.append(selfMessage)
        }

        // 新增一个私有辅助函数，用于压缩图片
    private nonisolated func compressImage(_ image: UIImage, toTargetSizeInBytes targetSize: Int) -> Data? {
        let imageData = image.jpegData(compressionQuality: 1.0)
            
            // 如果图片本来就小于目标大小，直接返回最高质量的JPEG数据
            if let data = imageData, data.count <= targetSize {
                return data
            }

            // --- 使用二分搜索寻找最佳压缩质量 ---
            var minQuality: CGFloat = 0.0
            var maxQuality: CGFloat = 1.0
            var bestImageData: Data?

            for _ in 0..<8 { // 8次迭代足以达到很高的精度
                let currentQuality = (minQuality + maxQuality) / 2
                guard let data = image.jpegData(compressionQuality: currentQuality) else { continue }
                
                if data.count <= targetSize {
                    // 这是一个可行的方案，保存它，然后尝试寻找更高质量的方案
                    bestImageData = data
                    minQuality = currentQuality
                } else {
                    // 图片还是太大，降低质量上限
                    maxQuality = currentQuality
                }
            }

            // 如果通过降低质量找到了一个可行的方案，就返回它
            if let finalData = bestImageData {
                 print("✅ Compressed image with quality \(minQuality) to \(finalData.count) bytes.")
                return finalData
            }

            // --- 如果最低质量依然过大，则开始降低分辨率 ---
            // (这种情况很少见，但作为备用方案)
            var scale: CGFloat = 0.9
            var resizedImage = image
            while let newImage = resizedImage.resized(by: scale),
                  let data = newImage.jpegData(compressionQuality: 0.75), // 使用一个较高的质量
                  data.count > targetSize && scale > 0.1 {
                resizedImage = newImage
                scale -= 0.1
            }
            
            if let finalImage = resizedImage.resized(by: scale) {
                 print("⚠️ Image too large, had to resize by scale \(scale).")
                return finalImage.jpegData(compressionQuality: 0.75)
            }
            
            // 最终的备用方案：返回最低质量的原始图片数据
            return image.jpegData(compressionQuality: 0.0)
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

extension UIImage {
    func resized(by scale: CGFloat) -> UIImage? {
        let newSize = CGSize(width: self.size.width * scale, height: self.size.height * scale)
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        self.draw(in: CGRect(origin: .zero, size: newSize))
        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return newImage
    }
}
