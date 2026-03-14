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
    @StateObject private var serverManager = ServerModelManager()
    @ObservedObject private var appState = AppState.shared
    
    /// 处理用户点击系统通知后跳转到聊天界面
    @StateObject private var notificationDelegate = NotificationDelegate()
    @State private var pendingDeepLinkChannelPath: [String] = []

    @SceneBuilder
    private var mainWindowScene: some Scene {
        WindowGroup {
            // 这里直接使用你之前的 Wrapper，或者直接换成 MainView
            AppRootView(serverManager: serverManager)
                .environmentObject(AppState.shared) // 建议注入 AppState，防止子视图崩溃
                #if os(iOS)
                .statusBar(hidden: appState.isImmersiveStatusBarHidden)
                #endif
                #if os(macOS)
                .frame(minWidth: 480, minHeight: 400)
                .background(WindowMinSizeSetter(minSize: NSSize(width: 480, height: 400)))
                #endif
                .onAppear {
                    MumbleLogger.general.info("SwiftUI lifecycle started")
                    UNUserNotificationCenter.current().delegate = notificationDelegate
                }
                .onReceive(NotificationCenter.default.publisher(for: .muConnectionOpened)) { _ in
                    joinPendingDeepLinkChannelIfNeeded()
                }
                // Handoff 接力：当其他设备的 Mumble 正在连接服务器时，本设备可以接力
                .onContinueUserActivity(MumbleHandoffActivityType) { userActivity in
                    MumbleLogger.handoff.info("Received Handoff activity")
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
        .onChange(of: scenePhase) { _, newPhase in
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

    var body: some Scene {
        mainWindowScene
        #if os(macOS)
        Settings {
            MacSettingsRootView()
                .environmentObject(serverManager)
                .frame(minWidth: 400, idealWidth: 500, minHeight: 100, idealHeight: 200)
        }
        #endif
    }
    
    // MARK: - Widget Deep Link 处理
    
    /// 处理 mumble:// URL（来自 Widget 或外部链接）
    private func handleMumbleURL(_ url: URL) {
        let scheme = (url.scheme ?? "").lowercased()
        guard scheme == "mumble" || scheme == "neomumble" else { return }

        let connController = MUConnectionController.shared()
        let hostname = url.host ?? ""
        let port = url.port ?? 64738
        let username = url.user ?? ""
        let password = url.password ?? ""
        let channelPath = decodedChannelPath(from: url)

        guard !hostname.isEmpty else { return }

        if connController?.isConnected() == true || connController?.connection != nil {
            guard isCurrentConnection(hostname: hostname, port: port) else {
                return
            }
            if joinChannel(path: channelPath) {
                MumbleLogger.connection.info("Deep link jumped to channel path: \(channelPath.joined(separator: "/"))")
            } else if !channelPath.isEmpty {
                pendingDeepLinkChannelPath = channelPath
            }
            return
        }

        MumbleLogger.connection.info("Opening mumble URL: \(hostname):\(port) as \(username)")
        
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
        
        connController?.connect(
            toHostname: hostname,
            port: UInt(port),
            withUsername: username.isEmpty ? (matchingFav?.userName ?? "MumbleUser") : username,
            andPassword: password.isEmpty ? (matchingFav?.password ?? "") : password,
            certificateRef: matchingFav?.certificateRef,
            displayName: matchingFav?.displayName
        )
        pendingDeepLinkChannelPath = channelPath
        
        // 最近连接由 MUConnectionController 内部调用 RecentServerManager.addRecent 自动记录
        // Widget 数据也由 RecentServerManager 自动同步
    }

    private func joinPendingDeepLinkChannelIfNeeded() {
        guard !pendingDeepLinkChannelPath.isEmpty else { return }
        // 稍等片刻，确保频道树已经同步完成
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if self.joinChannel(path: self.pendingDeepLinkChannelPath) {
                self.pendingDeepLinkChannelPath.removeAll()
            }
        }
    }

    private func decodedChannelPath(from url: URL) -> [String] {
        url.pathComponents
            .filter { $0 != "/" }
            .map { $0.removingPercentEncoding ?? $0 }
            .filter { !$0.isEmpty }
    }

    private func isCurrentConnection(hostname: String, port: Int) -> Bool {
        guard let connection = MUConnectionController.shared()?.connection else { return false }
        let connectedHost = (connection.hostname() ?? "").lowercased()
        let targetHost = hostname.lowercased()
        return connectedHost == targetHost && Int(connection.port()) == port
    }

    private func joinChannel(path: [String]) -> Bool {
        guard !path.isEmpty,
              let model = MUConnectionController.shared()?.serverModel,
              let root = model.rootChannel() else {
            return false
        }

        guard let target = findChannel(path: path, from: root) else { return false }
        model.join(target)
        return true
    }

    private func findChannel(path: [String], from root: MKChannel) -> MKChannel? {
        var current = root
        for component in path {
            guard let subChannels = current.channels() as? [MKChannel] else {
                return nil
            }
            guard let next = subChannels.first(where: { ($0.channelName() ?? "") == component }) else {
                return nil
            }
            current = next
        }
        return current
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
            if appState.isConnected {
                Button {
                    NotificationCenter.default.post(name: .mumbleToggleMute, object: nil)
                } label: {
                    Label("Mute/Unmute", systemImage: "mic.slash.fill")
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                
                Button {
                    NotificationCenter.default.post(name: .mumbleToggleDeafen, object: nil)
                } label: {
                    Label("Deafen/Undeafen", systemImage: "speaker.slash.fill")
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                
                Divider()
            }
            
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
                NotificationCenter.default.post(name: .mumbleShowAccessTokens, object: nil)
            } label: {
                Label("Access Tokens", systemImage: "key")
            }
            .disabled(!appState.isConnected)

            Button {
                NotificationCenter.default.post(name: .mumbleShowBanList, object: nil)
            } label: {
                Label("Ban List", systemImage: "nosign")
            }
            .disabled(!appState.isConnected)

            Button {
                NotificationCenter.default.post(name: .mumbleShowRegisteredUsers, object: nil)
            } label: {
                Label("Registered Users", systemImage: "person.2")
            }
            .disabled(!appState.isConnected)
            
            Divider()
            
            Button {
                NotificationCenter.default.post(name: .mumbleInitiateDisconnect, object: nil)
            } label: {
                Label("Disconnect", systemImage: "xmark.circle")
            }
            .keyboardShortcut("w", modifiers: [.command])
            .disabled(!appState.isConnected)
        }
        
    }
}

// Menu bar notification names
extension Notification.Name {
    static let mumbleShowCertInfo = Notification.Name("MumbleShowCertInfoNotification")
    static let mumbleInitiateDisconnect = Notification.Name("MumbleInitiateDisconnectFromMenuNotification")
    static let mumbleRegisterUser = Notification.Name("MumbleRegisterUserNotification")
    static let mumbleToggleMute = Notification.Name("MumbleToggleMuteNotification")
    static let mumbleToggleDeafen = Notification.Name("MumbleToggleDeafenNotification")
    static let mumbleShowAccessTokens = Notification.Name("MumbleShowAccessTokensNotification")
    static let mumbleShowBanList = Notification.Name("MumbleShowBanListNotification")
    static let mumbleShowRegisteredUsers = Notification.Name("MumbleShowRegisteredUsersNotification")
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
