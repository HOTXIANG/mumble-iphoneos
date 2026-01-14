//
//  ChannelView.swift
//  Mumble
//
//  Created by 王梓田 on 2025/1/3.
//

import SwiftUI

// MARK: - Configuration Constants (UI 尺寸配置)

private let kRowSpacing: CGFloat = 6.0    // 行与行之间的间隙
private let kRowPaddingV: CGFloat = 6.0   // 行内部的垂直边距
private let kContentHeight: CGFloat = 28.0 // 内容高度
private let kFontSize: CGFloat = 16.0     // 字体大小
private let kIconSize: CGFloat = 18.0     // 图标大小

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
                        .background(globalGradient)
                }
                .onChange(of: appState.currentTab) {
                    if appState.currentTab == .messages { appState.unreadMessageCount = 0 }
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
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        UITabBar.appearance().standardAppearance = appearance
        if #available(iOS 15.0, *) {
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }
    }
}

// MARK: - 2. Channel List Implementation

struct ServerChannelView: View {
    @ObservedObject var serverManager: ServerModelManager
    @State private var showingAudioSettings = false
    @State private var selectedUserForConfig: MKUser? = nil
    
    var body: some View {
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
                            self.showingAudioSettings = true
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
        .scrollContentBackground(.hidden)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.20, green: 0.20, blue: 0.25),
                    Color(red: 0.07, green: 0.07, blue: 0.10)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .sheet(isPresented: $showingAudioSettings) {
            if let user = selectedUserForConfig {
                UserAudioSettingsView(
                    manager: serverManager,
                    userSession: user.session(),
                    userName: user.userName() ?? "User"
                )
                .presentationDetents([.fraction(0.3)])
            }
        }
    }
}

// MARK: - 3. Recursive Tree Components

struct ChannelTreeRow: View {
    let channel: MKChannel
    let level: Int
    @ObservedObject var serverManager: ServerModelManager
    
    let onUserTap: (MKUser) -> Void
    
    private let haptic = UISelectionFeedbackGenerator()
    
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
                        .frame(width: CGFloat(level * 16))
                    
                    // [区域 2] 箭头点击区 (跟随缩进移动)
                    // 宽度 = 箭头视觉宽度(16) + 适当的点击热区余量(比如共 50)
                    Color.clear
                        .frame(width: 50, height: kContentHeight + kRowPaddingV * 2)
                        .contentShape(Rectangle()) // 确保透明区域可点击
                        .onTapGesture {
                            toggleCollapse()
                        }
                    
                    // [区域 3] 频道内容点击区 -> 弹出菜单
                    // 占据剩余的所有宽度
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
                        level: level + 1,
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
        let userCount = (channel.users() as? [MKUser])?.count ?? 0
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
    
    private let haptic = UISelectionFeedbackGenerator()
    
    var body: some View {
        HStack(spacing: 6) {
            // 1. 缩进
            Spacer().frame(width: CGFloat(level * 16))
            
            // 2. 折叠箭头 (独立交互，不触发菜单)
            if hasChildren {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.gray)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 16, height: kContentHeight)
            } else {
                Color.clear.frame(width: 16, height: kContentHeight)
            }
            
            // 3. 频道信息区域
            HStack(spacing: 6) {
                Image(systemName: "number")
                    .foregroundColor(isCurrentChannel ? .green : .secondary)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 20, height: kContentHeight)
                
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
        .padding(.horizontal, 12)
        .padding(.vertical, kRowPaddingV)
        .glassEffect(.clear.interactive().tint(isCurrentChannel ? Color.blue.opacity(0.5) : Color.blue.opacity(0.0)), in: .rect(cornerRadius: 12))
    }
    
    private var isCurrentChannel: Bool {
        let current = MUConnectionController.shared()?.serverModel?.connectedUser()?.channel()
        return current == channel
    }
    
    private var isCollapsed: Bool {
        serverManager.isChannelCollapsed(Int(channel.channelId()))
    }
    
    private var hasChildren: Bool {
        let uCount = (channel.users() as? [MKUser])?.count ?? 0
        let cCount = (channel.channels() as? [MKChannel])?.count ?? 0
        return uCount > 0 || cCount > 0
    }
    
    private var userCount: Int {
        (channel.users() as? [MKUser])?.count ?? 0
    }
}

// MARK: - 5. Styled User Row (用户行)

struct UserRowView: View {
    let user: MKUser
    let level: Int
    @ObservedObject var serverManager: ServerModelManager
    
    let onTap: () -> Void
    
    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 6) {
                // 缩进: level*16 + 箭头位(16) + 图标位(20)的微调
                Spacer().frame(width: CGFloat(level * 16) + 24)
                
                // Avatar
                AvatarView(talkingState: isTalking ? .talking : .silent)
                
                // 用户名
                Text(user.userName() ?? "Unknown")
                    .font(.system(size: kFontSize, weight: .medium))
                    .foregroundColor(isMyself ? .cyan : .primary)
                    .shadow(radius: isMyself ? 1 : 0)
                    .lineLimit(1)
                
                Spacer()
                
                // 状态图标
                HStack(spacing: 8) {
                    if user.isLocalMuted() {
                        Image(systemName: "speaker.slash.fill")
                            .foregroundColor(.yellow)
                            .font(.caption)
                    }
                    if user.isSelfDeafened() {
                        Image(systemName: "speaker.slash.fill").foregroundColor(.red).font(.caption)
                        Image(systemName: "mic.slash.fill").foregroundColor(.red).font(.caption)
                    } else if user.isSelfMuted() {
                        Image(systemName: "mic.slash.fill").foregroundColor(.orange).font(.caption)
                    }
                    
                    if user.isPrioritySpeaker() {
                        Image(systemName: "star.fill").foregroundColor(.yellow).font(.caption)
                    }
                    
                    if user.isAuthenticated() {
                        Image(systemName: "checkmark.shield.fill").foregroundColor(.green).font(.caption)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, kRowPaddingV)
            .glassEffect(.clear.interactive().tint(isMyself ? Color.indigo.opacity(0.5) : Color.indigo.opacity(0.0)), in: .rect(cornerRadius: 12))
            .contextMenu {
                Button(action: {}) { Label("User Info", systemImage: "person.circle") }
            }
            
            HStack(spacing: 0) {
                // 避开前面的缩进区域，确保点击的是内容部分
                Spacer().frame(width: CGFloat(level * 16))
                
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
            .foregroundColor(talkingState == .talking ? .green : Color(uiColor: .systemGray))
            .frame(width: kContentHeight, height: kContentHeight)
            .shadow(radius: talkingState == .talking ? 4 : 0)
    }
}

struct ResizeHandle: View {
    @State private var isHovering = false
    
    var body: some View {
        ZStack {
            Rectangle().fill(Color.clear).frame(width: 24).contentShape(Rectangle())
            Rectangle()
                .fill(isHovering ? Color.white.opacity(0.5) : Color.white.opacity(0.1))
                .frame(width: 4)
                .cornerRadius(2)
        }
        .onHover { hovering in withAnimation { isHovering = hovering } }
    }
}
