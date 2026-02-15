// 文件: ServerModelManager.swift (已添加 serverName 属性)

import SwiftUI
#if os(iOS)
import ActivityKit
#endif

final class ObserverTokenHolder {
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

final class DelegateToken {
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
    var isScanningACLs: Bool = false
    var pendingACLUserNameQueries: Set<Int> = []
    
    let tokenHolder = ObserverTokenHolder()
    var delegateToken: DelegateToken?
    var muteStateBeforeDeafen: Bool = false
    /// 保存重连前的监听频道 ID，重连后自动重新注册
    var savedListeningChannelIds: Set<UInt> = []
    var serverModel: MKServerModel?
    var userIndexMap: [UInt: Int] = [:]
    var channelIndexMap: [UInt: Int] = [:]
    #if os(iOS)
    var liveActivity: Activity<MumbleActivityAttributes>?
    #endif
    var keepAliveTimer: Timer?
    let systemMuteManager = SystemMuteManager()
    var isRestoringMuteState = false
    /// 音频重启前保存的闭麦/不听状态（防止系统回调覆盖）
    var savedMuteBeforeRestart: Bool?
    var savedDeafenBeforeRestart: Bool?
    /// 追踪每个用户的 mute/deafen 状态，用于检测变化并生成系统消息
    var previousMuteStates: [UInt: (isSelfMuted: Bool, isSelfDeafened: Bool)] = [:]
    /// 当前的 access tokens 列表
    var currentAccessTokens: [String] = []
    /// 正在尝试用密码进入的频道 ID（用于成功后标记为密码频道）
    var pendingPasswordChannelId: UInt? = nil
    /// 记录 deafen 前是否已被 server mute（用于 undeafen 时决定是否保留 mute）
    var wasMutedBeforeServerDeafen: [UInt: Bool] = [:]
    /// 用户主动尝试加入的频道 ID（用于在扫描期间仍弹出密码框）
    var userInitiatedJoinChannelId: UInt? = nil
    
    enum ViewMode {
        case server,
             channel
    }
    
    init() {
        print(
            "✅ ServerModelManager: INIT (Lazy)"
        )
    }

    deinit {
        print("🔴 ServerModelManager: DEINIT")
        NotificationCenter.default.removeObserver(self)
    }

    // Split note: manager logic moved into focused extensions:
    // `ServerModelManager+Controls.swift`
    // `ServerModelManager+Channels.swift`
    // `ServerModelManager+Notifications.swift`
    // `ServerModelManager+Messaging.swift`
    // `ServerModelManager+ModelState.swift`
    // `ServerModelManager+Registration.swift`
    // `ServerModelManager+Lifecycle.swift`
    // `ServerModelManager+AudioState.swift`
    // `ServerModelManager+HandoffLiveActivity.swift`
    // `ServerModelManager+Entry.swift`
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

extension Notification.Name {
    static let requestReconnect = Notification.Name("MURequestReconnect")
}
