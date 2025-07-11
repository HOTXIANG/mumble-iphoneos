// 文件: ChannelView.swift (已清理)

import SwiftUI

struct ChannelView: View {
    @ObservedObject var serverManager: ServerModelManager
    @State private var selectedTab: ContentType = .channels
    enum ContentType { case channels, messages }

    var body: some View {
        // TabView 是根视图，它自身是透明的
        TabView(selection: $selectedTab) {
            ServerChannelView(serverManager: serverManager)
                .tabItem { Label("Channels", systemImage: "person.3.fill") }
                .tag(ContentType.channels)
            
            MessagesView(serverManager: serverManager)
                .tabItem { Label("Messages", systemImage: "message.fill") }
                .tag(ContentType.messages)
        }
        // 我们依然需要这个来让 TabBar 本身变透明
        .onAppear {
            let appearance = UITabBarAppearance()
            appearance.configureWithTransparentBackground()
            UITabBar.appearance().standardAppearance = appearance
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }
        .onAppear { serverManager.activate() }
        .onDisappear { serverManager.cleanup() }
    }
}
