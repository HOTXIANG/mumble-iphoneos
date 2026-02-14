//
//  MumbleApp.swift
//  Mumble
//
//  Created by 王梓田 on 1/14/26.
//

import SwiftUI
import UserNotifications

// MARK: - FocusedValue for menu bar access

struct FocusedServerManagerKey: FocusedValueKey {
    typealias Value = ServerModelManager
}

extension FocusedValues {
    var serverManager: ServerModelManager? {
        get { self[FocusedServerManagerKey.self] }
        set { self[FocusedServerManagerKey.self] = newValue }
    }
}

@main
struct MumbleApp: App {
    // 关键点：使用 Adaptor 连接老的 Objective-C Delegate
    // 这样 AppDelegate 里的生命周期方法（如 didFinishLaunching）依然会被调用
    // 但是 UIWindow 的创建权交给了 SwiftUI
    #if os(iOS)
    @UIApplicationDelegateAdaptor(MUApplicationDelegate.self) var appDelegate
    #else
    @NSApplicationDelegateAdaptor(MUMacApplicationDelegate.self) var appDelegate
    #endif
    
    // 监听环境变化，用于处理 Scene 相位（后台/前台）
    @Environment(\.scenePhase) var scenePhase
    
    /// 处理用户点击系统通知后跳转到聊天界面
    @StateObject private var notificationDelegate = NotificationDelegate()

    var body: some Scene {
        WindowGroup {
            // 这里直接使用你之前的 Wrapper，或者直接换成 MainView
            AppRootView()
                .environmentObject(AppState.shared) // 建议注入 AppState，防止子视图崩溃
                #if os(macOS)
                .frame(minWidth: 600, minHeight: 400)
                .background(WindowMinSizeSetter(minSize: NSSize(width: 600, height: 400)))
                #endif
                .onAppear {
                    print("🚀 MumbleApp: SwiftUI Lifecycle Started")
                    UNUserNotificationCenter.current().delegate = notificationDelegate
                }
                // Handoff 接力：当其他设备的 Mumble 正在连接服务器时，本设备可以接力
                .onContinueUserActivity(MumbleHandoffActivityType) { userActivity in
                    print("📲 MumbleApp: Received Handoff activity")
                    HandoffManager.shared.handleIncomingActivity(userActivity)
                }
                // Widget 深链接：用户从 Widget 点击服务器直接连接
                .onOpenURL { url in
                    handleMumbleURL(url)
                }
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 760)
        #endif
        .onChange(of: scenePhase) { newPhase in
            // 你可以在这里处理生命周期，慢慢替代 AppDelegate 里的逻辑
            if newPhase == .background {
                // 例如：触发清理操作
            }
        }
        #if os(macOS)
        .commands {
            MumbleMenuCommands()
        }
        #endif
    }
    
    // MARK: - Widget Deep Link 处理
    
    /// 处理 mumble:// URL（来自 Widget 或外部链接）
    private func handleMumbleURL(_ url: URL) {
        guard url.scheme == "mumble" else { return }
        
        let connController = MUConnectionController.shared()
        guard connController?.isConnected() != true else {
            print("⚠️ MumbleApp: Already connected, ignoring widget URL")
            return
        }
        
        let hostname = url.host ?? ""
        let port = url.port ?? 64738
        let username = url.user ?? ""
        let password = url.password ?? ""
        
        guard !hostname.isEmpty else { return }
        
        print("🔗 MumbleApp: Opening mumble URL → \(hostname):\(port) as \(username)")
        
        // 从收藏夹中查找匹配的服务器，以获取证书和其他配置
        let allFavs = MUDatabase.fetchAllFavourites() as? [MUFavouriteServer] ?? []
        let matchingFav = allFavs.first(where: {
            $0.hostName?.lowercased() == hostname.lowercased()
            && Int($0.port) == port
            && $0.userName == username
        })
        
        AppState.shared.serverDisplayName = matchingFav?.displayName ?? hostname
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
        
        connController?.connet(
            toHostname: hostname,
            port: UInt(port),
            withUsername: username.isEmpty ? (matchingFav?.userName ?? "MumbleUser") : username,
            andPassword: password.isEmpty ? (matchingFav?.password ?? "") : password,
            certificateRef: matchingFav?.certificateRef,
            displayName: matchingFav?.displayName
        )
        
        // 最近连接由 MUConnectionController 内部调用 RecentServerManager.addRecent 自动记录
        // Widget 数据也由 RecentServerManager 自动同步
    }
}

// MARK: - macOS Menu Bar Commands
#if os(macOS)
struct MumbleMenuCommands: Commands {
    @FocusedValue(\.serverManager) var serverManager
    @ObservedObject private var appState = AppState.shared
    
    var body: some Commands {
        // 替换默认的 "File" 菜单里不需要的项
        CommandGroup(replacing: .newItem) {}
        
        // 移除 View 菜单中的 "Show Tab Bar" 和 "Show All Tabs"
        CommandGroup(replacing: .toolbar) {}
        
        // "Server" 菜单
        CommandMenu("Server") {
            Button {
                NotificationCenter.default.post(name: .mumbleToggleMute, object: nil)
            } label: {
                Label("Mute/Unmute", systemImage: "mic.slash.fill")
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(!appState.isConnected)
            
            Button {
                NotificationCenter.default.post(name: .mumbleToggleDeafen, object: nil)
            } label: {
                Label("Deafen/Undeafen", systemImage: "speaker.slash.fill")
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!appState.isConnected)
            
            Divider()
            
            Button {
                NotificationCenter.default.post(name: .mumbleRegisterUser, object: nil)
            } label: {
                Label("Register User", systemImage: "person.badge.plus")
            }
            .disabled(!appState.isConnected || appState.isUserAuthenticated)

            Button {
                NotificationCenter.default.post(name: .mumbleShowCertInfo, object: nil)
            } label: {
                Label("View Certificate", systemImage: "checkmark.shield")
            }
            .disabled(!appState.isConnected || !appState.isUserAuthenticated)
            
            Divider()
            
            Button {
                NotificationCenter.default.post(name: .mumbleInitiateDisconnect, object: nil)
            } label: {
                Label("Disconnect", systemImage: "xmark.circle")
            }
            .keyboardShortcut("w", modifiers: [.command])
            .disabled(!appState.isConnected)
        }
        
        // "Mumble" 菜单 - 添加设置项
        CommandGroup(after: .appSettings) {
            Button {
                NotificationCenter.default.post(name: .mumbleShowSettings, object: nil)
            } label: {
                Label("Settings...", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: [.command])
        }
    }
}

// Menu bar notification names
extension Notification.Name {
    static let mumbleShowSettings = Notification.Name("MumbleShowSettingsNotification")
    static let mumbleShowCertInfo = Notification.Name("MumbleShowCertInfoNotification")
    static let mumbleInitiateDisconnect = Notification.Name("MumbleInitiateDisconnectFromMenuNotification")
    static let mumbleRegisterUser = Notification.Name("MumbleRegisterUserNotification")
    static let mumbleToggleMute = Notification.Name("MumbleToggleMuteNotification")
    static let mumbleToggleDeafen = Notification.Name("MumbleToggleDeafenNotification")
}

/// 通过 NSViewRepresentable 直接设置 NSWindow.minSize，确保窗口无法缩小到指定尺寸以下
struct WindowMinSizeSetter: NSViewRepresentable {
    let minSize: NSSize
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // 延迟到下一个 run loop，此时 view 已经被加入到 window 中
        DispatchQueue.main.async {
            if let window = view.window {
                window.minSize = minSize
            }
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        // 每次更新时也确保 minSize 保持设置
        if let window = nsView.window {
            window.minSize = minSize
        }
    }
}
#endif

/// 单独的 UNUserNotificationCenterDelegate，用于处理通知点击事件
class NotificationDelegate: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    /// 用户点击了系统通知 → 自动跳转到聊天界面
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            AppState.shared.currentTab = .messages
        }
        completionHandler()
    }
    
    /// App 在前台收到通知时的展示策略
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        #if os(macOS)
        // macOS: 前台也显示系统通知横幅并播放音效
        completionHandler([.banner, .sound])
        #else
        // iOS: 前台不弹系统通知（已在 sendLocalNotification 中用 AudioServicesPlayAlertSound 播放了音效）
        completionHandler([])
        #endif
    }
}
