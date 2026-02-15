// 文件: ServerModelManager.swift (已添加 serverName 属性)

import SwiftUI
import UserNotifications
import AudioToolbox
#if os(iOS)
import ActivityKit
#endif

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
    
    /// 跟踪哪些频道有密码保护（通过 ACL 检测到 deny Enter for @all + grant Enter for #token）
    @Published var channelsWithPassword: Set<UInt> = []
    
    /// 跟踪当前用户有权进入的频道（通过 PermissionQuery 检测到有 Enter 权限）
    @Published var channelsUserCanEnter: Set<UInt> = []
    
    /// 存储每个频道的权限位（通过 PermissionQuery 获得），用于精确的权限检查
    @Published var channelPermissions: [UInt: UInt32] = [:]
    
    /// 跟踪正在被监听的频道 ID 集合（本用户）
    @Published var listeningChannels: Set<UInt> = []
    
    /// 跟踪所有用户的监听状态：channelId -> [userSession]
    @Published var channelListeners: [UInt: Set<UInt>] = [:]

    /// ACL 页面用的 UserID -> 用户名缓存（包含离线已注册用户）
    @Published var aclUserNamesById: [Int: String] = [:]
    
    /// 用于密码输入弹窗的状态
    @Published var passwordPromptChannel: MKChannel? = nil
    @Published var pendingPasswordInput: String = ""
    
    /// "Move to..." 模式：当前正在被移动的用户（非 nil 时进入频道选择模式）
    @Published var movingUser: MKUser? = nil
    
    /// ACL 扫描期间抑制 permission denied 通知
    private var isScanningACLs: Bool = false
    private var pendingACLUserNameQueries: Set<Int> = []
    
    private let tokenHolder = ObserverTokenHolder()
    private var delegateToken: DelegateToken?
    private var muteStateBeforeDeafen: Bool = false
    /// 保存重连前的监听频道 ID，重连后自动重新注册
    private var savedListeningChannelIds: Set<UInt> = []
    private var serverModel: MKServerModel?
    private var userIndexMap: [UInt: Int] = [:]
    private var channelIndexMap: [UInt: Int] = [:]
    private var delegateWrapper: ServerModelDelegateWrapper?
    #if os(iOS)
    private var liveActivity: Activity<MumbleActivityAttributes>?
    #endif
    private var keepAliveTimer: Timer?
    private let systemMuteManager = SystemMuteManager()
    private var isRestoringMuteState = false
    /// 音频重启前保存的闭麦/不听状态（防止系统回调覆盖）
    private var savedMuteBeforeRestart: Bool?
    private var savedDeafenBeforeRestart: Bool?
    /// 追踪每个用户的 mute/deafen 状态，用于检测变化并生成系统消息
    private var previousMuteStates: [UInt: (isSelfMuted: Bool, isSelfDeafened: Bool)] = [:]
    
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
        // SystemMute 和 AudioRoute 只在实际连接到服务器后才激活，
        // 避免在欢迎界面插入耳机时触发麦克风激活
        if serverModel != nil {
            setupSystemMute()
            #if os(iOS)
            setupAudioRouteObservation()
            #endif
        }
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
        #if os(iOS)
        // iOS: 前台直接播放音效（不弹系统通知），后台发系统通知
        if UIApplication.shared.applicationState == .active {
            AudioServicesPlayAlertSound(1000)
            return
        }
        #endif
        // macOS: 始终发送系统通知（前台也发，由 willPresent delegate 控制展示方式和音效）
        // iOS 后台: 也发送系统通知
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
        
        // 发布 Handoff Activity，让其他设备可以接力
        publishHandoffActivity()
        
        // 服务器模型绑定成功后，才激活音频相关的监听
        setupSystemMute()
        #if os(iOS)
        setupAudioRouteObservation()
        #endif
        
        // 监听 Handoff 恢复用户音频偏好的通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHandoffRestoreUserPreferences),
            name: MumbleHandoffRestoreUserPreferencesNotification,
            object: nil
        )
    }
    
    func cleanup() {
        print("🧹 ServerModelManager: CLEANUP (Data Only)")
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        
        userVolumes.removeAll()
        previousMuteStates.removeAll()
        channelsWithPassword.removeAll()
        channelsUserCanEnter.removeAll()
        channelPermissions.removeAll()
        aclUserNamesById.removeAll()
        pendingACLUserNameQueries.removeAll()
        // 保存当前监听频道以便重连后恢复
        if !listeningChannels.isEmpty {
            savedListeningChannelIds = listeningChannels
            print("💾 Saved \(savedListeningChannelIds.count) listening channels for reconnect")
        }
        listeningChannels.removeAll()
        channelListeners.removeAll()
        movingUser = nil
        passwordPromptChannel = nil
        pendingPasswordInput = ""
        
        self.delegateToken = nil
        self.serverModel = nil
        modelItems = []
        userIndexMap = [:]
        channelIndexMap = [:]
        isConnected = false
        serverName = nil
        
        systemMuteManager.cleanup()
        #if os(iOS)
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
        #endif
        NotificationCenter.default.removeObserver(self, name: MumbleHandoffRestoreUserPreferencesNotification, object: nil)
        endLiveActivity()
        
        // 停止广播 Handoff Activity
        HandoffManager.shared.invalidateActivity()
    }
    
    // MARK: - Handoff User Preferences Restore
    
    @objc private func handleHandoffRestoreUserPreferences() {
        restoreAllUserPreferences()
    }
    
    // MARK: - Audio Route Handling (Hot-swap Support)
    
    #if os(iOS)
    private func setupAudioRouteObservation() {
        // 先移除旧的，防止重复注册
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioRouteChanged),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }
    
    @objc private func handleAudioRouteChanged(_ notification: Notification) {
        // 未连接到服务器时不处理音频路由变化
        guard serverModel != nil else { return }
        
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
            
        case .oldDeviceUnavailable:
            // 🔒 拔耳机：同样需要上锁并恢复闭麦状态
            self.isRestoringMuteState = true
            
            print("🎧 Device Removed. Restoring mute state...")
            
            Task { @MainActor in
                // 等待音频路由切换稳定
                try? await Task.sleep(nanoseconds: 500_000_000)
                
                self.systemMuteManager.cleanup()
                self.systemMuteManager.activate()
                
                if let user = self.serverModel?.connectedUser() {
                    let targetState = user.isSelfMuted()
                    print("🔄 Syncing App State (\(targetState)) to Speaker after device removal...")
                    self.systemMuteManager.setSystemMute(targetState)
                }
                
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.isRestoringMuteState = false
            }
            
        case .categoryChange:
            break
            
        default:
            break
        }
    }
    #endif
    
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
    
    // MARK: - Handoff (接力)
    
    /// 发布 Handoff Activity，让其他设备可以接力
    private func publishHandoffActivity() {
        guard let model = serverModel,
              let connectedUser = model.connectedUser() else { return }

        let shouldSyncLocalAudio = UserDefaults.standard.object(forKey: MumbleHandoffSyncLocalAudioSettingsKey) as? Bool ?? true
        
        let hostname = model.hostname() ?? ""
        let port = Int(model.port())
        let username = connectedUser.userName() ?? ""
        let channelId = connectedUser.channel()?.channelId()
        let channelName = connectedUser.channel()?.channelName()
        let isSelfMuted = connectedUser.isSelfMuted()
        let isSelfDeafened = connectedUser.isSelfDeafened()
        
        // 收集当前所有用户的本地音频设置（非默认值的）
        var audioSettings: [HandoffUserAudioSetting] = []
        if shouldSyncLocalAudio, let rootChannel = model.rootChannel() {
            collectUserAudioSettings(in: rootChannel, settings: &audioSettings)
        }
        
        HandoffManager.shared.publishActivity(
            hostname: hostname,
            port: port,
            username: username,
            password: nil, // 不传递密码以保安全，收藏中已有密码的服务器会自动使用
            channelId: channelId != nil ? Int(channelId!) : nil,
            channelName: channelName,
            displayName: serverName,
            isSelfMuted: isSelfMuted,
            isSelfDeafened: isSelfDeafened,
            userAudioSettings: audioSettings
        )
    }
    
    /// 递归收集所有用户的本地音频设置
    private func collectUserAudioSettings(in channel: MKChannel, settings: inout [HandoffUserAudioSetting]) {
        if let users = channel.users() as? [MKUser] {
            for user in users {
                let volume = userVolumes[user.session()] ?? 1.0
                let isMuted = user.isLocalMuted()
                if let name = user.userName() {
                    settings.append(HandoffUserAudioSetting(
                        userName: name,
                        volume: volume,
                        isLocalMuted: isMuted
                    ))
                }
            }
        }
        if let subChannels = channel.channels() as? [MKChannel] {
            for sub in subChannels {
                collectUserAudioSettings(in: sub, settings: &settings)
            }
        }
    }
    
    private func startLiveActivity() {
        #if os(iOS)
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
        #endif
    }
    
    private func updateLiveActivity() {
        #if os(iOS)
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
        
        // 7. 同步更新 Handoff Activity 的音频状态
        updateHandoffAudioState()
        #endif
    }
    
    /// 收集当前用户音频设置并更新 Handoff Activity
    private func updateHandoffAudioState() {
        guard let model = serverModel,
              let connectedUser = model.connectedUser() else { return }

        let shouldSyncLocalAudio = UserDefaults.standard.object(forKey: MumbleHandoffSyncLocalAudioSettingsKey) as? Bool ?? true
        
        var audioSettings: [HandoffUserAudioSetting] = []
        if shouldSyncLocalAudio, let rootChannel = model.rootChannel() {
            collectUserAudioSettings(in: rootChannel, settings: &audioSettings)
        }
        
        HandoffManager.shared.updateActivityAudioState(
            isSelfMuted: connectedUser.isSelfMuted(),
            isSelfDeafened: connectedUser.isSelfDeafened(),
            userAudioSettings: audioSettings
        )
    }
    
    private func endLiveActivity() {
        #if os(iOS)
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
        #endif
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
            let mover = userInfo["mover"] as? MKUser
            let userTransfer = UnsafeTransfer(value: user)
            let channelTransfer = UnsafeTransfer(value: channel)
            let moverTransfer = mover.map { UnsafeTransfer(value: $0) }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let safeUser = userTransfer.value
                let safeChannel = channelTransfer.value
                let safeMover = moverTransfer?.value
                let movingUserSession = safeUser.session()
                let movingUserName = safeUser.userName() ?? "Unknown"
                let destChannelName = safeChannel.channelName() ?? "Unknown Channel"
                let destChannelId = safeChannel.channelId()
                if let connectedUser = self.serverModel?.connectedUser() {
                    if movingUserSession == connectedUser.session() {
                        // 如果是通过密码进入的频道，标记为密码频道（橙色锁）
                        if let pendingId = self.pendingPasswordChannelId, pendingId == destChannelId {
                            self.channelsWithPassword.insert(destChannelId)
                            self.pendingPasswordChannelId = nil
                        }
                        
                        // 区分自己移动和被管理员移动
                        let movedBySelf = (safeMover == nil || safeMover?.session() == connectedUser.session())
                        if movedBySelf {
                            self.addSystemNotification("You moved to channel \(destChannelName)", category: .userMoved, suppressPush: true)
                        } else {
                            let moverName = safeMover?.userName() ?? "admin"
                            self.addSystemNotification("You were moved to channel \(destChannelName) by \(moverName)", category: .movedByAdmin)
                        }
                        
                        // 更新 Handoff Activity 的频道信息
                        HandoffManager.shared.updateActivityChannel(
                            channelId: Int(destChannelId),
                            channelName: destChannelName
                        )
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
                                self.addSystemNotification("\(movingUserName) moved to \(destChannelName)", category: .userMoved)
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
                let category: SystemNotifyCategory = self.isUserInSameChannelAsMe(safeUser) ? .userJoinedSameChannel : .userJoinedOtherChannels
                self.addSystemNotification("\(userName) connected", category: category)
                self.rebuildModelArray()
            }
        })
        
        tokenHolder.add(center.addObserver(forName: ServerModelNotificationManager.userLeftNotification, object: nil, queue: nil) { [weak self] notification in
            guard let userInfo = notification.userInfo, let user = userInfo["user"] as? MKUser else { return }
            let userTransfer = UnsafeTransfer(value: user)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let safeUser = userTransfer.value
                let userName = safeUser.userName() ?? "Unknown User"
                let category: SystemNotifyCategory = self.isUserInSameChannelAsMe(safeUser) ? .userLeftSameChannel : .userLeftOtherChannels
                self.addSystemNotification("\(userName) disconnected", category: category)
                let session = safeUser.session()
                // 清除离开用户的监听状态
                for (channelId, var listeners) in self.channelListeners {
                    listeners.remove(session)
                    if listeners.isEmpty {
                        self.channelListeners.removeValue(forKey: channelId)
                    } else {
                        self.channelListeners[channelId] = listeners
                    }
                }
            }
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
                
                #if os(macOS)
                // macOS 分栏模式：前台即已读，只在非活跃窗口时累计未读
                if !NSApplication.shared.isActive {
                    AppState.shared.unreadMessageCount += 1
                } else {
                    // 前台活跃时不累计未读数；延迟清理通知中心，让横幅有时间显示
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
                    }
                }
                #else
                if AppState.shared.currentTab != .messages {
                    AppState.shared.unreadMessageCount += 1
                }
                #endif
            }
        })
        
        // 私聊消息接收
        tokenHolder.add(center.addObserver(forName: ServerModelNotificationManager.privateMessageReceivedNotification, object: nil, queue: nil) { [weak self] notification in
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
                
                // 忽略自己发给自己的回显
                if senderSession == connectedUserSession {
                    return
                }
                
                let images = imageData.compactMap { PlatformImage(data: $0) }
                
                let pmMessage = ChatMessage(
                    type: .privateMessage,
                    senderName: senderName,
                    attributedMessage: self.attributedString(from: plainText),
                    images: images,
                    timestamp: Date(),
                    isSentBySelf: false,
                    privatePeerName: senderName
                )
                self.messages.append(pmMessage)
                
                // 发送通知
                let defaults = UserDefaults.standard
                let notifyEnabled: Bool = {
                    if let v = defaults.object(forKey: "NotificationNotifyPrivateMessages") as? Bool { return v }
                    return defaults.object(forKey: "NotificationNotifyUserMessages") as? Bool ?? true
                }()
                if notifyEnabled {
                    let bodyText = plainText.isEmpty ? "[Image]" : plainText
                    self.sendLocalNotification(title: "PM from \(senderName)", body: bodyText)
                }
                
                #if os(macOS)
                if !NSApplication.shared.isActive {
                    AppState.shared.unreadMessageCount += 1
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
                    }
                }
                #else
                if AppState.shared.currentTab != .messages {
                    AppState.shared.unreadMessageCount += 1
                }
                #endif
            }
        })
        
        // 权限拒绝通知
        tokenHolder.add(center.addObserver(forName: ServerModelNotificationManager.permissionDeniedNotification, object: nil, queue: nil) { [weak self] notification in
            let reason = notification.userInfo?["reason"] as? String
            let permRaw = notification.userInfo?["permission"] as? UInt32
            let channel = notification.userInfo?["channel"] as? MKChannel
            let channelTransfer = channel.map { UnsafeTransfer(value: $0) }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                
                // 检测是否为 Enter 权限被拒绝
                let isEnterDenied = permRaw.map { ($0 & MKPermissionEnter.rawValue) != 0 } ?? false
                let deniedChannelId = channelTransfer?.value.channelId()
                let isUserInitiated = deniedChannelId != nil && deniedChannelId == self.userInitiatedJoinChannelId
                
                // ACL 扫描期间抑制后台扫描的 permission denied（但不抑制用户主动加入的）
                if self.isScanningACLs && !isUserInitiated { return }
                
                if isEnterDenied, let ct = channelTransfer {
                    let ch = ct.value
                    // 清除主动加入标记
                    if isUserInitiated { self.userInitiatedJoinChannelId = nil }
                    // 弹出密码提示框
                    self.passwordPromptChannel = ch
                    self.pendingPasswordInput = ""
                    self.addSystemNotification("Access denied. You may try entering a password.")
                } else if let reason = reason {
                    self.addSystemNotification("Permission denied: \(reason)")
                } else {
                    self.addSystemNotification("Permission denied")
                }
            }
        })
        
        // ACL 接收通知 - 检测频道是否有密码保护
        tokenHolder.add(center.addObserver(forName: ServerModelNotificationManager.aclReceivedNotification, object: nil, queue: nil) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let accessControl = userInfo["accessControl"] as? MKAccessControl,
                  let channel = userInfo["channel"] as? MKChannel else { return }
            let channelTransfer = UnsafeTransfer(value: channel)
            let aclTransfer = UnsafeTransfer(value: accessControl)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.updatePasswordStatus(for: channelTransfer.value, from: aclTransfer.value)
            }
        })
        
        // 新频道添加时自动扫描其权限
        tokenHolder.add(center.addObserver(forName: ServerModelNotificationManager.channelAddedNotification, object: nil, queue: nil) { [weak self] notification in
            guard let channel = notification.userInfo?["channel"] as? MKChannel else { return }
            let channelTransfer = UnsafeTransfer(value: channel)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // 请求权限查询（所有用户可用）
                self.serverModel?.requestPermission(for: channelTransfer.value)
                // 管理员还请求 ACL（用于区分密码和权限限制）
                if let connectedUser = self.serverModel?.connectedUser(), connectedUser.isAuthenticated() {
                    self.serverModel?.requestAccessControl(for: channelTransfer.value)
                }
            }
        })
        
        // PermissionQuery 结果 - 更新频道权限和限制状态后刷新 UI
        tokenHolder.add(center.addObserver(forName: ServerModelNotificationManager.permissionQueryResultNotification, object: nil, queue: nil) { [weak self] notification in
            guard let channel = notification.userInfo?["channel"] as? MKChannel,
                  let permissions = notification.userInfo?["permissions"] as? UInt32 else { return }
            let channelTransfer = UnsafeTransfer(value: channel)
            let channelId = channel.channelId()
            let hasEnter = (permissions & MKPermissionEnter.rawValue) != 0
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // 存储此频道的完整权限位
                self.channelPermissions[channelId] = permissions
                // 记录用户有权进入的频道
                if hasEnter {
                    self.channelsUserCanEnter.insert(channelId)
                } else {
                    self.channelsUserCanEnter.remove(channelId)
                }
                self.rebuildModelArray()
            }
        })

        // QueryUsers 结果：离线注册用户名解析（UserID -> Name）
        tokenHolder.add(center.addObserver(forName: ServerModelNotificationManager.aclUserNamesResolvedNotification, object: nil, queue: nil) { [weak self] notification in
            let raw = notification.userInfo?["userNamesById"]
            var resolved: [Int: String] = [:]
            if let typed = raw as? [NSNumber: String] {
                for (key, value) in typed {
                    resolved[key.intValue] = value
                }
            } else if let dict = raw as? NSDictionary {
                for (key, value) in dict {
                    if let idNum = key as? NSNumber, let name = value as? String {
                        resolved[idNum.intValue] = name
                    }
                }
            }
            guard !resolved.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                for (id, name) in resolved {
                    self.aclUserNamesById[id] = name
                    self.pendingACLUserNameQueries.remove(id)
                }
            }
        })
        
        // 监听频道变更通知（来自服务器回传的 UserState）
        tokenHolder.add(center.addObserver(forName: NSNotification.Name("MKListeningChannelAddNotification"), object: nil, queue: nil) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let user = userInfo["user"] as? MKUser,
                  let addChannels = userInfo["addChannels"] as? [NSNumber] else { return }
            let userTransfer = UnsafeTransfer(value: user)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let u = userTransfer.value
                let session = u.session()
                let isMyself = (session == MUConnectionController.shared()?.serverModel?.connectedUser()?.session())
                
                for channelIdNum in addChannels {
                    let channelId = channelIdNum.uintValue
                    
                    // 如果是自己，且 listeningChannels 中没有此频道（说明我们已经 stopListening 了），
                    // 跳过服务器的延迟回传，防止竞态条件导致监听行重新出现
                    if isMyself && !self.listeningChannels.contains(channelId) {
                        // 服务器确认添加监听 → 同步到 listeningChannels
                        self.listeningChannels.insert(channelId)
                    }
                    
                    var listeners = self.channelListeners[channelId] ?? Set()
                    listeners.insert(session)
                    self.channelListeners[channelId] = listeners
                }
                // 检查是否有人开始监听我所在的频道 → 通知
                if let myChannel = MUConnectionController.shared()?.serverModel?.connectedUser()?.channel(),
                   !isMyself {
                    for channelIdNum in addChannels {
                        if channelIdNum.uintValue == myChannel.channelId() {
                            let userName = u.userName() ?? "Someone"
                            self.addSystemNotification("\(userName) started listening to your channel", category: .channelListening)
                        }
                    }
                }
                self.rebuildModelArray()
            }
        })
        
        tokenHolder.add(center.addObserver(forName: NSNotification.Name("MKListeningChannelRemoveNotification"), object: nil, queue: nil) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let user = userInfo["user"] as? MKUser,
                  let removeChannels = userInfo["removeChannels"] as? [NSNumber] else { return }
            let userTransfer = UnsafeTransfer(value: user)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let u = userTransfer.value
                let session = u.session()
                let isMyself = (session == MUConnectionController.shared()?.serverModel?.connectedUser()?.session())
                
                for channelIdNum in removeChannels {
                    let channelId = channelIdNum.uintValue
                    self.channelListeners[channelId]?.remove(session)
                    if self.channelListeners[channelId]?.isEmpty == true {
                        self.channelListeners.removeValue(forKey: channelId)
                    }
                    // 如果是自己被服务器移除监听（管理员操作或频道删除），同步更新 listeningChannels
                    if isMyself {
                        self.listeningChannels.remove(channelId)
                    }
                }
                // 检查是否有人停止监听我所在的频道 → 通知
                if let myChannel = MUConnectionController.shared()?.serverModel?.connectedUser()?.channel(),
                   !isMyself {
                    for channelIdNum in removeChannels {
                        if channelIdNum.uintValue == myChannel.channelId() {
                            let userName = u.userName() ?? "Someone"
                            self.addSystemNotification("\(userName) stopped listening to your channel", category: .channelListening)
                        }
                    }
                }
                self.rebuildModelArray()
            }
        })
        
        // 音频设置即将变更 → 保存当前闭麦状态，防止系统回调在 restart 期间覆盖
        center.addObserver(self, selector: #selector(handlePreferencesAboutToChange), name: NSNotification.Name("MumblePreferencesChanged"), object: nil)
        
        // 音频引擎重启后恢复闭麦/不听状态（修改音频设置时 MKAudio.restart() 会重置音频输入）
        tokenHolder.add(center.addObserver(forName: NSNotification.Name.MKAudioDidRestart, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.restoreMuteDeafenStateAfterAudioRestart()
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
            
            // 连接初期立即开始抑制 permission denied
            // （ACL 扫描和初始权限同步期间，服务器会发送大量 PermissionDenied）
            self.isScanningACLs = true
            
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
                
                // 延迟 2s 后扫描频道权限（确保频道树已完全构建）
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s
                await MainActor.run {
                    print("🔐 [Async] Scanning channel permissions...")
                    self.scanAllChannelPermissions()
                }
                
                // 延迟 1s 后恢复之前的监听（确保频道树和权限扫描已完成）
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
                await MainActor.run {
                    self.reRegisterListeningChannels()
                }
            }
        }
    }
    
    /// 系统通知分类，每类对应一个独立的 UserDefaults 开关
    enum SystemNotifyCategory: String {
        case userJoinedSameChannel    = "NotifyUserJoinedSameChannel"
        case userLeftSameChannel      = "NotifyUserLeftSameChannel"
        case userJoinedOtherChannels  = "NotifyUserJoinedOtherChannels"
        case userLeftOtherChannels    = "NotifyUserLeftOtherChannels"
        case userMoved        = "NotifyUserMoved"
        case muteDeafen       = "NotifyMuteDeafen"
        case movedByAdmin     = "NotifyMovedByAdmin"
        case channelListening = "NotifyChannelListening"
        
        var defaultEnabled: Bool {
            switch self {
            case .userJoinedSameChannel, .userLeftSameChannel, .userMoved, .movedByAdmin, .channelListening:
                return true
            case .userJoinedOtherChannels, .userLeftOtherChannels, .muteDeafen:
                return false
            }
        }
    }
    
    /// 添加系统消息到聊天区域，并根据分类开关决定是否发送系统推送通知
    /// - Parameters:
    ///   - text: 消息文本
    ///   - category: 通知分类（nil 则不推送）
    ///   - suppressPush: 为 true 时只在聊天区域显示，不发送系统推送（用于自己的操作）
    private func addSystemNotification(_ text: String, category: SystemNotifyCategory? = nil, suppressPush: Bool = false) {
        let didAppend = appendNotificationMessage(text: text, senderName: "System")
        
        guard didAppend, !suppressPush else { return }
        
        // 如果指定了分类，检查该分类的独立开关（默认开启）
        // 如果未指定分类（如 "Connected to server"），不发送推送
        if let category = category {
            let shouldNotify = UserDefaults.standard.object(forKey: category.rawValue) as? Bool ?? category.defaultEnabled
            if shouldNotify {
                sendLocalNotification(title: currentNotificationTitle, body: text)
            }
        }
    }

    private func isUserInSameChannelAsMe(_ user: MKUser) -> Bool {
        guard let myChannelId = serverModel?.connectedUser()?.channel()?.channelId() else {
            return false
        }
        if let directUserChannelId = user.channel()?.channelId() {
            return directUserChannelId == myChannelId
        }
        guard let inferredUserChannelId = inferredChannelId(forUserSession: user.session()) else {
            return false
        }
        return inferredUserChannelId == myChannelId
    }

    private func inferredChannelId(forUserSession session: UInt) -> UInt? {
        guard let userIndex = userIndexMap[session],
              userIndex > 0,
              userIndex < modelItems.count else {
            return nil
        }
        let userItem = modelItems[userIndex]
        for i in stride(from: userIndex - 1, through: 0, by: -1) {
            let item = modelItems[i]
            if item.type == .channel && item.indentLevel < userItem.indentLevel {
                return (item.object as? MKChannel)?.channelId()
            }
        }
        return nil
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
    private func appendUserMessage(senderName: String, text: String, isSentBySelf: Bool, images: [PlatformImage] = []) -> Bool {
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
        let images = imageData.compactMap { PlatformImage(data: $0) }
        
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
            let defaults = UserDefaults.standard
            let notifyEnabled: Bool = {
                if let v = defaults.object(forKey: "NotificationNotifyNormalUserMessages") as? Bool { return v }
                return defaults.object(forKey: "NotificationNotifyUserMessages") as? Bool ?? true
            }()
            
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
    
    // MARK: - 私聊发送
    
    func sendPrivateMessage(_ text: String, to user: MKUser) {
        guard let serverModel = serverModel, !text.isEmpty else { return }
        
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        
        let htmlMessage = MUTextMessageProcessor.processedHTML(fromPlainTextMessage: trimmedText)
        let message = MKTextMessage(string: htmlMessage)
        
        serverModel.send(message, to: user)
        
        // 立即在 UI 上显示自己发送的私聊
        let targetName = user.userName() ?? "Unknown"
        let selfMessage = ChatMessage(
            type: .privateMessage,
            senderName: serverModel.connectedUser()?.userName() ?? "Me",
            attributedMessage: attributedString(from: trimmedText),
            timestamp: Date(),
            isSentBySelf: true,
            privatePeerName: targetName
        )
        messages.append(selfMessage)
    }
    
    func sendImageMessage(image: PlatformImage, isHighQuality: Bool) async {
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
    private func attemptSendImage(image: PlatformImage, targetSize: Int, decayRate: Double) async {
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
    private func appendLocalMessage(image: PlatformImage) async {
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
    
    // MARK: - 智能压缩算法（先降分辨率再降质量，优先保画质）
    private func smartCompress(image: PlatformImage, to maxBytes: Int) async -> Data? {
        // 1. 预检查：如果原图已经很小，直接返回
        if let data = image.jpegData(compressionQuality: 1.0), data.count <= maxBytes {
            return data
        }
        
        // 2. 获取实际像素尺寸
        #if os(iOS)
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        #else
        let pixelWidth = image.size.width
        let pixelHeight = image.size.height
        #endif
        let maxDim = max(pixelWidth, pixelHeight)
        
        // 3. 渐进式策略：先尝试当前分辨率，质量降到阈值后改为降分辨率
        // 分辨率梯度：从原始尺寸开始，逐级缩小
        var resolutionTiers: [CGFloat] = []
        // 第一级：如果原图超过 2048，先降到 2048
        if maxDim > 2048 {
            resolutionTiers.append(2048)
        } else {
            resolutionTiers.append(maxDim) // 保持原始分辨率
        }
        // 后续梯度
        for dim in [1536, 1024, 768, 512] as [CGFloat] {
            if dim < resolutionTiers.last! {
                resolutionTiers.append(dim)
            }
        }
        
        for tier in resolutionTiers {
            // 获取当前梯度的工作图片
            let workingImage: PlatformImage
            if tier < maxDim {
                workingImage = resizeImage(image: image, maxDimension: tier)
            } else {
                workingImage = image
            }
            
            // 二分法查找最佳质量（8 次迭代，精度 ~0.004）
            var lo: CGFloat = 0.05
            var hi: CGFloat = 1.0
            var bestData: Data? = nil
            var bestQuality: CGFloat = 0
            
            for _ in 0..<8 {
                let mid = (lo + hi) / 2
                if let data = workingImage.jpegData(compressionQuality: mid) {
                    if data.count <= maxBytes {
                        bestData = data
                        bestQuality = mid
                        lo = mid // 尝试更好的质量
                    } else {
                        hi = mid // 降低质量
                    }
                }
            }
            
            if let data = bestData {
                // 如果质量 >= 0.3 或者已经是最小分辨率了，接受此结果
                if bestQuality >= 0.3 || tier <= 512 {
                    let tierStr = tier < maxDim ? "resized to \(Int(tier))px" : "original"
                    print("📸 Compressed: \(tierStr), quality=\(String(format: "%.2f", bestQuality)), size=\(data.count/1024)KB")
                    return data
                }
                // 质量太低，尝试下一级更小的分辨率以获得更好的画质
                print("📸 Quality \(String(format: "%.2f", bestQuality)) too low at \(Int(tier))px, trying smaller resolution...")
                continue
            }
            // 在此分辨率下即使质量最低也不行，继续降分辨率
        }
        
        // 4. 兜底：最小分辨率 + 最低质量
        print("⚠️ Fallback: minimum resolution + minimum quality")
        let smallest = resizeImage(image: image, maxDimension: 512)
        return smallest.jpegData(compressionQuality: 0.2)
    }
    
    /// 保持比例缩放图片（指定长边最大像素数），修复白色边线问题
    private func resizeImage(image: PlatformImage, maxDimension: CGFloat) -> PlatformImage {
        #if os(iOS)
        // 使用实际像素尺寸而非 point 尺寸
        let pixelW = image.size.width * image.scale
        let pixelH = image.size.height * image.scale
        #else
        let pixelW = image.size.width
        let pixelH = image.size.height
        #endif
        
        let currentMax = max(pixelW, pixelH)
        guard currentMax > maxDimension else { return image }
        
        let ratio = maxDimension / currentMax
        // 关键：向下取整到整数像素，防止浮点精度导致右侧/底部出现白色像素列
        let newW = floor(pixelW * ratio)
        let newH = floor(pixelH * ratio)
        let newSize = CGSize(width: newW, height: newH)
        
        #if os(iOS)
        // opaque: true（JPEG 不需要透明通道，避免边缘透明→白线）
        // scale: 1.0（直接按像素操作，不受屏幕 scale 影响）
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { context in
            // 先填充白色背景确保无透明区域
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: newSize))
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        #else
        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        // 填充白色背景
        NSColor.white.setFill()
        NSRect(origin: .zero, size: newSize).fill()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .sourceOver, fraction: 1.0)
        newImage.unlockFocus()
        return newImage
        #endif
    }
    
    func updateUserBySession(
        _ session: UInt
    ) {
        guard let index = userIndexMap[session], index < modelItems.count,
              let user = modelItems[index].object as? MKUser else {
            return
        }
        
        // 检测 mute/deafen 状态变化，生成系统消息
        let currentMuted = user.isSelfMuted()
        let currentDeafened = user.isSelfDeafened()
        
        if let prev = previousMuteStates[session] {
            // 判断是否需要通知：自己的变化始终通知，他人的变化只在同频道时通知
            let isSelf = serverModel?.connectedUser()?.session() == session
            let isInSameChannel: Bool = {
                guard let myChannelId = serverModel?.connectedUser()?.channel()?.channelId(),
                      let theirChannelId = user.channel()?.channelId() else { return false }
                return myChannelId == theirChannelId
            }()
            
            if isSelf || isInSameChannel {
                let displayName = isSelf ? "You" : (user.userName() ?? "Unknown")
                
                if prev.isSelfDeafened != currentDeafened {
                    // 不听状态变化（优先级高于闭麦，因为 deafen 隐含 mute）
                    let action = currentDeafened ? "deafened" : "undeafened"
                    addSystemNotification("\(displayName) \(action)", category: .muteDeafen, suppressPush: isSelf)
                } else if prev.isSelfMuted != currentMuted {
                    // 闭麦状态变化
                    let action = currentMuted ? "muted" : "unmuted"
                    addSystemNotification("\(displayName) \(action)", category: .muteDeafen, suppressPush: isSelf)
                }
            }
        }
        previousMuteStates[session] = (isSelfMuted: currentMuted, isSelfDeafened: currentDeafened)
        
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
        ); item.state = state
        // 初始化 mute/deafen 状态追踪（首次见到用户时记录，不触发通知）
        if previousMuteStates[user.session()] == nil {
            previousMuteStates[user.session()] = (isSelfMuted: user.isSelfMuted(), isSelfDeafened: user.isSelfDeafened())
        }
        updateUserTalkingState(
            userSession: user
                .session(),
            talkState: user
                .talkState()
        ); if let connectedUser = serverModel?.connectedUser(),
              connectedUser
            .session() == user
            .session() {
            item.isConnectedUser = true
            // 同步认证状态到 AppState，供 macOS 菜单栏等全局 UI 使用
            AppState.shared.isUserAuthenticated = user.isAuthenticated()
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
    /// 音频设置即将变更（MumblePreferencesChanged），在 restart 之前或之后同步保存当前状态
    /// 注意：使用 selector-based observer 确保在同一次 NotificationCenter.post 中同步执行
    @objc private func handlePreferencesAboutToChange() {
        guard let user = serverModel?.connectedUser() else { return }
        // 保存当前的闭麦/不听状态（此时系统回调尚未被处理，状态仍为真实值）
        savedMuteBeforeRestart = user.isSelfMuted()
        savedDeafenBeforeRestart = user.isSelfDeafened()
        isRestoringMuteState = true
        print("🔒 Preferences changing - saved mute state: muted=\(savedMuteBeforeRestart ?? false), deafened=\(savedDeafenBeforeRestart ?? false)")
    }
    
    /// 音频引擎重启后恢复闭麦/不听状态
    /// 使用 handlePreferencesAboutToChange 中保存的状态（而非 user 当前状态，因为系统回调可能已覆盖）
    private func restoreMuteDeafenStateAfterAudioRestart() {
        guard let user = serverModel?.connectedUser() else {
            isRestoringMuteState = false
            savedMuteBeforeRestart = nil
            savedDeafenBeforeRestart = nil
            return
        }
        
        // 优先使用 restart 前保存的状态，若无则使用当前 user 状态
        let targetMuted = savedMuteBeforeRestart ?? user.isSelfMuted()
        let targetDeafened = savedDeafenBeforeRestart ?? user.isSelfDeafened()
        
        print("🔄 Audio restarted - restoring mute state: muted=\(targetMuted), deafened=\(targetDeafened)")
        
        // 如果系统回调已经把状态改错了，强制恢复到正确状态
        if user.isSelfMuted() != targetMuted || user.isSelfDeafened() != targetDeafened {
            print("⚠️ State drifted during restart! Forcing correct state back to server.")
            serverModel?.setSelfMuted(targetMuted, andSelfDeafened: targetDeafened)
            updateUserBySession(user.session())
        }
        
        // 在 iOS 上同步系统层面的闭麦状态（macOS 上 SystemMuteManager 是 no-op）
        systemMuteManager.setSystemMute(targetMuted || targetDeafened)
        
        // 清理保存的状态
        savedMuteBeforeRestart = nil
        savedDeafenBeforeRestart = nil
        
        // 延迟释放锁，确保后续的系统回调也被忽略
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self.isRestoringMuteState = false
            print("🔓 Audio restart state lock released.")
        }
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

        DispatchQueue.main.async {
            CertificateModel.shared.refreshCertificates()
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
            
            #if os(iOS)
            // 显式停用 Session 以消除橙色点
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                print("⚠️ Failed to deactivate session: \(error)")
            }
            #endif
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
    
    // MARK: - Permission Helpers
    
    /// 检查当前用户在指定频道是否拥有某权限
    func hasPermission(_ permission: MKPermission, forChannelId channelId: UInt) -> Bool {
        guard let perms = channelPermissions[channelId] else { return false }
        return (perms & UInt32(permission.rawValue)) != 0
    }
    
    /// 检查当前用户在根频道（全局）是否拥有某权限
    func hasRootPermission(_ permission: MKPermission) -> Bool {
        return hasPermission(permission, forChannelId: 0)
    }
    
    /// 连接后扫描所有频道的权限，检测哪些频道限制进入
    /// 使用 PermissionQuery（所有用户可用），而非 ACL 查询（仅管理员可用）
    func scanAllChannelPermissions() {
        guard let root = serverModel?.rootChannel() else {
            print("🔐 scanAllChannelPermissions: No root channel available")
            return
        }
        var count = 0
        recursiveRequestPermission(channel: root, count: &count)
        print("🔐 scanAllChannelPermissions: Requested permissions for \(count) channels")
        
        // 只有拥有 Write 权限的用户（管理员）才额外请求 ACL 来区分密码频道和纯权限限制频道
        // 普通注册用户不应请求 ACL，否则会收到大量 permission denied
        // 注意：此时 channelPermissions 可能还没收到服务器回复，延迟执行 ACL 扫描
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }
            if self.hasRootPermission(MKPermissionWrite) {
                var aclCount = 0
                self.recursiveRequestACL(channel: root, count: &aclCount)
                print("🔐 scanAllChannelPermissions: Also requested ACL for \(aclCount) channels (admin)")
            } else {
                print("🔐 scanAllChannelPermissions: Skipping ACL requests (no Write permission)")
            }
        }
        
        // 延迟后关闭扫描标记（给服务器足够时间响应）
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.isScanningACLs = false
        }
    }
    
    private func recursiveRequestPermission(channel: MKChannel, count: inout Int) {
        // 对所有频道请求权限查询（轻量级，所有用户可用）
        serverModel?.requestPermission(for: channel)
        count += 1
        // 递归子频道
        if let subs = channel.channels() as? [MKChannel] {
            for sub in subs {
                recursiveRequestPermission(channel: sub, count: &count)
            }
        }
    }
    
    private func recursiveRequestACL(channel: MKChannel, count: inout Int) {
        // 请求所有频道的 ACL（仅管理员能成功）
        serverModel?.requestAccessControl(for: channel)
        count += 1
        // 递归子频道
        if let subs = channel.channels() as? [MKChannel] {
            for sub in subs {
                recursiveRequestACL(channel: sub, count: &count)
            }
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
            if let group = aclItem.group, group.hasPrefix("#") && !group.hasPrefix("#!") &&
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
        // 获取当前已有的 tokens，添加新 token
        var tokens = currentAccessTokens
        if !tokens.contains(password) {
            tokens.append(password)
        }
        currentAccessTokens = tokens
        serverModel?.setAccessTokens(tokens)
        
        // 记录正在尝试用密码进入的频道
        pendingPasswordChannelId = channel.channelId()
        markUserInitiatedJoin(channelId: channel.channelId())
        
        // 稍微延迟后尝试加入频道（让服务器处理 token 更新）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.serverModel?.join(channel)
            
            // 3 秒后清除等待标记（无论是否成功）
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.pendingPasswordChannelId = nil
            }
        }
    }
    
    /// 当前的 access tokens 列表
    private var currentAccessTokens: [String] = []
    
    /// 正在尝试用密码进入的频道 ID（用于成功后标记为密码频道）
    private var pendingPasswordChannelId: UInt? = nil
    
    /// 记录用户在被 server deafen 之前是否已被 server mute（用于 undeafen 时决定是否保留 mute）
    private var wasMutedBeforeServerDeafen: [UInt: Bool] = [:]
    
    /// 用户主动尝试加入的频道 ID（用于在扫描期间仍弹出密码框）
    private var userInitiatedJoinChannelId: UInt? = nil
    
    /// 标记用户主动加入某频道（外部调用）
    func markUserInitiatedJoin(channelId: UInt) {
        userInitiatedJoinChannelId = channelId
        // 3 秒后自动清除
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            if self?.userInitiatedJoinChannelId == channelId {
                self?.userInitiatedJoinChannelId = nil
            }
        }
    }
    
    // MARK: - Channel Listening
    
    /// 重连后恢复之前保存的监听频道
    private func reRegisterListeningChannels() {
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
        serverModel?.addListening(channel)
        listeningChannels.insert(channelId)
        // 同时记录自己为该频道的监听者
        if let mySession = serverModel?.connectedUser()?.session() {
            var listeners = channelListeners[channelId] ?? Set()
            listeners.insert(mySession)
            channelListeners[channelId] = listeners
        }
        // 自动展开被监听的频道（确保监听行可见）
        if isChannelCollapsed(Int(channelId)) {
            toggleChannelCollapse(Int(channelId))
        }
        rebuildModelArray()
    }
    
    /// 停止监听某频道
    func stopListening(to channel: MKChannel) {
        let channelId = channel.channelId()
        serverModel?.removeListening(channel)
        listeningChannels.remove(channelId)
        // 移除自己的监听记录
        if let mySession = serverModel?.connectedUser()?.session() {
            channelListeners[channelId]?.remove(mySession)
            if channelListeners[channelId]?.isEmpty == true {
                channelListeners.removeValue(forKey: channelId)
            }
        }
        rebuildModelArray()
    }
    
    /// 获取某频道的所有监听者用户对象
    func getListeners(for channel: MKChannel) -> [MKUser] {
        guard let sessions = channelListeners[channel.channelId()] else { return [] }
        return sessions.compactMap { session in
            serverModel?.user(withSession: session)
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
            // 记录 deafen 之前的 mute 状态
            wasMutedBeforeServerDeafen[session] = user.isMuted()
            // deafen = 同时 mute + deafen
            serverModel?.setServerMuted(true, for: user)
            serverModel?.setServerDeafened(true, for: user)
        } else {
            // undeafen
            serverModel?.setServerDeafened(false, for: user)
            // 如果 deafen 之前没有被单独 mute，则也 unmute
            let wasMuted = wasMutedBeforeServerDeafen[session] ?? false
            if !wasMuted {
                serverModel?.setServerMuted(false, for: user)
            }
            wasMutedBeforeServerDeafen.removeValue(forKey: session)
        }
    }
}

@objc public class LiveActivityCleanup: NSObject {
    
    /// 阻塞式强制结束所有活动（专用于 App 终止时）
    @objc public static func forceEndAllActivitiesBlocking() {
        #if os(iOS)
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
        #endif
    }
}

#if canImport(UIKit)
extension PlatformImage {
    func resized(by scale: CGFloat) -> PlatformImage? {
        let newSize = CGSize(width: self.size.width * scale, height: self.size.height * scale)
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        self.draw(in: CGRect(origin: .zero, size: newSize))
        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return newImage
    }
}
#endif

extension Notification.Name {
    static let requestReconnect = Notification.Name("MURequestReconnect")
}
