// 文件: ChannelView.swift (已清理)

import SwiftUI

struct ChannelView: View {
    @ObservedObject var serverManager: ServerModelManager
    @StateObject private var appState = AppState.shared
    
    @State private var userPreferredChatWidth: CGFloat = 320
    
    private let minChatWidth: CGFloat = 300       // 聊天栏最小宽度
    private let minServerListWidth: CGFloat = 400 // 服务器列表最小安全宽度

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 全局背景：蓝灰渐变
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(red: 0.20, green: 0.20, blue: 0.25),
                        Color(red: 0.07, green: 0.07, blue: 0.10)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                
                // --- 核心逻辑：响应式布局 ---
                if geo.size.width > 700 {
                    // [宽屏模式]：三栏结构 (左侧频道 + 右侧聊天)
                    HStack(spacing: 0) {
                        // 左侧：频道列表 (自动占据剩余空间)
                        ServerChannelView(serverManager: serverManager)
                            .frame(maxWidth: .infinity)
                        
                        ResizeHandle()
                            .gesture(
                                DragGesture(minimumDistance: 1, coordinateSpace: .named("ChannelViewSpace"))
                                    .onChanged { value in
                                        // 绝对坐标计算：手指在哪，分界线就在哪
                                        // 聊天栏宽度 = 总宽度 - 手指的 X 坐标
                                        // (减去一点偏移量可以让手指对齐分割线中心，不减也可以)
                                        let newWidth = geo.size.width - value.location.x
                                        
                                        // 实时限制拖动范围
                                        let maxAvailableWidth = geo.size.width - minServerListWidth
                                        
                                        // 限制 1: 不能小于最小聊天宽
                                        // 限制 2: 不能挤压服务器列表 (最大宽度受限)
                                        // 限制 3: 也不建议超过屏幕的 70% (可选)
                                        let limitMaxWidth = min(geo.size.width * 0.7, maxAvailableWidth)
                                        
                                        // 更新状态
                                        userPreferredChatWidth = min(max(newWidth, minChatWidth), limitMaxWidth)
                                    }
                            )
                            .zIndex(10)
                        
                        // 右侧：聊天栏 (动态宽度)
                        MessagesView(serverManager: serverManager)
                            .frame(width: calculateEffectiveChatWidth(totalWidth: geo.size.width))
                            .background(Color.black.opacity(0.15))
                            .onAppear {
                                appState.unreadMessageCount = 0
                            }
                    }
                } else {
                    // [窄屏模式]：TabView
                    TabView(selection: $appState.currentTab) {
                        ServerChannelView(serverManager: serverManager)
                            .tabItem { Label("Channels", systemImage: "person.3.fill") }
                            .tag(AppState.Tab.channels)
                        
                        MessagesView(serverManager: serverManager)
                            .tabItem { Label("Messages", systemImage: "message.fill") }
                            .tag(AppState.Tab.messages)
                            .badge(appState.unreadMessageCount > 0 ? "\(appState.unreadMessageCount)" : nil)
                    }
                    .onChange(of: appState.currentTab) {
                        if appState.currentTab == .messages {
                            appState.unreadMessageCount = 0
                        }
                    }
                    .onAppear {
                        configureTabBarAppearance()
                    }
                }
            }
        }
        .coordinateSpace(name: "ChannelViewSpace")
        .onAppear {
            serverManager.activate()
        }
        .onDisappear {
            serverManager.cleanup()
        }
    }
    
    private func calculateEffectiveChatWidth(totalWidth: CGFloat) -> CGFloat {
        // 1. 计算为了保护左侧服务器列表，右侧最大能是多少
        let maxSafeWidth = totalWidth - minServerListWidth
        
        // 2. 取 "用户想要的宽度" 和 "最大安全宽度" 的较小值
        // 这实现了：当窗口变窄时，自动压缩聊天栏直到它消失（或者切换模式）
        let effective = min(userPreferredChatWidth, maxSafeWidth)
        
        // 3. 但也不能小于聊天栏的最小设计宽度 (防止 UI 错乱)
        // 如果这里 effective < minChatWidth，说明屏幕实在太窄了，
        // 但通常 totalWidth < 700 的判断会先拦截并切换到 TabView 模式，
        // 所以这里主要处理 700 ~ 800 这种中间态。
        return max(effective, minChatWidth)
    }
    
    private func configureTabBarAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        UITabBar.appearance().standardAppearance = appearance
        if #available(iOS 15.0, *) {
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }
    }
}

// 辅助视图：分割线手柄
struct ResizeHandle: View {
    @State private var isHovering = false
    
    var body: some View {
        ZStack {
            // 透明触摸热区 (24pt 宽，增加可点击面积)
            Rectangle()
                .fill(Color.clear)
                .frame(width: 24)
                .contentShape(Rectangle())
            
            // 视觉线 (细线，优雅)
            Rectangle()
                .fill(isHovering ? Color.white.opacity(0.5) : Color.white.opacity(0.1))
                .frame(width: 4)
                .cornerRadius(2)
        }
        // iPad 触控板/鼠标支持
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }
}
