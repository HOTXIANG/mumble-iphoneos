//
//  ChannelView.swift
//  Mumble
//
//  Created by 王梓田 on 2025/1/3.
//

import SwiftUI
import UniformTypeIdentifiers

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
private let kRowSpacing: CGFloat = 7.0    // 行与行之间的间隙
private let kRowPaddingV: CGFloat = 6.0   // 行内部的垂直边距
private let kContentHeight: CGFloat = 27.0 // 内容高度
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
                    ServerChannelView(serverManager: serverManager, isSplitLayout: true)
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
                    
                    MessagesView(serverManager: serverManager, isSplitLayout: true)
                        .frame(width: calculateEffectiveChatWidth(totalWidth: geo.size.width))
                        .background(Color.black.opacity(0.15))
                        .onAppear { appState.unreadMessageCount = 0 }
                }
                .background(globalGradient)
            } else {
                // [窄屏模式]
                TabView(selection: $appState.currentTab) {
                    ServerChannelView(serverManager: serverManager, isSplitLayout: false)
                        .tabItem { Label("Channels", systemImage: "person.3.fill") }
                        .tag(AppState.Tab.channels)
                    
                    MessagesView(serverManager: serverManager, isSplitLayout: false)
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
    let isSplitLayout: Bool
    @State private var selectedUserForConfig: MKUser? = nil
    @State private var selectedUserForInfo: MKUser? = nil
    @State private var selectedChannelForInfo: MKChannel? = nil
    @State private var selectedUserForPM: MKUser? = nil
    @State private var selectedChannelForEdit: MKChannel? = nil
    @State private var selectedChannelForCreate: MKChannel? = nil
    
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
                            },
                            onUserInfoTap: { user in
                                self.selectedUserForInfo = user
                            },
                            onChannelInfoTap: { channel in
                                self.selectedChannelForInfo = channel
                            },
                            onUserPMTap: { user in
                                self.selectedUserForPM = user
                            },
                            onChannelEditTap: { channel in
                                self.selectedChannelForEdit = channel
                            },
                            onChannelCreateTap: { channel in
                                self.selectedChannelForCreate = channel
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
                .padding(.leading, 16)
                .padding(.trailing, isSplitLayout ? 4 : 16)
            }
        }
        .overlay(alignment: .bottom) {
            if let movingUser = serverManager.movingUser {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.right.arrow.left")
                        .foregroundColor(.white)
                        .font(.system(size: 12))
                    Text("Moving \(movingUser.userName() ?? "user") — tap a channel")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            serverManager.movingUser = nil
                        }
                    } label: {
                        Text("Cancel")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.25), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
                .background(Color.accentColor.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: serverManager.movingUser != nil)
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
        .sheet(item: $selectedUserForInfo) { user in
            let isSelf = user.session() == MUConnectionController.shared()?.serverModel?.connectedUser()?.session()
            UserInfoView(user: user, isSelf: isSelf)
        }
        .sheet(item: $selectedChannelForInfo) { channel in
            ChannelInfoView(channel: channel)
        }
        .sheet(item: $selectedUserForPM) { user in
            PrivateMessageInputView(
                targetUser: user,
                serverManager: serverManager
            )
        }
        .sheet(item: $selectedChannelForEdit) { channel in
            EditChannelView(
                channel: channel,
                serverManager: serverManager
            )
        }
        .sheet(item: $selectedChannelForCreate) { channel in
            CreateChannelView(
                parentChannel: channel,
                serverManager: serverManager
            )
        }
        .alert("Channel Password", isPresented: Binding(
            get: { serverManager.passwordPromptChannel != nil },
            set: { if !$0 { serverManager.passwordPromptChannel = nil } }
        )) {
            SecureField("Enter password", text: $serverManager.pendingPasswordInput)
            Button("Cancel", role: .cancel) {
                serverManager.passwordPromptChannel = nil
                serverManager.pendingPasswordInput = ""
            }
            Button("Join") {
                if let channel = serverManager.passwordPromptChannel {
                    serverManager.submitPasswordAndJoin(channel: channel, password: serverManager.pendingPasswordInput)
                }
                serverManager.passwordPromptChannel = nil
                serverManager.pendingPasswordInput = ""
            }
        } message: {
            if let channel = serverManager.passwordPromptChannel {
                Text("Enter the password to join \"\(channel.channelName() ?? "this channel")\"")
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
    let onUserInfoTap: (MKUser) -> Void
    let onChannelInfoTap: (MKChannel) -> Void
    var onUserPMTap: ((MKUser) -> Void)? = nil
    var onChannelEditTap: ((MKChannel) -> Void)? = nil
    var onChannelCreateTap: ((MKChannel) -> Void)? = nil
    
    @State private var isDropTargeted: Bool = false
    private let haptic = PlatformSelectionFeedback()
    
    var body: some View {
        Group {
            // A. 频道行 (Logic + UI)
            ZStack(alignment: .leading) {
                // 1. 底层：纯 UI 视图 (负责渲染外观)
                ChannelRowView(channel: channel, level: level, serverManager: serverManager)
                
                // 2. 顶层：交互控制层
                if isInMoveMode {
                    // Move mode: 整个频道行可点击，用于选择目标频道
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: kContentHeight + kRowPaddingV * 2)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            completeMoveToChannel()
                        }
                } else {
                HStack(spacing: 0) {
                    
                    // [区域 1] 缩进占位符
                    Spacer()
                        .frame(width: CGFloat(level) * kIndentUnit)
                    
                    // [区域 2] 箭头点击区
                    Color.clear
                        .frame(width: kArrowWidth + 24, height: kContentHeight + kRowPaddingV * 2)
                        .contentShape(Rectangle())
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
                                onChannelInfoTap(channel)
                            } label: {
                                Label("Channel Info", systemImage: "info.circle")
                            }
                            
                            if hasChannelEditPermission {
                                Divider()
                                
                                Button {
                                    onChannelCreateTap?(channel)
                                } label: {
                                    Label("Create Sub-Channel", systemImage: "plus.rectangle")
                                }
                                
                                Button {
                                    onChannelEditTap?(channel)
                                } label: {
                                    Label("Edit Channel", systemImage: "pencil.and.outline")
                                }
                            }
                            
                            // 监听频道（功能暂时搁置）
                            // if canListenToChannel {
                            //     Divider()
                            //     if serverManager.listeningChannels.contains(channel.channelId()) {
                            //         Button {
                            //             serverManager.stopListening(to: channel)
                            //         } label: {
                            //             Label("Stop Listening", systemImage: "ear")
                            //         }
                            //     } else {
                            //         Button {
                            //             serverManager.startListening(to: channel)
                            //         } label: {
                            //             Label("Listen to Channel", systemImage: "ear")
                            //         }
                            //     }
                            // }
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
                            onChannelInfoTap(channel)
                        } label: {
                            Label("Channel Info", systemImage: "info.circle")
                        }
                        
                        if hasChannelEditPermission {
                            Divider()
                            
                            Button {
                                onChannelCreateTap?(channel)
                            } label: {
                                Label("Create Sub-Channel", systemImage: "plus.rectangle")
                            }
                            
                            Button {
                                onChannelEditTap?(channel)
                            } label: {
                                Label("Edit Channel", systemImage: "pencil.and.outline")
                            }
                        }
                        
                        // 监听频道（功能暂时搁置）
                        // if canListenToChannel {
                        //     Divider()
                        //     if serverManager.listeningChannels.contains(channel.channelId()) {
                        //         Button {
                        //             serverManager.stopListening(to: channel)
                        //         } label: {
                        //             Label("Stop Listening", systemImage: "ear")
                        //         }
                        //     } else {
                        //         Button {
                        //             serverManager.startListening(to: channel)
                        //         } label: {
                        //             Label("Listen to Channel", systemImage: "ear")
                        //         }
                        //     }
                        // }
                    } label: {
                        Color.clear
                    }
                    .frame(maxWidth: .infinity, maxHeight: kContentHeight + kRowPaddingV * 2)
                    .contentShape(Rectangle())
                    #endif
                }
                } // end else (not move mode)
            }
            // 拖拽用户到此频道的 drop target
            .onDrop(of: [UTType.plainText], isTargeted: $isDropTargeted) { providers in
                handleUserDrop(providers: providers)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .opacity(isDropTargeted ? 1 : 0)
                    .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
            )
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
                        onTap: { onUserTap(user) },
                        onInfoTap: { u in onUserInfoTap(u) },
                        onPMTap: onUserPMTap
                    )
                    .opacity(isInMoveMode ? 0.3 : 1.0)
                    .allowsHitTesting(!isInMoveMode)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                }
                
                // 1.5. 频道监听者行
                let listeners = serverManager.getListeners(for: channel)
                ForEach(listeners, id: \.self) { listener in
                    ListenerRow(
                        listener: listener,
                        channel: channel,
                        level: level,
                        serverManager: serverManager
                    )
                    .opacity(isInMoveMode ? 0.3 : 1.0)
                    .allowsHitTesting(!isInMoveMode)
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
                        onUserTap: onUserTap,
                        onUserInfoTap: onUserInfoTap,
                        onChannelInfoTap: onChannelInfoTap,
                        onUserPMTap: onUserPMTap,
                        onChannelEditTap: onChannelEditTap,
                        onChannelCreateTap: onChannelCreateTap
                    )
                }
            }
        }
    }
    
    // 辅助属性：判断是否真的有内容（包括监听者）
    private var hasContent: Bool {
        let userCount = serverManager.getSortedUsers(for: channel).count
        let subChannelCount = (channel.channels() as? [MKChannel])?.count ?? 0
        let listenerCount = serverManager.channelListeners[channel.channelId()]?.count ?? 0
        return userCount > 0 || subChannelCount > 0 || listenerCount > 0
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
            // 标记为用户主动加入（确保扫描期间也弹出密码框）
            serverManager.markUserInitiatedJoin(channelId: channel.channelId())
            MUConnectionController.shared()?.serverModel?.join(channel)
        }
    }
    
    /// 是否处于 Move to 模式
    private var isInMoveMode: Bool {
        serverManager.movingUser != nil
    }
    
    /// 完成移动操作：将用户移动到当前频道
    private func completeMoveToChannel() {
        guard let user = serverManager.movingUser else { return }
        haptic.selectionChanged()
        serverManager.moveUser(user, toChannel: channel)
        withAnimation(.easeInOut(duration: 0.2)) {
            serverManager.movingUser = nil
        }
    }
    
    /// 检查当前用户是否有权限编辑频道（需要 Write 权限）或创建子频道（需要 MakeChannel 权限）
    private var hasChannelEditPermission: Bool {
        let chId = channel.channelId()
        return serverManager.hasPermission(MKPermissionWrite, forChannelId: chId) ||
               serverManager.hasPermission(MKPermissionMakeChannel, forChannelId: chId)
    }
    
    /// 是否可以监听此频道（不是自己当前所在的频道 + 有 Whisper 权限）
    private var canListenToChannel: Bool {
        guard let connectedUser = MUConnectionController.shared()?.serverModel?.connectedUser() else {
            return false
        }
        // 不能监听自己当前所在的频道
        if connectedUser.channel()?.channelId() == channel.channelId() { return false }
        // 检查用户是否已认证（简易权限检查，服务器会做最终校验）
        return connectedUser.isAuthenticated()
    }
    
    /// 处理拖拽用户到频道的 drop 操作
    private func handleUserDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.canLoadObject(ofClass: NSString.self) {
                provider.loadObject(ofClass: NSString.self) { item, _ in
                    guard let sessionString = item as? String,
                          let session = UInt(sessionString) else { return }
                    DispatchQueue.main.async {
                        serverManager.moveUser(session: session, toChannelId: channel.channelId())
                    }
                }
                return true
            }
        }
        return false
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
                
                if channel.isTemporary() {
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                }
                
                Spacer()
                
                // 人数标记（在锁图标左侧）
                if channel.maxUsers() > 0 {
                    Text("\(userCount)/\(channel.maxUsers())")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(UInt(userCount) >= channel.maxUsers() ? .red : .secondary)
                        .padding(.horizontal, 6)
                        .frame(minHeight: 20)
                        .background(Color.black.opacity(0.2), in: Capsule())
                } else if userCount > 0 {
                    Text("\(userCount)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .frame(minHeight: 20)
                        .background(Color.black.opacity(0.2), in: Capsule())
                }
                
                // 频道限制标记（最右侧）
                if let lockColor = channelLockColor {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundColor(lockColor)
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
        let lCount = serverManager.channelListeners[channel.channelId()]?.count ?? 0
        return uCount > 0 || cCount > 0 || lCount > 0
    }
    
    private var userCount: Int {
        return serverManager.getSortedUsers(for: channel).count
    }
    
    /// 频道锁图标颜色：绿色=受限但你可进入，橙色=密码频道，红色=无法进入
    private var channelLockColor: Color? {
        let chId = channel.channelId()
        let isRestricted = channel.isEnterRestricted() || serverManager.channelsWithPassword.contains(chId)
        guard isRestricted else { return nil }
        
        let userCanEnter = serverManager.channelsUserCanEnter.contains(chId)
        if userCanEnter {
            return .green // 受限频道但你有权进入
        } else if serverManager.channelsWithPassword.contains(chId) {
            return .orange // 已确认密码频道
        } else {
            return .red // 无法进入
        }
    }
}

// MARK: - 5. Styled User Row (用户行)

struct UserRowView: View {
    let user: MKUser
    @ObservedObject var serverManager: ServerModelManager
    
    let onTap: () -> Void
    var onInfoTap: ((MKUser) -> Void)? = nil
    var onPMTap: ((MKUser) -> Void)? = nil
    
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
    
    /// 检查当前用户是否有权限移动其他用户（需要目标用户所在频道的 Move 权限）
    private var hasMovePermission: Bool {
        let userChannelId = user.channel()?.channelId() ?? 0
        return serverManager.hasPermission(MKPermissionMove, forChannelId: userChannelId) ||
               serverManager.hasRootPermission(MKPermissionMove)
    }
    
    /// 是否有管理员权限（MuteDeafen 权限 = 服务器端静音/耳聋）
    private var hasAdminPermission: Bool {
        let userChannelId = user.channel()?.channelId() ?? 0
        return serverManager.hasPermission(MKPermissionMuteDeafen, forChannelId: userChannelId) ||
               serverManager.hasRootPermission(MKPermissionMuteDeafen)
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
                    
                    // 服务器端静音/耳聋（管理员操作）— 蓝色，与自行闭麦图标形状一致
                    if user.isDeafened() {
                        Image(systemName: "speaker.slash.fill").foregroundColor(.blue).font(.caption).transition(.symbolEffect(.appear))
                        Image(systemName: "mic.slash.fill").foregroundColor(.blue).font(.caption).transition(.symbolEffect(.appear))
                    } else if user.isMuted() {
                        Image(systemName: "mic.slash.fill").foregroundColor(.blue).font(.caption).transition(.symbolEffect(.appear))
                    }
                    if user.isSuppressed() {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow).font(.caption).transition(.symbolEffect(.appear))
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
                    Button { onInfoTap?(user) } label: { Label("User Info", systemImage: "person.circle") }
                    if !isMyself {
                        Button { onPMTap?(user) } label: { Label("Private Message", systemImage: "envelope.fill") }
                        if hasMovePermission {
                            Divider()
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    serverManager.movingUser = user
                                }
                            } label: {
                                Label("Move to...", systemImage: "arrow.right.arrow.left")
                            }
                        }
                        if hasAdminPermission {
                            Divider()
                            Button {
                                serverManager.setServerMuted(!user.isMuted(), for: user)
                            } label: {
                                if user.isMuted() {
                                    Label("Server Unmute", systemImage: "mic.fill")
                                } else {
                                    Label("Server Mute", systemImage: "mic.slash.fill")
                                }
                            }
                            Button {
                                serverManager.setServerDeafened(!user.isDeafened(), for: user)
                            } label: {
                                if user.isDeafened() {
                                    Label("Server Undeafen", systemImage: "speaker.wave.2.fill")
                                } else {
                                    Label("Server Deafen", systemImage: "speaker.slash.fill")
                                }
                            }
                        }
                    }
                }
            
            #if os(iOS)
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
                    
                    if !isMyself {
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
                    }
                    
                    // Action 3: 用户信息
                    Button {
                        onInfoTap?(user)
                    } label: {
                        Label("User Info", systemImage: "person.circle")
                    }
                    
                    // Action 4: 私聊
                    if !isMyself {
                        Button {
                            onPMTap?(user)
                        } label: {
                            Label("Private Message", systemImage: "envelope.fill")
                        }
                        
                        if hasMovePermission {
                            Divider()
                            
                            // Action 5: 移动到频道
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    serverManager.movingUser = user
                                }
                            } label: {
                                Label("Move to...", systemImage: "arrow.right.arrow.left")
                            }
                        }
                        
                        if hasAdminPermission {
                            Divider()
                            
                            // Action 6: 服务器端静音
                            Button {
                                serverManager.setServerMuted(!user.isMuted(), for: user)
                            } label: {
                                if user.isMuted() {
                                    Label("Server Unmute", systemImage: "mic.fill")
                                } else {
                                    Label("Server Mute", systemImage: "mic.slash.fill")
                                }
                            }
                            Button {
                                serverManager.setServerDeafened(!user.isDeafened(), for: user)
                            } label: {
                                if user.isDeafened() {
                                    Label("Server Undeafen", systemImage: "speaker.wave.2.fill")
                                } else {
                                    Label("Server Deafen", systemImage: "speaker.slash.fill")
                                }
                            }
                        }
                    }
                    
                } label: {
                    Color.clear
                }
                .contentShape(Rectangle()) // 确保透明区域可点击
            }
            #endif
        }
        #if os(macOS)
        .onDrag {
            // macOS: 提供用户 session ID 作为拖拽数据（仅认证用户可拖拽移动）
            guard hasMovePermission else {
                return NSItemProvider()
            }
            let sessionString = String(user.session())
            return NSItemProvider(object: sessionString as NSString)
        }
        #endif
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

extension MKChannel: Identifiable {
    public var id: UInt {
        return channelId()
    }
}

// MARK: - 7. Private Message Input Dialog

struct PrivateMessageInputView: View {
    let targetUser: MKUser
    @ObservedObject var serverManager: ServerModelManager
    
    @State private var messageText: String = ""
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // 目标用户
                HStack(spacing: 10) {
                    Image(systemName: "envelope.fill")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Private Message")
                            .font(.headline)
                        Text("To: \(targetUser.userName() ?? "Unknown")")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 8)
                
                // 输入区域
                TextEditor(text: $messageText)
                    .font(.body)
                    .frame(minHeight: 100)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(Color.black.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                    )
                    .padding(.horizontal)
                
                Spacer()
            }
            .navigationTitle("Private Message")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        sendMessage()
                    }
                    .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 250)
        #endif
    }
    
    private func sendMessage() {
        serverManager.sendPrivateMessage(messageText, to: targetUser)
        dismiss()
    }
}

// MARK: - Listener Row (监听行)

struct ListenerRow: View {
    let listener: MKUser
    let channel: MKChannel
    let level: Int
    @ObservedObject var serverManager: ServerModelManager
    
    private var isMyself: Bool {
        return listener == MUConnectionController.shared()?.serverModel?.connectedUser()
    }
    
    private var hasSpeaker: Bool {
        return serverManager.getSortedUsers(for: channel).contains { $0.talkState() == MKTalkStateTalking }
    }
    
    var body: some View {
        HStack(spacing: kHSpacing) {
            // 缩进：与该频道内的用户行保持一致
            let indentWidth = CGFloat(level) * kIndentUnit + kArrowWidth + 4
            Spacer().frame(width: indentWidth)
            
            // 耳朵图标（替代用户头像），有人说话时亮绿色
            Image(systemName: "ear")
                .font(.system(size: kIconSize))
                .foregroundColor(hasSpeaker ? .green : .gray)
                .frame(width: kContentHeight, height: kContentHeight)
                .shadow(color: hasSpeaker ? .green.opacity(0.6) : .clear, radius: hasSpeaker ? 4 : 0)
            
            // 监听者用户名：自己=cyan（与自己用户行一致），别人=白色
            Text(listener.userName() ?? "Unknown")
                .font(.system(size: kFontSize, weight: .medium))
                .foregroundColor(isMyself ? .cyan : .primary)
                .lineLimit(1)
            
            Spacer()
            
            // 右侧说话指示：仅在耳朵没亮时显示（耳朵亮了就不需要文字了）
            if !hasSpeaker {
                // 无人说话时不显示任何内容
            }
            
            // 自己的监听行显示停止按钮
            if isMyself {
                Button {
                    serverManager.stopListening(to: channel)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, kRowPaddingH)
        .padding(.vertical, kRowPaddingV)
        // 自己=indigo（与自己用户行一致），别人=普通无色
        .modifier(TintedGlassRowModifier(isHighlighted: isMyself, highlightColor: .indigo))
    }
}
