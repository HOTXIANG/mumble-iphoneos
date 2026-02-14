// 文件: HandoffManager.swift
// 实现 Handoff (接力) 功能
// 当设备连接到 Mumble 服务器时，同一 iCloud 账户的其他设备可以通过 Handoff 快速加入同一服务器和频道

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Handoff 使用的 NSUserActivity 类型标识符
let MumbleHandoffActivityType = "info.mumble.Mumble.serverConnection"

/// Handoff 通知：当本设备的 activity 被另一台设备继续时，源设备应断开连接
let MumbleHandoffContinuedNotification = NSNotification.Name("MumbleHandoffContinuedNotification")

/// Handoff 通知：当收到来自其他设备的接力请求时
let MumbleHandoffReceivedNotification = NSNotification.Name("MumbleHandoffReceivedNotification")

/// Handoff 通知：请求 ServerModelManager 重新加载所有用户的音频偏好
let MumbleHandoffRestoreUserPreferencesNotification = NSNotification.Name("MumbleHandoffRestoreUserPreferencesNotification")

/// 用户设置：接力时是否同步本地对其他用户的音量/本地静音（默认开启）
let MumbleHandoffSyncLocalAudioSettingsKey = "HandoffSyncLocalAudioSettings"

// MARK: - HandoffServerInfo

/// 每个用户的音频设置（用于 Handoff 传递）
struct HandoffUserAudioSetting {
    let userName: String
    let volume: Float
    let isLocalMuted: Bool
    
    var dictionary: [String: Any] {
        return [
            "userName": userName,
            "volume": volume,
            "isLocalMuted": isLocalMuted
        ]
    }
    
    init(userName: String, volume: Float, isLocalMuted: Bool) {
        self.userName = userName
        self.volume = volume
        self.isLocalMuted = isLocalMuted
    }
    
    init?(from dict: [String: Any]) {
        guard let userName = dict["userName"] as? String else { return nil }
        self.userName = userName
        self.volume = dict["volume"] as? Float ?? 1.0
        self.isLocalMuted = dict["isLocalMuted"] as? Bool ?? false
    }
}

/// 封装 Handoff 传递的服务器连接信息
struct HandoffServerInfo {
    let hostname: String
    let port: Int
    let username: String
    let password: String?
    let channelId: Int?
    let channelName: String?
    let displayName: String?
    let isSelfMuted: Bool
    let isSelfDeafened: Bool
    let userAudioSettings: [HandoffUserAudioSetting]
    
    /// 从 NSUserActivity 的 userInfo 中解析
    init?(from userInfo: [AnyHashable: Any]?) {
        guard let info = userInfo,
              let hostname = info["hostname"] as? String,
              let port = info["port"] as? Int,
              let username = info["username"] as? String else {
            return nil
        }
        self.hostname = hostname
        self.port = port
        self.username = username
        self.password = info["password"] as? String
        self.channelId = info["channelId"] as? Int
        self.channelName = info["channelName"] as? String
        self.displayName = info["displayName"] as? String
        self.isSelfMuted = info["isSelfMuted"] as? Bool ?? false
        self.isSelfDeafened = info["isSelfDeafened"] as? Bool ?? false
        
        // 解析用户音频设置
        if let settingsArray = info["userAudioSettings"] as? [[String: Any]] {
            self.userAudioSettings = settingsArray.compactMap { HandoffUserAudioSetting(from: $0) }
        } else {
            self.userAudioSettings = []
        }
    }
}

// MARK: - HandoffManager

@MainActor
class HandoffManager: NSObject, ObservableObject {
    
    static let shared = HandoffManager()
    
    /// 当前正在广播的 NSUserActivity（源设备端）
    private var currentActivity: NSUserActivity?
    
    /// 标记是否正在处理接力（防止重入）
    @Published var isProcessingHandoff: Bool = false
    
    /// 需要在连接成功后加入的目标频道 ID
    var pendingChannelId: Int?
    
    /// 需要在连接成功后加入的目标频道名称（备用）
    var pendingChannelName: String?
    
    /// 需要在连接成功后恢复的闭麦/不听状态
    var pendingSelfMuted: Bool = false
    var pendingSelfDeafened: Bool = false
    
    /// 需要在连接成功后应用的用户音频设置
    var pendingUserAudioSettings: [HandoffUserAudioSetting] = []
    
    /// 标记这是一次 Handoff 连接（用于在连接成功后加入频道）
    var isHandoffConnection: Bool = false
    
    private override init() {
        super.init()
        // 监听连接成功通知，用于在 Handoff 连接建立后加入指定频道
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(connectionOpened(_:)),
            name: NSNotification.Name("MUConnectionOpenedNotification"),
            object: nil
        )
    }
    
    // MARK: - 获取当前设备类型后缀
    
    /// 获取当前设备类型字符串（用于用户名后缀）
    static var deviceTypeSuffix: String {
        #if os(macOS)
        return "Mac"
        #else
        if UIDevice.current.userInterfaceIdiom == .pad {
            return "iPad"
        } else {
            return "iOS"
        }
        #endif
    }
    
    // MARK: - 发布 Handoff Activity（源设备端）
    
    /// 当连接到服务器后，开始广播 NSUserActivity 以便其他设备接力
    func publishActivity(
        hostname: String,
        port: Int,
        username: String,
        password: String?,
        channelId: Int?,
        channelName: String?,
        displayName: String?,
        isSelfMuted: Bool = false,
        isSelfDeafened: Bool = false,
        userAudioSettings: [HandoffUserAudioSetting] = []
    ) {
        // 创建新的 NSUserActivity
        let activity = NSUserActivity(activityType: MumbleHandoffActivityType)
        
        // 设置 Handoff 相关属性
        activity.isEligibleForHandoff = true
        activity.title = {
            if let name = displayName, !name.isEmpty {
                return "Continue on \(name)"
            }
            return "Continue on \(hostname)"
        }()
        
        // 构建 userInfo 字典传递服务器信息
        var userInfoDict: [String: Any] = [
            "hostname": hostname,
            "port": port,
            "username": username
        ]
        if let password = password { userInfoDict["password"] = password }
        if let channelId = channelId { userInfoDict["channelId"] = channelId }
        if let channelName = channelName { userInfoDict["channelName"] = channelName }
        if let displayName = displayName { userInfoDict["displayName"] = displayName }
        userInfoDict["isSelfMuted"] = isSelfMuted
        userInfoDict["isSelfDeafened"] = isSelfDeafened
        if !userAudioSettings.isEmpty {
            userInfoDict["userAudioSettings"] = userAudioSettings.map { $0.dictionary }
        }
        
        // 使用非弃用的方式设置 userInfo（需要至少一个必须的 key）
        activity.addUserInfoEntries(from: userInfoDict)
        
        // 需要网络
        activity.needsSave = true
        
        // 设置 delegate 以监听"被继续"事件
        activity.delegate = self
        
        // 使其成为当前 activity
        activity.becomeCurrent()
        self.currentActivity = activity
        
        print("📡 Handoff: Published activity for \(hostname):\(port) as \(username)")
    }
    
    /// 更新正在广播的 activity 的频道信息（当用户切换频道时）
    func updateActivityChannel(channelId: Int?, channelName: String?) {
        guard let activity = currentActivity else { return }
        
        var updatedInfo = activity.userInfo ?? [:]
        if let channelId = channelId {
            updatedInfo["channelId"] = channelId
        } else {
            updatedInfo.removeValue(forKey: "channelId")
        }
        if let channelName = channelName {
            updatedInfo["channelName"] = channelName
        } else {
            updatedInfo.removeValue(forKey: "channelName")
        }
        activity.addUserInfoEntries(from: updatedInfo as! [String : Any])
        activity.needsSave = true
        
        print("📡 Handoff: Updated channel → \(channelName ?? "nil") (id: \(channelId ?? -1))")
    }
    
    /// 更新正在广播的 activity 的闭麦/不听状态和用户音频设置
    func updateActivityAudioState(
        isSelfMuted: Bool,
        isSelfDeafened: Bool,
        userAudioSettings: [HandoffUserAudioSetting] = []
    ) {
        guard let activity = currentActivity else { return }
        
        var updatedInfo = activity.userInfo ?? [:]
        updatedInfo["isSelfMuted"] = isSelfMuted
        updatedInfo["isSelfDeafened"] = isSelfDeafened
        if !userAudioSettings.isEmpty {
            updatedInfo["userAudioSettings"] = userAudioSettings.map { $0.dictionary }
        } else {
            updatedInfo.removeValue(forKey: "userAudioSettings")
        }
        activity.addUserInfoEntries(from: updatedInfo as! [String : Any])
        activity.needsSave = true
    }
    
    /// 停止广播 Handoff activity（断开连接时调用）
    func invalidateActivity() {
        currentActivity?.invalidate()
        currentActivity = nil
        print("📡 Handoff: Activity invalidated")
    }
    
    // MARK: - 处理接收到的 Handoff（目标设备端）
    
    /// 处理从其他设备接力过来的 NSUserActivity
    func handleIncomingActivity(_ userActivity: NSUserActivity) {
        guard userActivity.activityType == MumbleHandoffActivityType else {
            print("⚠️ Handoff: Unknown activity type: \(userActivity.activityType)")
            return
        }
        
        guard let serverInfo = HandoffServerInfo(from: userActivity.userInfo) else {
            print("⚠️ Handoff: Failed to parse server info from userActivity")
            return
        }
        
        print("📲 Handoff: Received activity for \(serverInfo.hostname):\(serverInfo.port)")
        
        isProcessingHandoff = true
        isHandoffConnection = true
        
        // 保存目标频道信息
        pendingChannelId = serverInfo.channelId
        pendingChannelName = serverInfo.channelName
        
        // 保存需要恢复的状态
        pendingSelfMuted = serverInfo.isSelfMuted
        pendingSelfDeafened = serverInfo.isSelfDeafened
        pendingUserAudioSettings = serverInfo.userAudioSettings
        
        // 如果当前已经连接到某个服务器，先断开
        if MUConnectionController.shared()?.isConnected() == true {
            print("📲 Handoff: Disconnecting current server before handoff...")
            MUConnectionController.shared()?.disconnectFromServer()
            // 等待断开后再连接
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.connectForHandoff(serverInfo: serverInfo)
            }
        } else {
            connectForHandoff(serverInfo: serverInfo)
        }
    }
    
    // MARK: - 核心连接逻辑
    
    /// 根据 Handoff 信息决定用哪个身份连接
    /// 优先级：0. 用户手动指定的 profile → 1. 有证书的注册用户 → 2. 无证书但有用户名的收藏 → 3. 源设备用户名+设备后缀
    private func connectForHandoff(serverInfo: HandoffServerInfo) {
        let connectUsername: String
        let connectPassword: String?
        let connectCertRef: NSData?
        let connectDisplayName: String?
        
        // 0. 检查用户是否手动指定了 Handoff Profile
        // @AppStorage 存储为 Int，使用 object(forKey:) 确保兼容性
        let preferredKey: Int
        if let stored = UserDefaults.standard.object(forKey: "HandoffPreferredProfileKey") {
            preferredKey = (stored as? Int) ?? (stored as? NSNumber)?.intValue ?? -1
        } else {
            preferredKey = -1
        }
        print("📲 Handoff: Preferred profile key = \(preferredKey)")
        if preferredKey > 0, let preferredProfile = findFavouriteByPrimaryKey(preferredKey) {
            connectUsername = preferredProfile.userName ?? "\(serverInfo.username)-\(HandoffManager.deviceTypeSuffix)"
            connectPassword = preferredProfile.password
            connectCertRef = preferredProfile.certificateRef as NSData?
            connectDisplayName = preferredProfile.displayName
            print("📲 Handoff: Using user-preferred profile (key=\(preferredKey)). Username: \(connectUsername)")
        } else {
            // 自动匹配：查找 Favourite Servers 中所有匹配的服务器
            let matchedServers = findMatchingFavouriteServers(
                hostname: serverInfo.hostname,
                port: serverInfo.port
            )
            
            // 1. 优先匹配有证书的注册用户
            if let registered = matchedServers.first(where: { $0.certificateRef != nil && $0.userName != nil && !$0.userName!.isEmpty }) {
                connectUsername = registered.userName!
                connectPassword = registered.password
                connectCertRef = registered.certificateRef as NSData?
                connectDisplayName = registered.displayName
                print("📲 Handoff: Found registered favourite (with cert). Using: \(connectUsername)")
            }
            // 2. 其次匹配无证书但有用户名的收藏
            else if let unregistered = matchedServers.first(where: { $0.userName != nil && !$0.userName!.isEmpty }) {
                connectUsername = unregistered.userName!
                connectPassword = unregistered.password
                connectCertRef = nil
                connectDisplayName = unregistered.displayName
                print("📲 Handoff: Found favourite (no cert). Using: \(connectUsername)")
            }
            // 3. 没有收藏 → 使用源设备的用户名 + 设备类型后缀
            else {
                connectUsername = "\(serverInfo.username)-\(HandoffManager.deviceTypeSuffix)"
                connectPassword = serverInfo.password
                connectCertRef = nil
                connectDisplayName = serverInfo.displayName
                print("📲 Handoff: No favourite found. Using suffixed username: \(connectUsername)")
            }
        }
        
        // 3. 设置 AppState 的显示名称
        AppState.shared.serverDisplayName = connectDisplayName
        
        // 4. 发起连接
        MUConnectionController.shared()?.connet(
            toHostname: serverInfo.hostname,
            port: UInt(serverInfo.port),
            withUsername: connectUsername,
            andPassword: connectPassword,
            certificateRef: connectCertRef as Data?,
            displayName: connectDisplayName
        )
        
        print("📲 Handoff: Connecting to \(serverInfo.hostname):\(serverInfo.port) as \(connectUsername)")
    }
    
    /// 根据 primaryKey 查找收藏服务器
    private func findFavouriteByPrimaryKey(_ key: Int) -> MUFavouriteServer? {
        guard let favourites = MUDatabase.fetchAllFavourites() as? [MUFavouriteServer] else {
            return nil
        }
        return favourites.first { $0.hasPrimaryKey() && Int($0.primaryKey) == key }
    }
    
    /// 在收藏列表中查找所有匹配该服务器的条目
    private func findMatchingFavouriteServers(hostname: String, port: Int) -> [MUFavouriteServer] {
        guard let favourites = MUDatabase.fetchAllFavourites() as? [MUFavouriteServer] else {
            return []
        }
        
        return favourites.filter { server in
            guard let serverHost = server.hostName else { return false }
            // 比较主机名和端口
            return serverHost.lowercased() == hostname.lowercased()
                && Int(server.port) == port
        }
    }
    
    // MARK: - 连接成功后加入频道
    
    @objc private func connectionOpened(_ notification: Notification) {
        guard isHandoffConnection else { return }
        
        // 延迟一小段时间等待 ServerModel 就绪
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.joinPendingChannel()
        }
    }
    
    /// 在连接成功后尝试加入目标频道
    private func joinPendingChannel() {
        guard let serverModel = MUConnectionController.shared()?.serverModel else {
            print("⚠️ Handoff: ServerModel not available for channel join")
            resetHandoffState()
            return
        }
        
        // 先尝试通过 channelId 加入
        if let channelId = pendingChannelId, channelId > 0 {
            if let targetChannel = serverModel.channel(withId: UInt(channelId)) {
                serverModel.join(targetChannel)
                print("✅ Handoff: Joined channel by ID: \(channelId) → \(targetChannel.channelName() ?? "Unknown")")
            }
        }
        // 如果 channelId 不匹配，尝试通过名称查找
        else if let channelName = pendingChannelName, !channelName.isEmpty {
            if let rootChannel = serverModel.rootChannel() {
                if let targetChannel = findChannel(named: channelName, in: rootChannel) {
                    serverModel.join(targetChannel)
                    print("✅ Handoff: Joined channel by name: \(channelName)")
                }
            }
        } else {
            print("ℹ️ Handoff: Target channel not found. Staying in default channel.")
        }
        
        // 加入频道后，延迟一小段时间再恢复音频状态（等待频道切换完成）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.applyPendingAudioStates()
            self?.resetHandoffState()
        }
    }
    
    /// 在连接成功后恢复闭麦/不听状态和用户音频设置
    private func applyPendingAudioStates() {
        guard let serverModel = MUConnectionController.shared()?.serverModel else { return }

        let shouldSyncLocalAudio = UserDefaults.standard.object(forKey: MumbleHandoffSyncLocalAudioSettingsKey) as? Bool ?? true
        
        // 1. 恢复闭麦/不听状态
        if pendingSelfMuted || pendingSelfDeafened {
            serverModel.setSelfMuted(pendingSelfMuted, andSelfDeafened: pendingSelfDeafened)
            print("🔇 Handoff: Restored mute=\(pendingSelfMuted), deaf=\(pendingSelfDeafened)")
        }
        
        // 2. 恢复每个用户的本地音量和本地静音
        if shouldSyncLocalAudio && !pendingUserAudioSettings.isEmpty {
            guard let hostname = serverModel.hostname(),
                  let rootChannel = serverModel.rootChannel() else { return }
            
            // 先将所有设置保存到 LocalUserPreferences（持久化）
            for setting in pendingUserAudioSettings {
                LocalUserPreferences.shared.save(
                    volume: setting.volume,
                    isLocalMuted: setting.isLocalMuted,
                    for: setting.userName,
                    on: hostname
                )
                print("🔊 Handoff: Saved user '\(setting.userName)' vol=\(setting.volume) mute=\(setting.isLocalMuted)")
            }
            
            // 通知 ServerModelManager 重新加载所有用户偏好（同步 UI + 音频引擎）
            NotificationCenter.default.post(name: MumbleHandoffRestoreUserPreferencesNotification, object: nil)
        } else if !shouldSyncLocalAudio {
            print("ℹ️ Handoff: Local user audio settings sync is disabled by user preference.")
        }
    }
    
    /// 递归收集频道树中的所有用户
    private func collectAllUsers(in channel: MKChannel) -> [MKUser] {
        var users: [MKUser] = []
        if let channelUsers = channel.users() as? [MKUser] {
            users.append(contentsOf: channelUsers)
        }
        if let subChannels = channel.channels() as? [MKChannel] {
            for sub in subChannels {
                users.append(contentsOf: collectAllUsers(in: sub))
            }
        }
        return users
    }
    
    /// 递归搜索频道名称
    private func findChannel(named name: String, in parentChannel: MKChannel) -> MKChannel? {
        if parentChannel.channelName() == name {
            return parentChannel
        }
        
        guard let subChannels = parentChannel.channels() as? [MKChannel] else {
            return nil
        }
        
        for sub in subChannels {
            if let found = findChannel(named: name, in: sub) {
                return found
            }
        }
        
        return nil
    }
    
    /// 重置 Handoff 状态
    private func resetHandoffState() {
        isProcessingHandoff = false
        isHandoffConnection = false
        pendingChannelId = nil
        pendingChannelName = nil
        pendingSelfMuted = false
        pendingSelfDeafened = false
        pendingUserAudioSettings = []
    }
}

// MARK: - NSUserActivityDelegate

extension HandoffManager: NSUserActivityDelegate {
    /// 当另一台设备继续了此 activity 时被调用（源设备端）
    /// 用于实现"接力后源设备自动断开"
    nonisolated func userActivityWasContinued(_ userActivity: NSUserActivity) {
        print("📡 Handoff: Activity was continued by another device! Disconnecting source...")
        
        DispatchQueue.main.async {
            // 发送通知，让 UI 层知道接力发生了
            NotificationCenter.default.post(
                name: MumbleHandoffContinuedNotification,
                object: nil
            )
            
            // 断开源设备的连接
            MUConnectionController.shared()?.disconnectFromServer()
            
            // 显示 Toast 提示
            let deviceInfo: String
            #if os(macOS)
            deviceInfo = "another device"
            #else
            deviceInfo = "another device"
            #endif
            
            NotificationCenter.default.post(
                name: NSNotification.Name("MUAppShowMessageNotification"),
                object: nil,
                userInfo: [
                    "message": NSLocalizedString("Session handed off to \(deviceInfo)", comment: "Handoff toast"),
                    "type": "info"
                ]
            )
        }
    }
    
    /// 系统请求更新 userInfo（当 needsSave = true 时）
    nonisolated func userActivityWillSave(_ userActivity: NSUserActivity) {
        // 可以在这里刷新最新的频道信息等
        print("📡 Handoff: Activity will save")
    }
}
