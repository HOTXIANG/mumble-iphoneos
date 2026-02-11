// 文件: ServerModelManager.swift (已添加 serverName 属性)

import SwiftUI
import UserNotifications
import AudioToolbox
import ActivityKit

struct UnsafeTransfer<T>: @unchecked Sendable {
    let value: T
}

private class ObserverTokenHolder {
    private var tokens: [NSObjectProtocol] = []
    
    func add(_ token: NSObjectProtocol) {
        tokens.append(token)
    }
    
    func removeAll() {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
        tokens.removeAll()
    }
    
    deinit {
        removeAll()
    }
}

private final class DelegateToken {
    private let model: MKServerModel
    private let wrapper: ServerModelDelegateWrapper
    
    init(model: MKServerModel, wrapper: ServerModelDelegateWrapper) {
        self.model = model
        self.wrapper = wrapper
    }
    
    deinit {
        // 在这里执行清理是安全的，因为它访问的是自己的常量属性
        model.removeDelegate(wrapper)
    }
}

@MainActor
class ServerModelManager: ObservableObject {
    @Published var modelItems: [ChannelNavigationItem] = []
    @Published var viewMode: ViewMode = .server
    @Published var isConnected: Bool = false
    @Published var isLocalAudioTestRunning: Bool = false
    
    // --- 核心修改 1：添加 @Published 数组来存储聊天消息 ---
    @Published var messages: [ChatMessage] = []
    
    // --- 核心修改 1：添加一个新的 @Published 属性来存储服务器名称 ---
    @Published var serverName: String? = nil
    
    @Published var collapsedChannelIds: Set<Int> = []
    
    @Published public var userVolumes: [UInt: Float] = [:]
    
    private let tokenHolder = ObserverTokenHolder()
    private var delegateToken: DelegateToken?
    private var muteStateBeforeDeafen: Bool = false
    private var serverModel: MKServerModel?
    private var userIndexMap: [UInt: Int] = [:]
    private var channelIndexMap: [UInt: Int] = [:]
    private var delegateWrapper: ServerModelDelegateWrapper?
    private var liveActivity: Activity<MumbleActivityAttributes>?
    private var keepAliveTimer: Timer?
    private let systemMuteManager = SystemMuteManager()
    private var isRestoringMuteState = false
    
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
        print("🚀 ServerModelManager: ACTIVATE - Activating model and notifications.")
        setupServerModel();
        setupNotifications()
        requestNotificationAccess()
        setupSystemMute()
        setupAudioRouteObservation()
    }
    deinit {
        print("🔴 ServerModelManager: DEINIT")
        NotificationCenter.default.removeObserver(self)
    }
    
    func markAsRead() {
        // 1. 清除 App 内红点
        AppState.shared.unreadMessageCount = 0
        
        // 2. 清除 iOS 系统通知中心的推送
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
    
    private func setupSystemMute() {
        systemMuteManager.onSystemMuteChanged = { [weak self] isSystemMuted in
            guard let self = self, let user = self.serverModel?.connectedUser() else { return }
            
            // ✅ 核心修复：如果正在恢复状态（路由切换中），忽略系统的“自动开麦”通知
            // 这防止了系统重置硬件状态时，反过来把 App 的状态也带偏了
            if self.isRestoringMuteState {
                print("🔒 Route changing: Ignoring system mute notification (\(isSystemMuted)) to preserve App state.")
                return
            }
            
            // 只有当 Mumble 内部状态不一致时才更新
            if user.isSelfMuted() != isSystemMuted {
                print("🔄 Sync: System(\(isSystemMuted)) -> App")
                self.serverModel?.setSelfMuted(isSystemMuted, andSelfDeafened: user.isSelfDeafened())
                self.updateUserBySession(user.session())
                self.updateLiveActivity()
            }
        }
        
        systemMuteManager.activate()
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
        
        guard let newModel = connectionController.serverModel else {
            print("⚠️ ServerModel not ready. Retrying in 0.5s...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.setupServerModel()
            }
            return
        }
        
        if self.serverModel === newModel {
            print("✅ ServerModel identity match. Skipping setup to prevent duplicates.")
            // 兜底：如果界面是空的，强制刷新一下
            if self.modelItems.isEmpty { rebuildModelArray() }
            return
        }
        
        if self.serverModel != nil {
            print("🔄 Switching Server Model. Performing cleanup...")
            self.cleanup()
        }
        
        print("🔗 Binding new ServerModel...")
        self.serverModel = newModel
        
        let wrapper = ServerModelDelegateWrapper()
        newModel.addDelegate(wrapper)
        self.delegateToken = DelegateToken(model: model, wrapper: wrapper)
        
        isConnected = true
        
        let currentHost = model.hostname() ?? ""
        let currentPort = Int(model.port())
        
        if let savedName = RecentServerManager.shared.getDisplayName(hostname: currentHost, port: currentPort) {
            print("📖 ServerModelManager: Resolved name from Recents: '\(savedName)'")
            self.serverName = savedName
        } else {
            self.serverName = currentHost
        }
        
        if let welcomeText = connectionController.lastWelcomeMessage, !welcomeText.isEmpty {
            let lastMsg = self.messages.last?.attributedMessage.description
            if lastMsg == nil || !lastMsg!.contains(welcomeText) {
                let welcomeMsg = ChatMessage(
                    id: UUID(),
                    type: .notification,
                    senderName: "Server",
                    attributedMessage: self.attributedString(from: welcomeText),
                    images: [],
                    timestamp: Date(),
                    isSentBySelf: false
                )
                self.messages.append(welcomeMsg)
            }
        } else if messages.isEmpty {
            // 兜底显示
            let hostDisplayName = serverName ?? currentHost
            addSystemNotification("Connected to \(hostDisplayName)")
        }
        
        rebuildModelArray()
        startLiveActivity()
    }
    
    func cleanup() {
        print("🧹 ServerModelManager: CLEANUP (Data Only)")
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        
        userVolumes.removeAll()
        
        self.delegateToken = nil
        self.serverModel = nil
        modelItems = []
        userIndexMap = [:]
        channelIndexMap = [:]
        isConnected = false
        serverName = nil
        
        systemMuteManager.cleanup()
        endLiveActivity()
    }
    
    // MARK: - Audio Route Handling (Hot-swap Support)
    
    private func setupAudioRouteObservation() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioRouteChanged),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }
    
    @objc private func handleAudioRouteChanged(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        
        print("🎧 Audio Route Changed. Reason: \(reason.rawValue)")
        
        switch reason {
        case .newDeviceAvailable:
            // 🔒 1. 立即上锁，防止重启期间系统发出的“开麦”通知把 App 状态带偏
            self.isRestoringMuteState = true
            
            print("🎧 New Device Detected. Scheduling Full Reactivation...")
            
            Task { @MainActor in
                // ⏳ 2. 等待蓝牙握手 (1.5秒)
                // AirPods Pro 连接过程：蓝牙连接 -> A2DP 路由 -> HFP (麦克风) 路由。
                // 必须要等 HFP 路由完全建立，AVAudioApplication 才能控制它。
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                
                // 🔄 3. 重启 SystemMuteManager (Cleanup -> Activate)
                // 这相当于重新注册了一遍闭麦手势监听
                self.systemMuteManager.cleanup()
                self.systemMuteManager.activate()
                
                // 📲 4. 强制把 App 的状态“刷”给新耳机
                if let user = self.serverModel?.connectedUser() {
                    let targetState = user.isSelfMuted()
                    print("🔄 Syncing App State (\(targetState)) to New Hardware...")
                    self.systemMuteManager.setSystemMute(targetState)
                }
                
                // 🔓 5. 解锁
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.isRestoringMuteState = false
            }
            
        case .oldDeviceUnavailable, .categoryChange:
            break
            
        default:
            break
        }
    }
    
    private func enforceAppMuteStateToSystem() {
        guard let user = serverModel?.connectedUser() else {
            self.isRestoringMuteState = false
            return
        }
        
        // 1. 获取 App 当前的真实意图（是静音还是开麦）
        let shouldBeMuted = user.isSelfMuted()
        
        print("🔄 Route changed. Locking state and enforcing: \(shouldBeMuted)...")
        
        Task { @MainActor in
            // 2. 稍微等待，让音频链路和蓝牙握手稳定
            // 0.5秒通常足够覆盖 AirPods 连接时的系统重置动作
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            
            // 3. 再次确认用户还在
            if let freshUser = self.serverModel?.connectedUser() {
                // 使用 App 之前的状态，强行覆盖系统状态
                self.systemMuteManager.setSystemMute(shouldBeMuted)
                print("✅ Enforced state to System: \(shouldBeMuted)")
            }
            
            // 4. 解锁，恢复正常监听
            // 稍微再延迟一点点解锁，确保刚才的 setSystemMute 不会被误判为外部变更
            try? await Task.sleep(nanoseconds: 500_000_000) // +0.5s
            self.isRestoringMuteState = false
            print("🔓 Route change handling complete. State lock released.")
        }
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
    
    private func setupNotifications() {
        // 1. 先清理旧的，防止叠加
        tokenHolder.removeAll()
        
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name("MUConnectionOpenedNotification"), object: nil)
        
        let center = NotificationCenter.default
        
        // 2. 注册并保存令牌
        tokenHolder.add(center.addObserver(forName: ServerModelNotificationManager.rebuildModelNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.rebuildModelArray() }
        })
        
        tokenHolder.add(center.addObserver(forName: ServerModelNotificationManager.userStateUpdatedNotification, object: nil, queue: nil) { [weak self] notification in
            guard let userInfo = notification.userInfo, let userSession = userInfo["userSession"] as? UInt else { return }
            Task { @MainActor in self?.updateUserBySession(userSession) }
        })
        
        tokenHolder.add(center.addObserver(forName: ServerModelNotificationManager.userTalkStateChangedNotification, object: nil, queue: nil) { [weak self] notification in
            guard let userInfo = notification.userInfo, let userSession = userInfo["userSession"] as? UInt, let talkState = userInfo["talkState"] as? MKTalkState else { return }
            Task { @MainActor in self?.updateUserTalkingState(userSession: userSession, talkState: talkState) }
        })
        
        tokenHolder.add(center.addObserver(forName: ServerModelNotificationManager.channelRenamedNotification, object: nil, queue: nil) { [weak self] notification in
            guard let userInfo = notification.userInfo, let channelId = userInfo["channelId"] as? UInt, let newName = userInfo["newName"] as? String else { return }
            Task { @MainActor in self?.updateChannelName(channelId: channelId, newName: newName) }
        })
        
        tokenHolder.add(center.addObserver(forName: ServerModelNotificationManager.userMovedNotification, object: nil, queue: nil) { [weak self] notification in
            guard let userInfo = notification.userInfo, let user = userInfo["user"] as? MKUser, let channel = userInfo["channel"] as? MKChannel else { return }
            let userTransfer = UnsafeTransfer(value: user)
            let channelTransfer = UnsafeTransfer(value: channel)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let safeUser = userTransfer.value
                let safeChannel = channelTransfer.value
                let movingUserSession = safeUser.session()
                let movingUserName = safeUser.userName() ?? "Unknown"
                let destChannelName = safeChannel.channelName() ?? "Unknown Channel"
                let destChannelId = safeChannel.channelId()
                if let connectedUser = self.serverModel?.connectedUser() {
                    if movingUserSession == connectedUser.session() {
                        self.addSystemNotification("You moved to channel \(destChannelName)")
                    } else {
                        let myCurrentChannelId = connectedUser.channel()?.channelId()
                        if let userIndex = self.userIndexMap[movingUserSession] {
                            var originChannelId: UInt?
                            let userItem = self.modelItems[userIndex]
                            for i in stride(from: userIndex - 1, through: 0, by: -1) {
                                let item = self.modelItems[i]
                                if item.type == .channel && item.indentLevel < userItem.indentLevel {
                                    if let ch = item.object as? MKChannel { originChannelId = ch.channelId() }
                                    break
                                }
                            }
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
        })
        
        tokenHolder.add(center.addObserver(forName: ServerModelNotificationManager.userJoinedNotification, object: nil, queue: nil) { [weak self] notification in
            guard let userInfo = notification.userInfo, let user = userInfo["user"] as? MKUser else { return }
            let userTransfer = UnsafeTransfer(value: user)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let safeUser = userTransfer.value
                self.applySavedUserPreferences(user: safeUser)
                let userName = safeUser.userName() ?? "Unknown User"
                self.addSystemNotification("\(userName) connected")
                self.rebuildModelArray()
            }
        })
        
        tokenHolder.add(center.addObserver(forName: ServerModelNotificationManager.userLeftNotification, object: nil, queue: nil) { [weak self] notification in
            guard let userInfo = notification.userInfo, let user = userInfo["user"] as? MKUser else { return }
            let userName = user.userName() ?? "Unknown User"
            Task { @MainActor [weak self] in self?.addSystemNotification("\(userName) disconnected") }
        })
        
        // 核心修复：消息去重 + 监听器管理
        tokenHolder.add(center.addObserver(forName: ServerModelNotificationManager.textMessageReceivedNotification, object: nil, queue: nil) { [weak self] notification in
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
                
                if senderSession == connectedUserSession {
                    print("🚫 Ignoring echoed message from self to prevent duplicate.")
                    return
                }
                
                self.handleReceivedMessage(
                    senderName: senderName,
                    plainText: plainText,
                    imageData: imageData,
                    senderSession: senderSession,
                    connectedUserSession: connectedUserSession
                )
                
                if AppState.shared.currentTab != .messages {
                    AppState.shared.unreadMessageCount += 1
                }
            }
        })
        
        center.addObserver(self, selector: #selector(handleConnectionOpened), name: NSNotification.Name("MUConnectionOpenedNotification"), object: nil)
    }
    
    @objc private func handleConnectionOpened(_ notification: Notification) {
        print("✅ Connection Opened - Triggering Restore")
        
        let userInfo = notification.userInfo
        
        Task { @MainActor in
            // 设置服务器显示名称
            if let extractedDisplayName = userInfo?["displayName"] as? String {
                AppState.shared.serverDisplayName = extractedDisplayName
            }
            
            if let welcomeText = userInfo?["welcomeMessage"] as? String, !welcomeText.isEmpty {
                // 这里也使用带返回值的添加方法，但通常欢迎语不需要发通知
                self.appendNotificationMessage(text: welcomeText, senderName: "Server")
            }
            
            self.setupServerModel()
            
            Task.detached(priority: .userInitiated) {
                // 稍微等待 UI 动画完成 (例如进入频道的 Push 动画)
                try? await Task.sleep(nanoseconds: 600_000_000) // 0.6s
                
                // 回到主线程执行具体的恢复逻辑
                await MainActor.run {
                    print("♻️ [Async] Restoring user preferences...")
                    self.restoreAllUserPreferences()
                    
                    // 初始进入时的状态同步
                    if let user = self.serverModel?.connectedUser(), user.isSelfMuted() {
                        print("🔒 [Async] Initial Sync: Enforcing System Mute")
                        self.systemMuteManager.setSystemMute(true)
                    }
                }
            }
        }
    }
    
    private func addSystemNotification(_ text: String) {
        let didAppend = appendNotificationMessage(text: text, senderName: "System")
        
        // 只有真的添加了系统消息，才发通知
        if didAppend && UserDefaults.standard.bool(forKey: "NotificationNotifySystemMessages") {
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
    
    // 消息添加方法
    @discardableResult
    private func appendUserMessage(senderName: String, text: String, isSentBySelf: Bool, images: [UIImage] = []) -> Bool {
        let newMessage = ChatMessage(
            id: UUID(),
            type: .userMessage,
            senderName: senderName,
            attributedMessage: attributedString(from: text),
            images: images,
            timestamp: Date(),
            isSentBySelf: isSentBySelf
        )
        messages.append(newMessage)
        return true
    }
    
    // ✅ 修复：专用函数添加通知消息
    @discardableResult
    private func appendNotificationMessage(text: String, senderName: String) -> Bool {
        if let lastMsg = messages.last {
            let isSameContent = (lastMsg.attributedMessage.description == text) || (lastMsg.attributedMessage.description == attributedString(from: text).description)
            if lastMsg.senderName == senderName && isSameContent {
                return false
            }
        }
        
        let newMessage = ChatMessage(
            id: UUID(),
            type: .notification,
            senderName: senderName,
            attributedMessage: attributedString(from: text),
            images: [],
            timestamp: Date(),
            isSentBySelf: false
        )
        messages.append(newMessage)
        return true
    }
    
    private func handleReceivedMessage(senderName: String, plainText: String, imageData: [Data], senderSession: UInt, connectedUserSession: UInt?) {
        let images = imageData.compactMap { UIImage(data: $0) }
        
        // ✅ 核心修复：获取返回值
        let didAppend = appendUserMessage(
            senderName: senderName,
            text: plainText,
            isSentBySelf: senderSession == connectedUserSession,
            images: images
        )
        
        // 只有当消息真的被添加了 (didAppend == true)，才处理后续通知
        if didAppend {
            let isSentBySelf = (senderSession == connectedUserSession)
            let notifyEnabled = UserDefaults.standard.object(forKey: "NotificationNotifyUserMessages") as? Bool ?? true
            
            // 只有不是自己发的、且开启了通知，才发通知
            // sendLocalNotification 内部会根据 applicationState 判断：前台播放音效，后台发系统推送
            if !isSentBySelf && notifyEnabled {
                let bodyText = plainText.isEmpty ? "[Image]" : plainText
                let notificationBody = "\(senderName): \(bodyText)"
                sendLocalNotification(title: currentNotificationTitle, body: notificationBody)
            }
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
    
    func sendImageMessage(image: UIImage, isHighQuality: Bool) async {
        if isHighQuality {
            // ✅ 高画质模式：从 1MB 开始，失败后缓慢降级
            // 适用于：已知服务器支持大图，或者对方也是 NeoMumble 客户端
            await attemptSendImage(image: image, targetSize: 1024 * 1024, decayRate: 0.9) // 每次降 10%
        } else {
            // ✅ 兼容模式 (默认)：死守 128KB 防线
            // 适用于：需要让 PC 端 Mumble 也能看到图
            // 考虑到 Base64 开销，目标设为 90KB 比较稳妥 (90 * 1.33 ≈ 120KB)
            await attemptSendImage(image: image, targetSize: 90 * 1024, decayRate: 0.9)
        }
    }
    // 递归尝试发送函数
    private func attemptSendImage(image: UIImage, targetSize: Int, decayRate: Double) async {
        // 保底 20KB，再小没意义了
        guard targetSize > 20 * 1024 else {
            print("❌ Image too small to compress further. Give up.")
            return
        }
        
        print("🚀 [High Quality] Attempting size: \(targetSize / 1024) KB")
        
        // 1. 压缩
        guard let data = await smartCompress(image: image, to: targetSize) else { return }
        
        // 2. 构造消息
        let base64Str = data.base64EncodedString()
        let htmlBody = "<img src=\"data:image/jpeg;base64,\(base64Str)\" />"
        let msg = MKTextMessage(plainText: htmlBody)
        
        // 3. 监听失败
        let failName = Notification.Name("MUMessageSendFailed")
        let task = Task {
            if let channel = self.serverModel?.connectedUser()?.channel() {
                self.serverModel?.send(msg, to: channel)
            }
            try? await Task.sleep(nanoseconds: 800 * 1_000_000) // 等待 0.8s
        }
        
        var didFail = false
        let observer = NotificationCenter.default.addObserver(forName: failName, object: nil, queue: .main) { _ in
            didFail = true
        }
        _ = await task.result
        NotificationCenter.default.removeObserver(observer)
        
        // 4. 判定
        if didFail {
            print("⚠️ Send failed. Reducing size by 10%...")
            // 核心修改：每次只降 10% (targetSize * 0.9)
            let newTarget = Int(Double(targetSize) * decayRate)
            await attemptSendImage(image: image, targetSize: newTarget, decayRate: decayRate)
        } else {
            print("✅ Send success!")
            await appendLocalMessage(image: image)
        }
    }
    
    // 辅助：本地回显
    private func appendLocalMessage(image: UIImage) async {
        await MainActor.run {
            let localMessage = ChatMessage(
                id: UUID(),
                type: .userMessage,
                senderName: self.serverModel?.connectedUser()?.userName() ?? "Me",
                attributedMessage: AttributedString(""),
                images: [image],
                timestamp: Date(),
                isSentBySelf: true
            )
            self.messages.append(localMessage)
        }
    }
    
    // MARK: - 智能压缩算法 (二分法 + Resize)
    private func smartCompress(image: UIImage, to maxBytes: Int) async -> Data? {
        // 1. 预检查：如果原图已经很小，直接返回
        if let data = image.jpegData(compressionQuality: 1.0), data.count <= maxBytes {
            return data
        }
        
        // 2. 二分法查找最佳压缩比 (只调整质量，不调整分辨率)
        var minQuality: CGFloat = 0.0
        var maxQuality: CGFloat = 1.0
        var bestData: Data? = nil
        
        // 最多尝试 6 次二分查找 (精度足以达到 0.015)
        for _ in 0..<6 {
            let midQuality = (minQuality + maxQuality) / 2
            if let data = image.jpegData(compressionQuality: midQuality) {
                if data.count <= maxBytes {
                    bestData = data // 暂存这个可用的结果
                    minQuality = midQuality // 尝试更好的质量
                } else {
                    maxQuality = midQuality // 质量太高了，降低
                }
            }
        }
        
        // 3. 如果二分法找到了符合大小的数据，直接返回
        if let data = bestData {
            return data
        }
        
        // 4. 兜底方案：如果质量降到 0 还是太大，说明分辨率太高，必须 Resize
        // 强制缩放到较小的尺寸 (比如长边 1024)
        print("⚠️ Quality compression failed. Resizing image...")
        let resizedImage = resizeImage(image: image, targetSize: CGSize(width: 1024, height: 1024))
        
        // 对缩放后的图片再次尝试低质量压缩
        return resizedImage.jpegData(compressionQuality: 0.5)
    }
 
    // 辅助：保持比例缩放图片
    private func resizeImage(image: UIImage, targetSize: CGSize) -> UIImage {
        let size = image.size
        
        let widthRatio  = targetSize.width  / size.width
        let heightRatio = targetSize.height / size.height
        
        // 取较小的比例，确保长宽都在 targetSize 内
        let ratio = min(widthRatio, heightRatio)
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        
        let rect = CGRect(origin: .zero, size: newSize)
        
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: rect)
        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return newImage ?? image
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
        guard let user = serverModel?.connectedUser() else { return }
        
        // 当用户听障时，不允许单独取消静音
        if user.isSelfDeafened() { return }
        
        let newMuteState = !user.isSelfMuted()
        
        serverModel?.setSelfMuted(newMuteState, andSelfDeafened: user.isSelfDeafened())
        
        updateUserBySession(
            user.session()
        )
        
        systemMuteManager.setSystemMute(newMuteState)
        
        updateLiveActivity()
    }
    func toggleSelfDeafen() {
        guard let user = serverModel?.connectedUser() else { return }
        
        // 判断当前是否处于听障状态
        let currentlyDeafened = user.isSelfDeafened()
        
        if currentlyDeafened {
            // 取消听障 -> 恢复旧状态
            serverModel?.setSelfMuted(self.muteStateBeforeDeafen, andSelfDeafened: false)
            // ✅ 同步恢复后的状态给系统
            systemMuteManager.setSystemMute(self.muteStateBeforeDeafen)
        } else {
            // 开启听障 -> 强制静音
            self.muteStateBeforeDeafen = user.isSelfMuted()
            serverModel?.setSelfMuted(true, andSelfDeafened: true)
            // ✅ 强制系统静音
            systemMuteManager.setSystemMute(true)
        }
        
        // 无论哪种情况，都立刻主动刷新UI
        updateUserBySession(user.session())
        
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
    
    // MARK: - Audio Control for Settings / Audio Wizard
    
    /// 进入设置界面时调用：临时开启麦克风
    func startAudioTest() {
        // 如果当前已经连接了服务器，说明麦克风本来就开着，不需要做任何事
        if self.isConnected || isLocalAudioTestRunning {
            return
        }
        
        print("🎤 Starting Local Audio for Settings/Testing...")
        isLocalAudioTestRunning = true
        // 调用 ObjC 的 MKAudio
        Task.detached(priority: .userInitiated) {
            MKAudio.shared().restart()
        }
    }
    
    /// 退出设置界面时调用：关闭麦克风
    func stopAudioTest() {
        // 如果当前连接着服务器，绝对不能关麦，否则通话断了
        if self.isConnected {
            print("🎤 Connected to server, keeping audio active.")
            return
        }
        
        if !isLocalAudioTestRunning {
            return
        }
        
        print("🎤 Stopping Local Audio (Settings closed)...")
        isLocalAudioTestRunning = false
        // 关闭引擎并释放 AudioSession
        Task.detached(priority: .userInitiated) {
            MKAudio.shared().stop()
            
            // 显式停用 Session 以消除橙色点
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                print("⚠️ Failed to deactivate session: \(error)")
            }
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
        Task { @MainActor in
            await recursiveRestore(channel: root)
        }
    }
    
    private func recursiveRestore(channel: MKChannel) async {
        // 1. 恢复当前频道的用户
        if let users = channel.users() as? [MKUser] {
            for user in users {
                applySavedUserPreferences(user: user)
            }
        }
        
        await Task.yield()
        
        // 2. 递归子频道
        if let subs = channel.channels() as? [MKChannel] {
            for sub in subs {
                await recursiveRestore(channel: sub)
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
