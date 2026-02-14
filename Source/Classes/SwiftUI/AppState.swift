// 文件: AppState.swift (已更新)

import SwiftUI
import Combine

struct AppToast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let type: ToastType
    
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
    @Published var activeError: AppError?
    @Published var activeToast: AppToast?
    @Published var isRegistering: Bool = false
    
    var pendingRegistration = false
    
    // --- 核心修改：添加一个属性来临时存储服务器的显示名称 ---
    @Published var serverDisplayName: String? = nil
    
    // --- 核心修改 1：添加一个新的 @Published 属性来存储未读消息数 ---
    @Published var unreadMessageCount: Int = 0
    
    // --- 核心修改 2：添加一个属性来跟踪当前显示的 Tab ---
    @Published var currentTab: Tab = .channels // 默认是频道列表
    
    /// macOS 图片预览：设置此属性会在 AppRootView 层级弹出全窗口预览 overlay
    #if os(macOS)
    @Published var previewImage: PlatformImage? = nil
    #endif
    
    private var cancellables = Set<AnyCancellable>()
    
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
        center.publisher(for: NSNotification.Name("MUConnectionOpenedNotification"))
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self = self else { return }
                
                print("🟢 AppState: Connection Opened")
                if let userInfo = notification.userInfo,
                   let displayName = userInfo["displayName"] as? String {
                    self.serverDisplayName = displayName
                }
                
                if self.pendingRegistration {
                    print("🔄 Reconnection successful. Executing pending registration...")
                    
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
        center.publisher(for: NSNotification.Name("MUConnectionClosedNotification"))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
    
                if self.isRegistering {
                    print("🔵 AppState: Keeping UI alive for registration process (ignoring disconnect)")
                    return
                }
                
                print("🔴 AppState: Connection Closed")
                self.isConnecting = false
                self.isReconnecting = false
                self.isConnected = false
                self.serverDisplayName = nil
                self.unreadMessageCount = 0
            }
            .store(in: &cancellables)
        
        // 3. 监听正在连接 (我们在 ObjC 中新加的通知)
        center.publisher(for: NSNotification.Name("MUConnectionConnectingNotification"))
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self = self else { return }
                // 如果正在注册，不需要显示常规的 Connecting 状态，因为会有遮罩
                if self.isRegistering { return }
                
                let isReconnecting = (notification.userInfo?["isReconnecting"] as? Bool) ?? false
                
                print("🟡 AppState: Connecting... (Reconnecting: \(isReconnecting))")
                withAnimation {
                    self.isConnecting = true
                    self.isReconnecting = isReconnecting
                }
            }
            .store(in: &cancellables)
        
        // 4. 监听连接错误 (我们在 ObjC 中新加的通知)
        center.publisher(for: NSNotification.Name("MUConnectionErrorNotification"))
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self = self else { return }
                
                self.isConnecting = false
                self.isReconnecting = false
                self.isConnected = false
                self.pendingRegistration = false
                // 解析 ObjC 传来的 userInfo
                if let userInfo = notification.userInfo,
                   let title = userInfo["title"] as? String,
                   let msg = userInfo["message"] as? String {
                    print("⚠️ AppState: Error - \(title): \(msg)")
                    self.activeError = AppError(title: title, message: msg)
                }
            }
            .store(in: &cancellables)
        
        center.publisher(for: NSNotification.Name("MUAppShowMessageNotification"))
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                if let userInfo = notification.userInfo,
                   let message = userInfo["message"] as? String {
                    
                    let typeString = userInfo["type"] as? String ?? "info"
                    let type: AppToast.ToastType = (typeString == "error") ? .error : .info
                    
                    // 显示 Toast
                    withAnimation(.spring()) {
                        self?.activeToast = AppToast(message: message, type: type)
                    }
                    
                    // 3秒后自动消失
                    // 取消之前的自动消失任务（如果有），防止闪烁
                    self?.toastWorkItem?.cancel()
                    let task = DispatchWorkItem { [weak self] in
                        withAnimation(.easeOut) {
                            self?.activeToast = nil
                        }
                    }
                    self?.toastWorkItem = task
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: task)
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
    private var toastWorkItem: DispatchWorkItem?
}
