// 文件: ChannelView.swift (已清理)

import SwiftUI

struct ChannelView: View {
    @ObservedObject var serverManager: ServerModelManager
    // 监听我们创建的全局 AppState
    @StateObject private var appState = AppState.shared
    
    @State private var selectedTab: ContentType = .channels
    enum ContentType { case channels, messages }
    
    var body: some View {
        // --- 核心修改 2：TabView 的 selection 直接绑定到 $appState.currentTab ---
        TabView(selection: $appState.currentTab) {
            ServerChannelView(serverManager: serverManager)
                .tabItem { Label("Channels", systemImage: "person.3.fill") }
                .tag(AppState.Tab.channels) // 使用 AppState.Tab
            
            MessagesView(serverManager: serverManager)
                .tabItem { Label("Messages", systemImage: "message.fill") }
                .tag(AppState.Tab.messages) // 使用 AppState.Tab
                .badge(appState.unreadMessageCount > 0 ? "\(appState.unreadMessageCount)" : nil)
        }
        // --- 核心修改 3：逻辑被极大地简化 ---
        .onChange(of: appState.currentTab) {
            // 当 Tab 切换到 messages 时，清空未读计数
            if appState.currentTab == .messages {
                appState.unreadMessageCount = 0
            }
        }
        .onAppear {
            // 将所有 onAppear 的逻辑合并到一个地方
            let appearance = UITabBarAppearance()
            appearance.configureWithTransparentBackground()
            UITabBar.appearance().standardAppearance = appearance
            UITabBar.appearance().scrollEdgeAppearance = appearance
            
            serverManager.activate()
        }
        .onDisappear {
            serverManager.cleanup()
        }
        .ignoresSafeArea(edges: .top)
    }
    
}
