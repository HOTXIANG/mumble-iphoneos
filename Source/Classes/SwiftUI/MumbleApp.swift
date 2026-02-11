//
//  MumbleApp.swift
//  Mumble
//
//  Created by 王梓田 on 1/14/26.
//

import SwiftUI
import UserNotifications

@main
struct MumbleApp: App {
    // 关键点：使用 Adaptor 连接老的 Objective-C Delegate
    // 这样 AppDelegate 里的生命周期方法（如 didFinishLaunching）依然会被调用
    // 但是 UIWindow 的创建权交给了 SwiftUI
    @UIApplicationDelegateAdaptor(MUApplicationDelegate.self) var appDelegate
    
    // 监听环境变化，用于处理 Scene 相位（后台/前台）
    @Environment(\.scenePhase) var scenePhase
    
    /// 处理用户点击系统通知后跳转到聊天界面
    @StateObject private var notificationDelegate = NotificationDelegate()

    var body: some Scene {
        WindowGroup {
            // 这里直接使用你之前的 Wrapper，或者直接换成 MainView
            AppRootView()
                .environmentObject(AppState.shared) // 建议注入 AppState，防止子视图崩溃
                .onAppear {
                    print("🚀 MumbleApp: SwiftUI Lifecycle Started")
                    UNUserNotificationCenter.current().delegate = notificationDelegate
                }
        }
        .onChange(of: scenePhase) { newPhase in
            // 你可以在这里处理生命周期，慢慢替代 AppDelegate 里的逻辑
            if newPhase == .background {
                // 例如：触发清理操作
            }
        }
    }
}

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
    
    /// App 在前台收到通知时不弹 banner（前台已有音效提示）
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }
}
