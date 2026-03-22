// 文件: AppState.swift (已更新)

import SwiftUI
import Combine

// MARK: - Centralized Notification Names (ObjC-bridged)

extension Notification.Name {
    static let muConnectionOpened     = Notification.Name("MUConnectionOpenedNotification")
    static let muConnectionClosed     = Notification.Name("MUConnectionClosedNotification")
    static let muConnectionConnecting = Notification.Name("MUConnectionConnectingNotification")
    static let muConnectionError      = Notification.Name("MUConnectionErrorNotification")
    static let muConnectionUDPTransportStatus = Notification.Name("MUConnectionUDPTransportStatusNotification")
    static let muAppShowMessage       = Notification.Name("MUAppShowMessageNotification")
    static let muConnectionReady      = Notification.Name("MUConnectionReadyForSwiftUI")
    static let muMessageSendFailed    = Notification.Name("MUMessageSendFailed")

    static let mkAudioDidRestart         = Notification.Name("MKAudioDidRestartNotification")
    static let mkAudioError              = Notification.Name("MKAudioErrorNotification")
    static let mkListeningChannelAdd     = Notification.Name("MKListeningChannelAddNotification")
    static let mkListeningChannelRemove  = Notification.Name("MKListeningChannelRemoveNotification")

    static let muPreferencesChanged      = Notification.Name("MumblePreferencesChanged")
    static let muCertificateTrustFailure = Notification.Name("MUCertificateTrustFailureNotification")
    static let muAutomationOpenUI        = Notification.Name("MUAutomationOpenUINotification")
    static let muAutomationDismissUI     = Notification.Name("MUAutomationDismissUINotification")
    static let muAutomationNavigate      = Notification.Name("MUAutomationNavigateNotification")
    static let muAutomationUIStateChanged = Notification.Name("MUAutomationUIStateChangedNotification")

    #if os(macOS)
    static let muMacAudioInputDevicesChanged = Notification.Name("MUMacAudioInputDevicesChanged")
    static let muMacAudioVPIOToHALTransition = Notification.Name("MUMacAudioVPIOToHALTransition")
    #endif
}

// MARK: - Toast / Error types

struct AppToast: Identifiable {
    let id = UUID()
    let message: String
    let type: ToastType
    let jumpToMessagesOnTap: Bool
    let senderName: String?
    let bodyText: String?
    let avatarImage: PlatformImage?
    let isSystemMessageBanner: Bool

    init(
        message: String,
        type: ToastType,
        jumpToMessagesOnTap: Bool = false,
        senderName: String? = nil,
        bodyText: String? = nil,
        avatarImage: PlatformImage? = nil,
        isSystemMessageBanner: Bool = false
    ) {
        self.message = message
        self.type = type
        self.jumpToMessagesOnTap = jumpToMessagesOnTap
        self.senderName = senderName
        self.bodyText = bodyText
        self.avatarImage = avatarImage
        self.isSystemMessageBanner = isSystemMessageBanner
    }

    var isChatMessageBanner: Bool {
        senderName != nil && bodyText != nil && !isSystemMessageBanner
    }
    
    enum ToastType {
        case info
        case error
        case success
    }
}

// 定义一个简单的错误结构体，用于弹窗
struct AppError: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct CertTrustInfo: Identifiable {
    let id = UUID()
    let hostname: String
    let port: Int
    let subjectName: String
    let issuerName: String
    let fingerprint: String
    let notBefore: String
    let notAfter: String
    let isChanged: Bool
}

@objc class CertTrustBridge: NSObject {
    @objc static func handleTrustFailure(_ info: NSDictionary) {
        NSLog("📜 CertTrustBridge.handleTrustFailure called")
        let hostname    = info["hostname"]    as? String ?? ""
        let port        = (info["port"]       as? NSNumber)?.intValue ?? 0
        let subjectName = info["subjectName"] as? String ?? "Unknown"
        let issuerName  = info["issuerName"]  as? String ?? "Unknown"
        let fingerprint = info["fingerprint"] as? String ?? "Unknown"
        let notBefore   = info["notBefore"]   as? String ?? "—"
        let notAfter    = info["notAfter"]    as? String ?? "—"
        let isChanged   = (info["isChanged"]  as? NSNumber)?.boolValue ?? false

        DispatchQueue.main.async {
            let state = AppState.shared
            state.isConnecting = false
            state.pendingCertTrust = CertTrustInfo(
                hostname: hostname, port: port,
                subjectName: subjectName, issuerName: issuerName,
                fingerprint: fingerprint,
                notBefore: notBefore, notAfter: notAfter,
                isChanged: isChanged
            )
            NSLog("📜 CertTrustBridge: isConnecting=%d, pendingCertTrust=%@",
                  state.isConnecting, state.pendingCertTrust != nil ? "SET" : "nil")
        }
    }
}

@MainActor
class AppState: ObservableObject {
    // --- 核心修改 1：将 Tab 的定义移到这里 ---
    enum Tab {
        case channels
        case messages
    }
    
    @Published var isConnected: Bool = false
    @Published var isConnecting: Bool = false
    @Published var isReconnecting: Bool = false
    @Published var reconnectAttempt: Int = 0
    @Published var reconnectMaxAttempts: Int = 0
    @Published var reconnectReason: String? = nil
    @Published var isUserAuthenticated: Bool = false
    @Published var activeError: AppError?
    @Published var activeToast: AppToast?
    @Published var pendingCertTrust: CertTrustInfo?
    @Published var isRegistering: Bool = false
    
    var pendingRegistration = false
    
    // --- 核心修改：添加一个属性来临时存储服务器的显示名称 ---
    @Published var serverDisplayName: String? = nil
    
    // --- 核心修改 1：添加一个新的 @Published 属性来存储未读消息数 ---
    @Published var unreadMessageCount: Int = 0
    
    // --- 核心修改 2：添加一个属性来跟踪当前显示的 Tab ---
    @Published var currentTab: Tab = .channels // 默认是频道列表
    @Published var isInChannelView: Bool = false
    @Published var isChannelSplitLayout: Bool = false
    @Published var automationCurrentScreen: String = "welcome"
    @Published var automationPresentedSheet: String? = nil
    @Published var automationPresentedAlert: String? = nil
    @Published var automationVisibleOverlays: [String] = []
    
    #if os(iOS)
    @Published var isImmersiveStatusBarHidden: Bool = false
    @Published var activeImagePreview: MessageImagePreviewItem? = nil
    @Published var hiddenPreviewSourceID: String? = nil
    #endif
    
    /// macOS 图片预览：设置此属性会在 AppRootView 层级弹出全窗口预览 overlay
    #if os(macOS)
    @Published var activeMacImagePreview: MessageImagePreviewItem? = nil
    @Published var hiddenMacPreviewSourceID: String? = nil
    #endif
    
    private var cancellables = Set<AnyCancellable>()
    private var lastUDPTransportStateName: String = "unknown"
    private var suppressNextUDPAvailableToast: Bool = false
    
    static let shared = AppState()
    private init() {
        setupObservers()
        setupDockBadge()
    }
    
    private func setupDockBadge() {
        #if os(macOS)
        $unreadMessageCount
            .receive(on: RunLoop.main)
            .sink { count in
                if count > 0 {
                    NSApp.dockTile.badgeLabel = "\(count)"
                } else {
                    NSApp.dockTile.badgeLabel = nil
                }
            }
            .store(in: &cancellables)
        #endif
    }
    
    private func setupObservers() {
        let center = NotificationCenter.default
        
        // 1. 监听连接成功
        center.publisher(for: .muConnectionOpened)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self = self else { return }
                
                MumbleLogger.connection.info("Connection opened")
                     self.suppressNextUDPAvailableToast = true
                if let userInfo = notification.userInfo,
                   let displayName = userInfo["displayName"] as? String {
                    self.serverDisplayName = displayName
                }
                
                if self.pendingRegistration {
                    MumbleLogger.connection.info("Reconnection successful, executing pending registration")
                    
                    // 延迟 0.5 秒确保连接稳定
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        if let model = MUConnectionController.shared()?.serverModel {
                            // 发送 Mumble 协议的注册指令
                            model.registerConnectedUser()
                        }
                        // 重置标记
                        self.pendingRegistration = false
                        
                        withAnimation {
                            self.isRegistering = false
                        }
                    }
                } else {
                    // 如果不是注册流程，确保遮罩关闭
                    self.isRegistering = false
                }
                
                withAnimation(.spring()) {
                    self.isConnected = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.isConnecting = false
                    }
                }
            }
            .store(in: &cancellables)
        
        // 2. 监听连接断开
        center.publisher(for: .muConnectionClosed)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
    
                if self.isRegistering {
                    MumbleLogger.connection.debug("Keeping UI alive for registration (ignoring disconnect)")
                    return
                }
                
                MumbleLogger.connection.info("Connection closed")
                self.isConnecting = false
                self.isReconnecting = false
                self.reconnectAttempt = 0
                self.reconnectMaxAttempts = 0
                self.reconnectReason = nil
                self.isConnected = false
                self.isUserAuthenticated = false
                self.lastUDPTransportStateName = "unknown"
                self.suppressNextUDPAvailableToast = false
                self.serverDisplayName = nil
                self.unreadMessageCount = 0
            }
            .store(in: &cancellables)
        
        // 3. 监听正在连接
        center.publisher(for: .muConnectionConnecting)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self = self else { return }
                // 如果正在注册，不需要显示常规的 Connecting 状态，因为会有遮罩
                if self.isRegistering { return }
                
                let isReconnecting = (notification.userInfo?["isReconnecting"] as? Bool) ?? false
                let reconnectAttempt =
                    (notification.userInfo?["reconnectAttempt"] as? NSNumber)?.intValue
                    ?? (notification.userInfo?["reconnectAttempt"] as? Int)
                    ?? 0
                let reconnectMaxAttempts =
                    (notification.userInfo?["reconnectMaxAttempts"] as? NSNumber)?.intValue
                    ?? (notification.userInfo?["reconnectMaxAttempts"] as? Int)
                    ?? 0
                let reconnectReason = notification.userInfo?["reconnectReason"] as? String
                
                MumbleLogger.connection.info("Connecting (reconnecting: \(isReconnecting))")
                withAnimation {
                    self.isConnecting = true
                    self.isReconnecting = isReconnecting
                    self.reconnectAttempt = isReconnecting ? reconnectAttempt : 0
                    self.reconnectMaxAttempts = isReconnecting ? reconnectMaxAttempts : 0
                    self.reconnectReason = isReconnecting ? reconnectReason : nil
                }
            }
            .store(in: &cancellables)
        
        // 4. 监听连接错误
        center.publisher(for: .muConnectionError)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self = self else { return }
                
                self.isConnecting = false
                self.isReconnecting = false
                self.reconnectAttempt = 0
                self.reconnectMaxAttempts = 0
                self.reconnectReason = nil
                self.isConnected = false
                self.isUserAuthenticated = false
                self.pendingRegistration = false
                // 解析 ObjC 传来的 userInfo
                if let userInfo = notification.userInfo,
                   let title = userInfo["title"] as? String,
                   let msg = userInfo["message"] as? String {
                    MumbleLogger.connection.error("Connection error: \(title) - \(msg)")
                    self.activeError = AppError(title: title, message: msg)
                }
            }
            .store(in: &cancellables)
        
        // Certificate trust failure is now handled directly via CertTrustBridge.handleTrustFailure(_:)

        center.publisher(for: .muConnectionUDPTransportStatus)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self = self else { return }
                let stateName = (notification.userInfo?["stateName"] as? String) ?? "unknown"
                guard stateName != self.lastUDPTransportStateName else { return }
                self.lastUDPTransportStateName = stateName

                MumbleLogger.connection.info("UDP transport state changed: \(stateName)")

                switch stateName {
                case "stalled":
                    self.suppressNextUDPAvailableToast = false
                    self.showToast(message: NSLocalizedString("UDP stalled, recovering audio channel...", comment: "UDP stalled status toast"), type: .error)
                case "recovering":
                    self.suppressNextUDPAvailableToast = false
                    self.showToast(message: NSLocalizedString("Re-establishing UDP channel...", comment: "UDP recovering status toast"), type: .info)
                case "available":
                    if self.suppressNextUDPAvailableToast {
                        self.suppressNextUDPAvailableToast = false
                        break
                    }
                    self.showToast(message: NSLocalizedString("UDP channel restored", comment: "UDP available status toast"), type: .success)
                case "unavailable":
                    self.suppressNextUDPAvailableToast = false
                    self.showToast(message: NSLocalizedString("UDP unavailable, using TCP tunnel", comment: "UDP unavailable status toast"), type: .info)
                default:
                    break
                }
            }
            .store(in: &cancellables)

        center.publisher(for: .muAppShowMessage)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                if let userInfo = notification.userInfo,
                   let message = userInfo["message"] as? String {
                    
                    let typeString = userInfo["type"] as? String ?? "info"
                    let type: AppToast.ToastType = (typeString == "error") ? .error : .info
                    let jumpToMessages = userInfo["jumpToMessages"] as? Bool ?? false
                    let bannerType = userInfo["inAppBannerType"] as? String
                    let senderName = userInfo["senderName"] as? String
                    let bodyText = userInfo["body"] as? String
                    let avatarImage = userInfo["avatarImage"] as? PlatformImage
                    
                    // 显示 Toast
                    withAnimation(.spring()) {
                        if bannerType == "chatMessage",
                           let senderName,
                           let bodyText {
                            self?.activeToast = AppToast(
                                message: message,
                                type: type,
                                jumpToMessagesOnTap: jumpToMessages,
                                senderName: senderName,
                                bodyText: bodyText,
                                avatarImage: avatarImage,
                                isSystemMessageBanner: false
                            )
                        } else {
                            self?.activeToast = AppToast(
                                message: message,
                                type: type,
                                jumpToMessagesOnTap: jumpToMessages,
                                isSystemMessageBanner: bannerType == "systemMessage"
                            )
                        }
                    }
                    
                    // 3秒后自动消失
                    // 取消之前的自动消失任务（如果有），防止闪烁
                    self?.toastWorkItem?.cancel()
                    let dismissDelay: TimeInterval = (bannerType == "chatMessage") ? 6.0 : 3.0
                    let task = DispatchWorkItem { [weak self] in
                        withAnimation(.easeOut) {
                            self?.activeToast = nil
                        }
                    }
                    self?.toastWorkItem = task
                    DispatchQueue.main.asyncAfter(deadline: .now() + dismissDelay, execute: task)
                }
            }
            .store(in: &cancellables)
    }
    func cancelConnection() {
        // 调用 ObjC 的 disconnect 方法，这会将 _isUserInitiatedDisconnect 设为 YES
        // 从而停止重连循环，并触发 Closed 通知回到主页
        MUConnectionController.shared()?.disconnectFromServer()
        self.isConnecting = false
        self.isReconnecting = false
        self.pendingRegistration = false
    }

    func setAutomationCurrentScreen(_ screen: String) {
        guard automationCurrentScreen != screen else { return }
        automationCurrentScreen = screen
        postAutomationUIStateChanged()
    }

    func setAutomationPresentedSheet(_ sheet: String?) {
        guard automationPresentedSheet != sheet else { return }
        automationPresentedSheet = sheet
        postAutomationUIStateChanged()
    }

    func clearAutomationPresentedSheet(ifMatches sheet: String) {
        guard automationPresentedSheet == sheet else { return }
        automationPresentedSheet = nil
        postAutomationUIStateChanged()
    }

    func setAutomationPresentedAlert(_ alert: String?) {
        guard automationPresentedAlert != alert else { return }
        automationPresentedAlert = alert
        postAutomationUIStateChanged()
    }

    func setAutomationVisibleOverlays(_ overlays: [String]) {
        let normalized = Array(Set(overlays)).sorted()
        guard automationVisibleOverlays != normalized else { return }
        automationVisibleOverlays = normalized
        postAutomationUIStateChanged()
    }

    func automationUISnapshot() -> [String: Any] {
        [
            "currentScreen": automationCurrentScreen,
            "presentedSheet": automationPresentedSheet ?? NSNull(),
            "presentedAlert": automationPresentedAlert ?? NSNull(),
            "visibleOverlays": automationVisibleOverlays
        ]
    }

    private func showToast(message: String, type: AppToast.ToastType) {
        withAnimation(.spring()) {
            activeToast = AppToast(message: message, type: type)
        }

        toastWorkItem?.cancel()
        let task = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut) {
                self?.activeToast = nil
            }
        }
        toastWorkItem = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: task)
    }

    private var toastWorkItem: DispatchWorkItem?

    private func postAutomationUIStateChanged() {
        NotificationCenter.default.post(
            name: .muAutomationUIStateChanged,
            object: nil,
            userInfo: automationUISnapshot()
        )
    }
}
