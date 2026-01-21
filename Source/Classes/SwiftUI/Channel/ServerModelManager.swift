// 文件: ServerModelManager.swift (已添加 serverName 属性)

import SwiftUI
import UserNotifications
import AudioToolbox
import ActivityKit

struct UnsafeTransfer<T>: @unchecked Sendable {
    let value: T
}

@MainActor
class ServerModelManager: ObservableObject {
    @Published var modelItems: [ChannelNavigationItem] = []
    @Published var viewMode: ViewMode = .server
    @Published var isConnected: Bool = false
    
    // --- 核心修改 1：添加 @Published 数组来存储聊天消息 ---
    @Published var messages: [ChatMessage] = []
    
    // --- 核心修改 1：添加一个新的 @Published 属性来存储服务器名称 ---
    @Published var serverName: String? = nil
    
    @Published var collapsedChannelIds: Set<Int> = []
    
    @Published public var userVolumes: [UInt: Float] = [:]
    
    private var muteStateBeforeDeafen: Bool = false
    private var serverModel: MKServerModel?
    private var userIndexMap: [UInt: Int] = [:]
    private var channelIndexMap: [UInt: Int] = [:]
    private var delegateWrapper: ServerModelDelegateWrapper?
    private var liveActivity: Activity<MumbleActivityAttributes>?
    private var keepAliveTimer: Timer?
    
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
        ); setupServerModel();
        setupNotifications()
        
        requestNotificationAccess()
        
        startLiveActivity()
    }
    deinit {
        print(
            "🔴 ServerModelManager: DEINIT"
        ); NotificationCenter.default.removeObserver(
            self
        )
    }
    
    private func requestNotificationAccess() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if granted {
                print("🔔 Notifications authorized")
            } else if let error = error {
                print("🚫 Notifications permission error: \(error.localizedDescription)")
            }
        }
    }
    
    private func sendLocalNotification(title: String, body: String) {
        // 1. 如果应用在前台，直接播放音效
        if UIApplication.shared.applicationState == .active {
            // 1007 是 iOS 标准的三全音 (Tri-tone) 提示音
            // 使用 AlertSound 可以在静音模式下触发震动
            AudioServicesPlayAlertSound(1000)
            return
        }
        
        // 2. 如果应用在后台，发送带有默认音效的系统通知
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Failed to schedule notification: \(error)")
            }
        }
    }
    
    private var currentNotificationTitle: String {
        if let currentChannelName = serverModel?.connectedUser()?.channel()?.channelName() {
            return currentChannelName
        }
        return serverName ?? "Mumble"
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
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        
        userVolumes.removeAll()
        
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
        serverName = nil
        
        endLiveActivity()
    }
    
    private func startLiveActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        
        LiveActivityCleanup.forceEndAllActivitiesBlocking()
        
        // 初始状态
        let initialContentState = MumbleActivityAttributes.ContentState(
            speakers: [],
            userCount: 0,
            channelName: "Connecting...",
            isSelfMuted: true,
            isSelfDeafened: false
        )
        
        let attributes = MumbleActivityAttributes(serverName: serverName ?? "Mumble")
        
        let initialContent = ActivityContent(
            state: initialContentState,
            staleDate: Date().addingTimeInterval(15.0)
        )
        
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialContentState, staleDate: nil),
                pushType: nil
            )
            self.liveActivity = activity
            print("🏝️ Live Activity Started")
            
            self.keepAliveTimer?.invalidate()
            self.keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.updateLiveActivity()
                }
            }
            // 立即更新一次准确数据
            updateLiveActivity()
        } catch {
            print("❌ Failed to start Live Activity: \(error)")
        }
    }
    
    private func updateLiveActivity() {
        guard let activity = liveActivity else { return }
        
        // 1. 获取基础信息
        let channelName = currentNotificationTitle
        var userCount = 0
        var speakers: [String] = []
        var isSelfMuted = true
        var isSelfDeafened = false
        
        if let connectedUser = serverModel?.connectedUser() {
            // 2. 获取自我状态
            isSelfMuted = connectedUser.isSelfMuted()
            isSelfDeafened = connectedUser.isSelfDeafened()
            
            if let currentChannel = connectedUser.channel() {
                // 3. 获取人数
                if let users = currentChannel.users() as? [MKUser] {
                    userCount = users.count
                    
                    // 4. 获取所有正在说话的人 (talkState > 0)
                    // 我们过滤掉自己，或者保留自己（看需求，通常显示自己也在说话比较好）
                    let speakingUsers = users.filter { $0.talkState().rawValue > 0 }
                    speakers = speakingUsers.compactMap { $0.userName() }
                }
            }
        }
        
        // 5. 构建新状态
        let contentState = MumbleActivityAttributes.ContentState(
            speakers: speakers,
            userCount: userCount,
            channelName: channelName,
            isSelfMuted: isSelfMuted,
            isSelfDeafened: isSelfDeafened
        )
        
        let content = ActivityContent(
            state: contentState,
            staleDate: Date().addingTimeInterval(15.0)
        )
        
        // 6. 更新
        Task {
            await activity.update(
                ActivityContent(state: contentState, staleDate: nil)
            )
        }
    }
    
    private func endLiveActivity() {
        guard let activity = liveActivity else { return }
        
        let finalContentState = MumbleActivityAttributes.ContentState(
            speakers: [],
            userCount: 0,
            channelName: "Disconnected",
            isSelfMuted: false,
            isSelfDeafened: false
        )
        
        Task {
            await activity.end(
                ActivityContent(state: finalContentState, staleDate: nil),
                dismissalPolicy: .immediate
            )
            self.liveActivity = nil
        }
    }
    
    private nonisolated func setupNotifications() {
        NotificationCenter.default.removeObserver(self)
        
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
            queue: nil
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let user = userInfo["user"] as? MKUser,
                  let channel = userInfo["channel"] as? MKChannel else { return }
            
            let userTransfer = UnsafeTransfer(value: user)
            let channelTransfer = UnsafeTransfer(value: channel)
            
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                
                let safeUser = userTransfer.value
                let safeChannel = channelTransfer.value
                
                // --- A. 先执行通知判断逻辑 (依赖旧的 modelItems 状态) ---
                // 我们需要利用还没刷新的 modelItems 来判断用户之前在哪，
                // 从而决定是否发送 "Moved to..." 通知。
                
                let movingUserSession = safeUser.session()
                let movingUserName = safeUser.userName() ?? "Unknown"
                let destChannelName = safeChannel.channelName() ?? "Unknown Channel"
                let destChannelId = safeChannel.channelId()
                
                if let connectedUser = self.serverModel?.connectedUser() {
                    // 1. 如果是我自己移动，总是显示
                    if movingUserSession == connectedUser.session() {
                        self.addSystemNotification("You moved to channel \(destChannelName)")
                    } else {
                        // 2. 如果是别人移动，判断是否与我有关
                        let myCurrentChannelId = connectedUser.channel()?.channelId()
                        
                        // 查找用户在旧列表中的位置 (Origin)
                        if let userIndex = self.userIndexMap[movingUserSession] {
                            // 向上遍历寻找父频道
                            var originChannelId: UInt?
                            let userItem = self.modelItems[userIndex]
                            for i in stride(from: userIndex - 1, through: 0, by: -1) {
                                let item = self.modelItems[i]
                                if item.type == .channel && item.indentLevel < userItem.indentLevel {
                                    if let ch = item.object as? MKChannel {
                                        originChannelId = ch.channelId()
                                    }
                                    break
                                }
                            }
                            
                            // 判定逻辑
                            let isLeavingMyChannel = (originChannelId == myCurrentChannelId)
                            let isEnteringMyChannel = (destChannelId == myCurrentChannelId)
                            
                            if isLeavingMyChannel || isEnteringMyChannel {
                                self.addSystemNotification("\(movingUserName) moved to \(destChannelName)")
                            }
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
                self.rebuildModelArray()
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: ServerModelNotificationManager.userJoinedNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let user = userInfo["user"] as? MKUser else { return }
            
            let userTransfer = UnsafeTransfer(value: user)
            
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                
                let safeUser = userTransfer.value
                self.applySavedUserPreferences(user: safeUser)
                
                let userName = safeUser.userName() ?? "Unknown User"
                self.addSystemNotification("\(userName) connected")
                
                self.rebuildModelArray()
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: ServerModelNotificationManager.userLeftNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let user = userInfo["user"] as? MKUser else { return }
            
            let userName = user.userName() ?? "Unknown User"
            Task { @MainActor [weak self] in
                self?.addSystemNotification("\(userName) disconnected")
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
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConnectionOpened),
            name: NSNotification.Name("MUConnectionOpenedNotification"), // 确保这个名字和 ObjC 定义的一致
            object: nil
        )
    }
    
    @objc private func handleConnectionOpened(_ notification: Notification) {
        print("✅ Connection Opened - Triggering Restore")
        
        let userInfo = notification.userInfo
        
        Task { @MainActor in
            // 1. 设置服务器显示名称 (原有逻辑)
            if let extractedDisplayName = userInfo?["displayName"] as? String {
                AppState.shared.serverDisplayName = extractedDisplayName
            }
            
            // 2. 插入欢迎消息
            if let welcomeText = userInfo?["welcomeMessage"] as? String, !welcomeText.isEmpty {
                // 简单的去重防止重复显示
                let lastMsg = self.messages.last?.attributedMessage.description
                if lastMsg == nil || !lastMsg!.contains(welcomeText) {
                    let welcomeMsg = ChatMessage(
                        id: UUID(),
                        type: .notification, // 使用通知样式
                        senderName: "Server", // 发送者显示为 Server
                        attributedMessage: self.attributedString(from: welcomeText),
                        images: [],
                        timestamp: Date(),
                        isSentBySelf: false
                    )
                    self.messages.append(welcomeMsg)
                }
            }
            
            // 3. 清理旧状态并重新加载 (原有逻辑)
            self.cleanup()
            self.setupServerModel()
            
            // 稍微延迟一下，确保 MKUser 对象都已就位后恢复偏好
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.restoreAllUserPreferences()
            }
        }
        //稍微延迟一下，确保 MKUser 对象都已就位
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.restoreAllUserPreferences()
        }
    }
    
    private func addSystemNotification(_ text: String) {
        let notificationMessage = ChatMessage(
            id: UUID(),
            type: .notification,
            senderName: "System",
            attributedMessage: AttributedString(text),
            images: [],
            timestamp: Date(),
            isSentBySelf: false
        )
        messages.append(notificationMessage)
        
        if UserDefaults.standard.bool(forKey: "NotificationNotifySystemMessages") {
            sendLocalNotification(title: currentNotificationTitle, body: text)
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
        let images = imageData.compactMap { UIImage(data: $0) }
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
        
        // 1. 默认只推送别人的消息
        let isSentBySelf = (senderSession == connectedUserSession)
        
        // 2. 检查设置: 默认如果没有设置过，视为开启 (true)
        let notifyEnabled = UserDefaults.standard.object(forKey: "NotificationNotifyUserMessages") as? Bool ?? true
        
        if !isSentBySelf && notifyEnabled {
            // 推送内容： "Sender: Message Content"
            let bodyText = plainText.isEmpty ? "[Image]" : plainText
            let notificationBody = "\(senderName): \(bodyText)"
            sendLocalNotification(title: currentNotificationTitle, body: notificationBody)
        }
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
        
        let isServerMuted = item.state?.isMutedByServer ?? false
        let isSelfMuted = item.state?.isSelfMuted ?? false
        let isSelfDeafened = item.state?.isSelfDeafened ?? false
        
        // 如果是因为这些硬性原因导致无法说话，才强制设为 passive
        if isServerMuted || isSelfMuted || isSelfDeafened {
            item.talkingState = .passive
            // 注意：这里不用 return，让代码往下走去更新 UI 也是安全的，但设为 passive 是对的
        } else {
            // 如果只是本地屏蔽 (isLocallyMuted)，代码会继续执行下面的 switch
            // 从而正确更新 talkingState 为 .talking，实现“虽然听不到但能看到他在说”的效果
            switch talkState.rawValue {
            case 1, 2, 3:
                item.talkingState = .talking
            default:
                item.talkingState = .passive
            }
        }
        objectWillChange
            .send() // 同样，讲话状态变化也需要通知刷新
        updateLiveActivity()
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
        updateLiveActivity()
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
                        applySavedUserPreferences(user: user)
                        
                        let userName = user.userName() ?? "Unknown User"
                        let item = ChannelNavigationItem(
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
        updateLiveActivity()
    }
    private func addChannelTreeToModel(
        channel: MKChannel,
        indentLevel: Int
    ) {
        let channelName = channel.channelName() ?? "Unknown Channel"
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
        };

        if let usersArray = channel.users(),
           let rawUsers = usersArray as? [MKUser] {
            
            channelItem.userCount = rawUsers.count
            channelIndexMap[channel.channelId()] = modelItems.count
            modelItems.append(channelItem)
            
            for user in rawUsers {
                // 顺便确保配置被应用 (之前的修复)
                applySavedUserPreferences(user: user)
                
                let userName = user.userName() ?? "Unknown User"
                let userItem = ChannelNavigationItem(
                    title: userName,
                    subtitle: "in \(channelName)",
                    type: .user,
                    indentLevel: indentLevel + 1,
                    object: user
                )
                updateUserItemState(item: userItem, user: user)
                userIndexMap[user.session()] = modelItems.count
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
        
        updateLiveActivity()
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
        
        updateLiveActivity()
    }
    var connectedUserState: UserState? {
        guard let connectedUserItem = modelItems.first(
            where: {
                $0.isConnectedUser
            }) else {
            return nil
        }; return connectedUserItem.state
    }
    func registerSelf() {
        // 1. 获取当前连接信息
        guard let connectionController = MUConnectionController.shared() else { return }
        guard let serverModel = connectionController.serverModel else { return }
        guard let user = serverModel.connectedUser() else { return }
        
        // 2. 检查是否已有证书 (通过 MKConnection 检查)
        // 这里我们简化逻辑：既然用户点击了“注册”，我们假设他想为这个服务器创建一个专属身份
        let currentHost = serverModel.hostname() ?? "UnknownHost"
        let userName = user.userName() ?? "User"
        let certName = "\(userName)@\(currentHost)"
        
        print("📝 Starting registration flow for \(certName)...")
        
        // 3. 生成新证书
        guard let newCertRef = MUCertificateController.generateSelfSignedCertificate(withName: certName, email: "") else {
            print("❌ Failed to generate certificate during registration.")
            return
        }
        
        print("✅ Certificate generated. Binding to favourite server...")
        
        DispatchQueue.main.async {
            AppState.shared.isRegistering = true
            AppState.shared.pendingRegistration = true
        }
        
        // 4. 找到对应的 Favourite Server 条目并更新
        let rawFavs = MUDatabase.fetchAllFavourites() as? [Any] ?? []
        let allFavs = rawFavs.compactMap { $0 as? MUFavouriteServer }
        
        let currentPort = UInt(serverModel.port())
        let currentUser = user.userName()
        
        var targetServer: MUFavouriteServer?
        
        // 尝试匹配：Host + Port + Username (最精确)
        targetServer = allFavs.first {
            $0.hostName == currentHost && $0.port == currentPort && $0.userName == currentUser
        }
        
        // 如果没找到，尝试匹配：Host + Port (可能是匿名登录进来的)
        if targetServer == nil {
            targetServer = allFavs.first {
                $0.hostName == currentHost && $0.port == currentPort
            }
        }
        
        AppState.shared.pendingRegistration = true
        
        if let serverToUpdate = targetServer {
            serverToUpdate.certificateRef = newCertRef
            if serverToUpdate.userName == nil || serverToUpdate.userName!.isEmpty {
                serverToUpdate.userName = userName
            }
            MUDatabase.storeFavourite(serverToUpdate)
            
            connectionController.disconnectFromServer()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                connectionController.connet(
                    toHostname: serverToUpdate.hostName,
                    port: UInt(serverToUpdate.port),
                    withUsername: serverToUpdate.userName,
                    andPassword: serverToUpdate.password,
                    certificateRef: serverToUpdate.certificateRef,
                    displayName: serverToUpdate.displayName
                )
            }
        } else {
            // 如果不在收藏夹，新建一个
            // 注意：这里需要 DisplayName，我们还是得从 AppState 取一下作为新建收藏的默认名
            let rawDispName = AppState.shared.serverDisplayName ?? currentHost
            let cleanDispName = rawDispName.replacingOccurrences(of: "Optional(\"", with: "").replacingOccurrences(of: "\")", with: "")
            
            // 强制解包 MUFavouriteServer()! 确保非空
            let newFav = MUFavouriteServer()!
            newFav.hostName = currentHost
            newFav.port = currentPort
            newFav.userName = userName
            newFav.displayName = cleanDispName.isEmpty ? currentHost : cleanDispName
            newFav.certificateRef = newCertRef
            
            MUDatabase.storeFavourite(newFav)
            
            connectionController.disconnectFromServer()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                connectionController.connet(
                    toHostname: newFav.hostName,
                    port: UInt(newFav.port),
                    withUsername: newFav.userName,
                    andPassword: newFav.password,
                    certificateRef: newFav.certificateRef,
                    displayName: newFav.displayName
                )
            }
        }
    }
    
    func toggleChannelCollapse(_ channelId: Int) {
        if collapsedChannelIds.contains(channelId) {
            collapsedChannelIds.remove(channelId)
        } else {
            collapsedChannelIds.insert(channelId)
        }
    }
    
    func isChannelCollapsed(_ channelId: Int) -> Bool {
        return collapsedChannelIds.contains(channelId)
    }
    
    // 辅助方法：获取排序后的子频道
    func getSortedSubChannels(for channel: MKChannel) -> [MKChannel] {
        guard let subChannels = channel.channels() as? [MKChannel] else { return [] }
        return subChannels.sorted { c1, c2 in
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
            return user.channel()?.channelId() == channel.channelId()
        }
        
        // 使用 validatedUsers 进行排序
        return validatedUsers.sorted { u1, u2 in
            return (u1.userName() ?? "") < (u2.userName() ?? "")
        }
    }
    
    // MARK: - Local User Audio Control
    
    func setLocalUserVolume(session: UInt, volume: Float) {
        guard let user = getUserBySession(session) else { return }
        guard let serverHost = serverModel?.hostname() else { return }
        
        // 1. 更新内存中的状态
        userVolumes[session] = volume
        
        user.localVolume = volume
        
        // 2. 持久化保存 (同时保存当前的静音状态)
        let isMuted = user.isLocalMuted()
        LocalUserPreferences.shared.save(
            volume: volume,
            isLocalMuted: isMuted,
            for: user.userName() ?? "",
            on: serverHost
        )
        
        if let connection = MUConnectionController.shared()?.connection {
            // ✅ 调试日志：如果这里打印 nil，说明 MKConnection.m 的 Getter 没写对
            print("🔊 Setting volume for \(session): \(volume) on output: \(String(describing: connection.audioOutput))")
            
            connection.audioOutput?.setVolume(volume, forSession: session)
        }
        
        // 3. 通知 UI 刷新
        objectWillChange.send()
    }
    
    /// 切换某个用户的本地屏蔽状态 (Local Mute / Ignore)
    func toggleLocalUserMute(session: UInt) {
        guard let user = getUserBySession(session) else { return }
        guard let serverHost = serverModel?.hostname() else { return }
        
        let newMuteState = !user.isLocalMuted()
        user.setLocalMuted(newMuteState)
        
        if let connection = MUConnectionController.shared()?.connection {
            connection.audioOutput?.setMuted(newMuteState, forSession: session)
        }
        
        let currentVol = userVolumes[session] ?? 1.0
        
        // 持久化
        LocalUserPreferences.shared.save(
            volume: currentVol,
            isLocalMuted: newMuteState,
            for: user.userName() ?? "",
            on: serverHost
        )
        
        // 通知 UI
        objectWillChange.send()
    }
    
    func restoreAllUserPreferences() {
        print("🔄 Restoring preferences for ALL users...")
        guard let root = serverModel?.rootChannel() else { return }
        recursiveRestore(channel: root)
    }
    
    private func recursiveRestore(channel: MKChannel) {
        // 1. 恢复当前频道的用户
        if let users = channel.users() as? [MKUser] {
            for user in users {
                applySavedUserPreferences(user: user)
            }
        }
        
        // 2. 递归子频道
        if let subs = channel.channels() as? [MKChannel] {
            for sub in subs {
                recursiveRestore(channel: sub)
            }
        }
    }
    
    // 辅助：应用已保存的设置 (在 rebuildModelArray 中调用)
    private func applySavedUserPreferences(user: MKUser) {
        guard let serverHost = serverModel?.hostname(),
              let name = user.userName() else { return }
        
        // 读取配置
        let prefs = LocalUserPreferences.shared.load(for: name, on: serverHost)
        
        // 1. 应用自定义音量到内存字典
        // 注意：我们不调用 user.setLocalVolume，只更新我们自己的逻辑字典
        userVolumes[user.session()] = prefs.volume
        user.localVolume = prefs.volume
        
        // 2. 应用屏蔽状态 (这个依然调用 MumbleKit，因为它支持)
        if user.isLocalMuted() != prefs.isLocalMuted {
            user.setLocalMuted(prefs.isLocalMuted)
        }
        
        if let connection = MUConnectionController.shared()?.connection {
            connection.audioOutput?.setVolume(prefs.volume, forSession: user.session())
            connection.audioOutput?.setMuted(prefs.isLocalMuted, forSession: user.session())
        }
    }
    
    // 辅助：通过 Session 找 User
    func getUserBySession(_ session: UInt) -> MKUser? {
        guard let index = userIndexMap[session], index < modelItems.count else { return nil }
        return modelItems[index].object as? MKUser
    }
}

@objc public class LiveActivityCleanup: NSObject {
    
    /// 阻塞式强制结束所有活动（专用于 App 终止时）
    @objc public static func forceEndAllActivitiesBlocking() {
        // iOS 16.1 之前不支持
        guard #available(iOS 16.1, *) else { return }
        
        print("🛑 Force ending Live Activities (Blocking)...")
        let semaphore = DispatchSemaphore(value: 0)
        
        // 使用 detached 任务，脱离当前上下文，提高存活率
        Task.detached(priority: .userInitiated) {
            for activity in Activity<MumbleActivityAttributes>.activities {
                print("🛑 Ending activity: \(activity.id)")
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            // 任务完成，发送信号
            semaphore.signal()
        }
        
        // ⚠️ 关键点：卡住主线程，最多等待 2.0 秒
        // 这强迫系统不要立即杀掉进程，直到我们的清理请求发出去
        let result = semaphore.wait(timeout: .now() + 2.0)
        if result == .timedOut {
            print("⚠️ LiveActivity cleanup timed out.")
        } else {
            print("✅ LiveActivity cleanup finished successfully.")
        }
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

extension Notification.Name {
    static let requestReconnect = Notification.Name("MURequestReconnect")
}
