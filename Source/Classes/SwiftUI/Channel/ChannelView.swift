//
//  ChannelView.swift
//  Mumble
//
//  Created by 王梓田 on 2025/1/3.
//

import SwiftUI

// MARK: - Configuration Constants (UI 尺寸配置)

#if os(macOS)
private let kRowSpacing: CGFloat = 6.0    // 行与行之间的间隙
private let kRowPaddingV: CGFloat = 4.0   // 行内部的垂直边距
private let kContentHeight: CGFloat = 24.0 // 内容高度
private let kFontSize: CGFloat = 13.0     // 字体大小
private let kIconSize: CGFloat = 14.0     // 图标大小
private let kIndentUnit: CGFloat = 12.0   // 每级缩进
private let kRowPaddingH: CGFloat = 8.0   // 行内部的水平边距
private let kHSpacing: CGFloat = 4.0      // 水平间距
private let kArrowSize: CGFloat = 9.0     // 箭头大小
private let kArrowWidth: CGFloat = 14.0   // 箭头占位宽度
private let kChannelIconSize: CGFloat = 10.0
private let kChannelIconWidth: CGFloat = 16.0
#else
private let kRowSpacing: CGFloat = 6.0    // 行与行之间的间隙
private let kRowPaddingV: CGFloat = 6.0   // 行内部的垂直边距
private let kContentHeight: CGFloat = 28.0 // 内容高度
private let kFontSize: CGFloat = 16.0     // 字体大小
private let kIconSize: CGFloat = 18.0     // 图标大小
private let kIndentUnit: CGFloat = 16.0   // 每级缩进
private let kRowPaddingH: CGFloat = 12.0  // 行内部的水平边距
private let kHSpacing: CGFloat = 6.0      // 水平间距
private let kArrowSize: CGFloat = 10.0    // 箭头大小
private let kArrowWidth: CGFloat = 16.0   // 箭头占位宽度
private let kChannelIconSize: CGFloat = 12.0
private let kChannelIconWidth: CGFloat = 20.0
#endif

// MARK: - 1. Main Layout Container

struct ChannelView: View {
    @ObservedObject var serverManager: ServerModelManager
    @StateObject private var appState = AppState.shared
    
    @State private var userPreferredChatWidth: CGFloat = 320
    private let minChatWidth: CGFloat = 300
    private let minServerListWidth: CGFloat = 400

    var body: some View {
        GeometryReader { geo in
            if geo.size.width > 700 {
                // [宽屏模式]
                HStack(spacing: 0) {
                    ServerChannelView(serverManager: serverManager)
                        .frame(maxWidth: .infinity)
                    
                    ResizeHandle()
                        .gesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .named("ChannelViewSpace"))
                                .onChanged { value in
                                    let newWidth = geo.size.width - value.location.x
                                    let maxSafe = geo.size.width - minServerListWidth
                                    let limit = min(geo.size.width * 0.7, maxSafe)
                                    userPreferredChatWidth = min(max(newWidth, minChatWidth), limit)
                                }
                        )
                        .zIndex(10)
                    
                    MessagesView(serverManager: serverManager)
                        .frame(width: calculateEffectiveChatWidth(totalWidth: geo.size.width))
                        .background(Color.black.opacity(0.15))
                        .onAppear { appState.unreadMessageCount = 0 }
                }
                .background(globalGradient)
            } else {
                // [窄屏模式]
                TabView(selection: $appState.currentTab) {
                    ServerChannelView(serverManager: serverManager)
                        .tabItem { Label("Channels", systemImage: "person.3.fill") }
                        .tag(AppState.Tab.channels)
                    
                    MessagesView(serverManager: serverManager)
                        .tabItem { Label("Messages", systemImage: "message.fill") }
                        .tag(AppState.Tab.messages)
                        .badge(appState.unreadMessageCount > 0 ? "\(appState.unreadMessageCount)" : nil)
                }
                .background(globalGradient)
                #if os(iOS)
                .toolbarBackground(.clear, for: .tabBar)
                .toolbarBackground(.hidden, for: .tabBar)
                #endif
                .onChange(of: appState.currentTab) {
                    if appState.currentTab == .messages { serverManager.markAsRead() }
                }
                .onAppear { configureTabBarAppearance() }
            }
        }
        .coordinateSpace(name: "ChannelViewSpace")
        .onAppear { serverManager.activate() }
        .onDisappear { serverManager.cleanup() }
    }
    
    private var globalGradient: some View {
        LinearGradient(
            gradient: Gradient(colors: [
                Color(red: 0.20, green: 0.20, blue: 0.25),
                Color(red: 0.07, green: 0.07, blue: 0.10)
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
    
    private func calculateEffectiveChatWidth(totalWidth: CGFloat) -> CGFloat {
        let maxSafeWidth = totalWidth - minServerListWidth
        let effective = min(userPreferredChatWidth, maxSafeWidth)
        return max(effective, minChatWidth)
    }
    
    private func configureTabBarAppearance() {
        #if os(iOS)
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundColor = .clear
        appearance.backgroundEffect = nil
        appearance.shadowColor = .clear
        UITabBar.appearance().standardAppearance = appearance
        if #available(iOS 15.0, *) {
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }
        #endif
    }
}

// MARK: - 2. Channel List Implementation

struct ServerChannelView: View {
    @ObservedObject var serverManager: ServerModelManager
    @State private var selectedUserForConfig: MKUser? = nil
    
    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.20, green: 0.20, blue: 0.25),
                    Color(red: 0.07, green: 0.07, blue: 0.10)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: kRowSpacing) {
                    Color.clear.frame(height: 10)
                    
                    if let root = MUConnectionController.shared()?.serverModel?.rootChannel() {
                        ChannelTreeRow(
                            channel: root,
                            level: 0,
                            serverManager: serverManager,
                            onUserTap: { user in
                                self.selectedUserForConfig = user
                            }
                        )
                    } else {
                        VStack(spacing: 12) {
                            ProgressView().tint(.white)
                            Text("Loading channels...")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 100)
                    }
                    
                    Color.clear.frame(height: 80)
                }
                .padding(.horizontal, 16)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .sheet(item: $selectedUserForConfig) { user in
            UserAudioSettingsView(
                manager: serverManager,
                userSession: user.session(),
                userName: user.userName() ?? "User"
            )
            .presentationDetents([.medium])
        }
    }
}

// MARK: - 3. Recursive Tree Components

struct ChannelTreeRow: View {
    let channel: MKChannel
    let level: Int
    @ObservedObject var serverManager: ServerModelManager
    
    let onUserTap: (MKUser) -> Void
    
    private let haptic = PlatformSelectionFeedback()
    
    var body: some View {
        Group {
            // A. 频道行 (Logic + UI)
            ZStack(alignment: .leading) {
                // 1. 底层：纯 UI 视图 (负责渲染外观)
                ChannelRowView(channel: channel, level: level, serverManager: serverManager)
                
                // 2. 顶层：交互控制层 (透明覆盖)
                // 使用 HStack 布局，确保点击区域与视觉元素位置完全对齐
                HStack(spacing: 0) {
                    
                    // [区域 1] 缩进占位符 (不可点击，透传给 List 选中或者无操作)
                    // 这里的宽度必须与 UI 层的缩进 Spacer 完全一致
                    Spacer()
                        .frame(width: CGFloat(level) * kIndentUnit)
                    
                    // [区域 2] 箭头点击区 (跟随缩进移动)
                    Color.clear
                        .frame(width: kArrowWidth + 24, height: kContentHeight + kRowPaddingV * 2)
                        .contentShape(Rectangle()) // 确保透明区域可点击
                        .onTapGesture {
                            toggleCollapse()
                        }
                    
                    // [区域 3] 频道内容点击区
                    #if os(macOS)
                    // macOS: 双击进入频道，右键上下文菜单
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: kContentHeight + kRowPaddingV * 2)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            joinChannel()
                        }
                        .contextMenu {
                            Button {
                                joinChannel()
                            } label: {
                                Label("Join Channel", systemImage: "arrow.right.to.line")
                            }
                            Button {
                                // TODO: Show Info
                            } label: {
                                Label("Channel Info", systemImage: "info.circle")
                            }
                        }
                    #else
                    // iOS: 点击弹出菜单
                    Menu {
                        Text(channel.channelName() ?? "Channel")
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .padding(.bottom, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                        
                        Button {
                            joinChannel()
                        } label: {
                            Label("Join Channel", systemImage: "arrow.right.to.line")
                        }
                        
                        Button {
                            // TODO: Show Info
                        } label: {
                            Label("Channel Info", systemImage: "info.circle")
                        }
                    } label: {
                        Color.clear
                    }
                    .frame(maxWidth: .infinity, maxHeight: kContentHeight + kRowPaddingV * 2)
                    .contentShape(Rectangle())
                    #endif
                }
            }
            // List Row 配置
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
            
            // B. 子内容区域
            if hasContent && !serverManager.isChannelCollapsed(Int(channel.channelId())) {
                // 1. 用户
                let users = serverManager.getSortedUsers(for: channel)
                ForEach(users, id: \.self) { user in
                    UserRowView(
                        user: user,
                        serverManager: serverManager,
                        onTap: { onUserTap(user) }
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                }
                
                // 2. 子频道 (递归)
                let subChannels = serverManager.getSortedSubChannels(for: channel)
                ForEach(subChannels, id: \.self) { subChannel in
                    ChannelTreeRow(
                        channel: subChannel,
                        level: level + 1,
                        serverManager: serverManager,
                        onUserTap: onUserTap
                    )
                }
            }
        }
    }
    
    // 辅助属性：判断是否真的有内容
    private var hasContent: Bool {
        let userCount = serverManager.getSortedUsers(for: channel).count
        let subChannelCount = (channel.channels() as? [MKChannel])?.count ?? 0
        return userCount > 0 || subChannelCount > 0
    }
    
    private func toggleCollapse() {
        if hasContent {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                serverManager.toggleChannelCollapse(Int(channel.channelId()))
                haptic.selectionChanged()
            }
        }
    }
    
    private func joinChannel() {
        let current = MUConnectionController.shared()?.serverModel?.connectedUser()?.channel()
        if current != channel {
            haptic.selectionChanged()
            MUConnectionController.shared()?.serverModel?.join(channel)
        }
    }
}

// MARK: - 4. Styled Channel Row (频道行)

struct ChannelRowView: View {
    let channel: MKChannel
    let level: Int
    @ObservedObject var serverManager: ServerModelManager
    
    private let haptic = PlatformSelectionFeedback()
    
    var body: some View {
        HStack(spacing: kHSpacing) {
            // 1. 缩进
            Spacer().frame(width: CGFloat(level) * kIndentUnit)
            
            // 2. 折叠箭头 (独立交互，不触发菜单)
            if hasChildren {
                Image(systemName: "chevron.right")
                    .font(.system(size: kArrowSize, weight: .bold))
                    .foregroundColor(.gray)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: kArrowWidth, height: kContentHeight)
            } else {
                Color.clear.frame(width: kArrowWidth, height: kContentHeight)
            }
            
            // 3. 频道信息区域
            HStack(spacing: kHSpacing) {
                Image(systemName: "number")
                    .foregroundColor(isCurrentChannel ? .green : .secondary)
                    .font(.system(size: kChannelIconSize, weight: .semibold))
                    .frame(width: kChannelIconWidth, height: kContentHeight)
                
                Text(channel.channelName() ?? "Unknown")
                    .font(.system(size: kFontSize, weight: .medium))
                    .foregroundColor(isCurrentChannel ? .green : .primary)
                    .shadow(radius: 1)
                    .lineLimit(1)
                
                Spacer()
                
                if userCount > 0 {
                    Text("\(userCount)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .frame(minHeight: 20)
                        .background(Color.black.opacity(0.2), in: Capsule())
                }
            }
        }
        .padding(.horizontal, kRowPaddingH)
        .padding(.vertical, kRowPaddingV)
        .modifier(TintedGlassRowModifier(isHighlighted: isCurrentChannel, highlightColor: .blue))
    }
    
    private var isCurrentChannel: Bool {
        let current = MUConnectionController.shared()?.serverModel?.connectedUser()?.channel()
        return current == channel
    }
    
    private var isCollapsed: Bool {
        serverManager.isChannelCollapsed(Int(channel.channelId()))
    }
    
    private var hasChildren: Bool {
        let uCount = serverManager.getSortedUsers(for: channel).count
        let cCount = (channel.channels() as? [MKChannel])?.count ?? 0
        return uCount > 0 || cCount > 0
    }
    
    private var userCount: Int {
        return serverManager.getSortedUsers(for: channel).count
    }
}

// MARK: - 5. Styled User Row (用户行)

struct UserRowView: View {
    let user: MKUser
    @ObservedObject var serverManager: ServerModelManager
    
    let onTap: () -> Void
    
    private var currentVolume: Float {
        if let vol = serverManager.userVolumes[user.session()] {
            return vol
        }
        
        return user.localVolume
    }
    
    private var dynamicLevel: Int {
        var depth = 0
        var current = user.channel()
        // 只要还有父频道，就说明层级+1 (Root 的 parent 为 nil)
        while let parent = current?.parent() {
            depth += 1
            current = parent
        }
        return depth
    }
    
    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: kHSpacing) {
                let level = dynamicLevel
                let indentWidth = CGFloat(level) * kIndentUnit + kArrowWidth + 4
                // 缩进
                Spacer().frame(width: indentWidth)
                
                // Avatar
                AvatarView(talkingState: isTalking ? .talking : .silent)
                
                // 用户名
                Text(user.userName() ?? "Unknown")
                    .font(.system(size: kFontSize, weight: .medium))
                    .foregroundColor(isMyself ? .cyan : .primary)
                    .shadow(radius: isMyself ? 1 : 0)
                    .lineLimit(1)
                
                if abs(currentVolume - 1.0) > 0.01 {
                    Text("\(Int(currentVolume * 100))%")
                        .font(.system(size: 9, weight: .bold))
                    // 大于 100% 橙色，小于 100% 灰色
                        .foregroundColor(currentVolume > 1.0 ? .orange : .gray)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.3))
                                .overlay(
                                    Capsule().stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                                )
                        )
                        .transition(.scale.combined(with: .opacity))
                }
                
                Spacer()
                
                // 状态图标
                HStack(spacing: 8) {
                    if user.isLocalMuted() {
                        Image(systemName: "speaker.slash.fill")
                            .foregroundColor(.yellow)
                            .font(.caption)
                            .transition(.symbolEffect(.appear))
                    }
                    if user.isSelfDeafened() {
                        Image(systemName: "speaker.slash.fill").foregroundColor(.red).font(.caption).transition(.symbolEffect(.appear))
                        Image(systemName: "mic.slash.fill").foregroundColor(.red).font(.caption).transition(.symbolEffect(.appear))
                    } else if user.isSelfMuted() {
                        Image(systemName: "mic.slash.fill").foregroundColor(.orange).font(.caption).transition(.symbolEffect(.appear))
                    }
                    
                    if user.isPrioritySpeaker() {
                        Image(systemName: "star.fill").foregroundColor(.yellow).font(.caption).transition(.symbolEffect(.appear))
                    }
                    
                    if user.isAuthenticated() {
                        Image(systemName: "checkmark.shield.fill").foregroundColor(.green).font(.caption).transition(.symbolEffect(.appear))
                    }
                }
            }
            .padding(.horizontal, kRowPaddingH)
            .padding(.vertical, kRowPaddingV)
            .modifier(TintedGlassRowModifier(isHighlighted: isMyself, highlightColor: .indigo))
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: kContentHeight + kRowPaddingV * 2)
                .contentShape(Rectangle())
                .contextMenu {
                    if !isMyself {
                        Button {
                            serverManager.toggleLocalUserMute(session: user.session())
                        } label: {
                            if user.isLocalMuted() {
                                Label("Unmute Locally", systemImage: "speaker.wave.2.fill")
                            } else {
                                Label("Mute Locally", systemImage: "speaker.slash.fill")
                            }
                        }
                        Button {
                            onTap()
                        } label: {
                            Label("Audio Settings...", systemImage: "slider.horizontal.3")
                        }
                        Divider()
                    }
                    Button(action: {}) { Label("User Info", systemImage: "person.circle") }
                }
            
            #if os(iOS)
            if !isMyself {
                HStack(spacing: 0) {
                    let level = dynamicLevel
                    // 避开前面的缩进区域，确保点击的是内容部分
                    Spacer().frame(width: CGFloat(level) * kIndentUnit)
                    
                    Menu {
                        // Menu Header
                        Text(user.userName() ?? "User")
                            .font(.caption)
                            .foregroundColor(.gray)
                        
                        Divider()
                        
                        // Action 1: 本地静音/取消静音
                        Button {
                            serverManager.toggleLocalUserMute(session: user.session())
                        } label: {
                            if user.isLocalMuted() {
                                Label("Unmute Locally", systemImage: "speaker.wave.2.fill")
                            } else {
                                Label("Mute Locally", systemImage: "speaker.slash.fill")
                            }
                        }
                        
                        // Action 2: 打开详细音频设置
                        Button {
                            onTap()
                        } label: {
                            Label("Audio Settings...", systemImage: "slider.horizontal.3")
                        }
                        
                        Divider()
                        
                        // Action 3: 用户信息 (占位)
                        Button {
                            // Show User Info Logic
                        } label: {
                            Label("User Info", systemImage: "person.circle")
                        }
                        
                    } label: {
                        Color.clear
                    }
                    .contentShape(Rectangle()) // 确保透明区域可点击
                }
            }
            #endif
        }
    }
    
    private var isMyself: Bool {
        return user == MUConnectionController.shared()?.serverModel?.connectedUser()
    }
    
    private var isTalking: Bool {
        return user.talkState() == MKTalkStateTalking
    }
}

// MARK: - 6. Helper Components

private struct AvatarView: View {
    enum TalkingState { case talking, silent }
    let talkingState: TalkingState
    
    var body: some View {
        Image(systemName: "person.fill")
            .font(.system(size: kIconSize))
            .foregroundColor(talkingState == .talking ? .green : .gray)
            .frame(width: kContentHeight, height: kContentHeight)
            .shadow(radius: talkingState == .talking ? 4 : 0)
    }
}

struct ResizeHandle: View {
    @State private var isHovering = false
    
    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
                .frame(width: 24)
                .padding(.bottom, 8)
                .contentShape(Rectangle())
            Rectangle()
                .fill(isHovering ? Color.white.opacity(0.5) : Color.white.opacity(0.1))
                .frame(width: 4)
                .padding(.bottom, 8)
                .cornerRadius(2)
        }
        .onHover { hovering in withAnimation { isHovering = hovering } }
    }
}

extension MKUser: Identifiable {
    public var id: UInt {
        return session()
    }
}
