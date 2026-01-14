//
//  MumbleApp.swift
//  Mumble
//
//  Created by 王梓田 on 1/14/26.
//

import SwiftUI

@main
struct MumbleApp: App {
    // 关键点：使用 Adaptor 连接老的 Objective-C Delegate
    // 这样 AppDelegate 里的生命周期方法（如 didFinishLaunching）依然会被调用
    // 但是 UIWindow 的创建权交给了 SwiftUI
    @UIApplicationDelegateAdaptor(MUApplicationDelegate.self) var appDelegate
    
    // 监听环境变化，用于处理 Scene 相位（后台/前台）
    @Environment(\.scenePhase) var scenePhase

    var body: some Scene {
        WindowGroup {
            // 这里直接使用你之前的 Wrapper，或者直接换成 MainView
            AppRootView()
                .environmentObject(AppState.shared) // 建议注入 AppState，防止子视图崩溃
                .onAppear {
                    print("🚀 MumbleApp: SwiftUI Lifecycle Started")
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
