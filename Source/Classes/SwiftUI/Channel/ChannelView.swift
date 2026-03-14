//
//  ChannelView.swift
//  Mumble
//
//  Created by 王梓田 on 2025/1/3.
//

import SwiftUI
import PhotosUI
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
    @Environment(\.colorScheme) private var colorScheme
    
    @State private var userPreferredChatWidth: CGFloat = -1
    private let minChatWidth: CGFloat = 300
    private let minServerListWidth: CGFloat = {
        #if os(macOS)
        350
        #else
        400
        #endif
    }()
    private let splitThreshold: CGFloat = {
        #if os(macOS)
        return 550
        #else
        return 600
        #endif
    }()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if geo.size.width > splitThreshold {
                    // [宽屏模式]
                    HStack(spacing: 0) {
                        ServerChannelView(serverManager: serverManager, isSplitLayout: true)
                            .frame(maxWidth: .infinity)
                        
                        ResizeHandle()
                            .gesture(
                                DragGesture(minimumDistance: 1, coordinateSpace: .named("ChannelViewSpace"))
                                    .onChanged { value in
                                        let handleHalfWidth: CGFloat = 12
                                        let newWidth = geo.size.width - value.location.x - handleHalfWidth
                                        let maxSafe = geo.size.width - minServerListWidth
                                        let limit = min(geo.size.width * 0.7, maxSafe)
                                        userPreferredChatWidth = min(max(newWidth, minChatWidth), limit)
                                    }
                            )
                            .zIndex(10)
                        
                        MessagesView(serverManager: serverManager, isSplitLayout: true)
                            .frame(width: calculateEffectiveChatWidth(totalWidth: geo.size.width))
                            .onAppear { appState.unreadMessageCount = 0 }
                    }
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
                    #if os(iOS)
                    .toolbarBackground(.clear, for: .tabBar)
                    .toolbarBackground(.hidden, for: .tabBar)
                    #endif
                    .onChange(of: appState.currentTab) {
                        if appState.currentTab == .messages { serverManager.markAsRead() }
                    }
                    .onAppear { configureTabBarAppearance() }
                }

                globalGradient
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: "ChannelViewSpace")
        .onAppear { serverManager.activate() }
        .onDisappear { serverManager.cleanup() }
    }
    
    private var globalGradient: some View {
        LinearGradient(
            colors: [
                Color(red: 0.30, green: 0.30, blue: 0.62).opacity(0.07),
                Color(red: 0.33, green: 0.32, blue: 0.75).opacity(0.10)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
    
    private func calculateEffectiveChatWidth(totalWidth: CGFloat) -> CGFloat {
        let handleWidth: CGFloat = 24
        let preferred = userPreferredChatWidth < 0
            ? (totalWidth - handleWidth) / 2
            : userPreferredChatWidth
        let maxSafeWidth = totalWidth - minServerListWidth
        let effective = min(preferred, maxSafeWidth)
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
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedUserForConfig: MKUser? = nil
    @State private var selectedUserForInfo: MKUser? = nil
    @State private var selectedUserForStats: MKUser? = nil
    @State private var selectedChannelForInfo: MKChannel? = nil
    @State private var selectedUserForPM: MKUser? = nil
    @State private var selectedChannelForEdit: MKChannel? = nil
    @State private var selectedChannelForCreate: MKChannel? = nil
    @State private var selectedUserForRename: MKUser? = nil
    @State private var pendingNicknameInput: String = ""
    
    var body: some View {
        ZStack {
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
                            onUserStatsTap: { user in
                                self.selectedUserForStats = user
                            },
                            onUserRenameTap: { user in
                                self.selectedUserForRename = user
                                self.pendingNicknameInput = serverManager.localNicknames[user.session()] ?? ""
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
                            ProgressView().tint(.accentColor)
                            Text("Loading channels...")
                                .font(.caption)
                                .foregroundColor(.secondary)
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
                    Text("Moving \(movingUser.userName() ?? NSLocalizedString("user", comment: "")) — tap a channel")
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
                            .background(Color.primary.opacity(0.18), in: Capsule())
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
                userName: user.userName() ?? NSLocalizedString("User", comment: "")
            )
            .presentationDetents([.medium])
        }
        .sheet(item: $selectedUserForInfo) { user in
            let isSelf = user.session() == MUConnectionController.shared()?.serverModel?.connectedUser()?.session()
            UserInfoView(user: user, isSelf: isSelf, serverManager: serverManager)
        }
        .sheet(item: $selectedUserForStats) { user in
            UserStatsView(user: user, serverManager: serverManager)
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
        .alert("Set Nickname", isPresented: Binding(
            get: { selectedUserForRename != nil },
            set: { if !$0 { selectedUserForRename = nil } }
        )) {
            TextField("Nickname", text: $pendingNicknameInput)
            Button("Cancel", role: .cancel) {
                selectedUserForRename = nil
                pendingNicknameInput = ""
            }
            Button("Reset", role: .destructive) {
                if let user = selectedUserForRename {
                    serverManager.setLocalNickname(nil, for: user)
                }
                selectedUserForRename = nil
                pendingNicknameInput = ""
            }
            Button("Save") {
                if let user = selectedUserForRename {
                    let normalizedNickname = pendingNicknameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    serverManager.setLocalNickname(normalizedNickname.isEmpty ? nil : normalizedNickname, for: user)
                }
                selectedUserForRename = nil
                pendingNicknameInput = ""
            }
        } message: {
            if let user = selectedUserForRename {
                Text("Enter a local nickname for \(user.userName() ?? "this user") (leave blank to reset):")
            }
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
                Text("Enter the password to join \"\(channel.channelName() ?? NSLocalizedString("this channel", comment: ""))\"")
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
    var onUserStatsTap: ((MKUser) -> Void)? = nil
    var onUserRenameTap: ((MKUser) -> Void)? = nil
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

                            if hasChannelEditPermission || canManageChannelFilter {
                                Menu {
                                    if hasChannelEditPermission {
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

                                    if canManageChannelFilter {
                                        if hasChannelEditPermission {
                                            Divider()
                                        }

                                        Button {
                                            serverManager.toggleChannelPinned(channel)
                                        } label: {
                                            Label(
                                                pinToggleTitle,
                                                systemImage: serverManager.isChannelPinned(channel) ? "pin.slash" : "pin"
                                            )
                                        }

                                        if !isRootChannel {
                                            Button {
                                                serverManager.toggleChannelHidden(channel)
                                            } label: {
                                                Label(
                                                    hideToggleTitle,
                                                    systemImage: serverManager.isChannelHidden(channel) ? "eye" : "eye.slash"
                                                )
                                            }
                                        }
                                    }
                                } label: {
                                    Label("Channel Management", systemImage: "slider.horizontal.3")
                                }
                            }

                            if canListenToChannel || hasLinkPermission {
                                Menu {
                                    if canListenToChannel {
                                        if serverManager.listeningChannels.contains(channel.channelId()) {
                                            Button {
                                                serverManager.stopListening(to: channel)
                                            } label: {
                                                Label("Stop Listening", systemImage: "ear.fill")
                                            }
                                        } else {
                                            Button {
                                                serverManager.startListening(to: channel)
                                            } label: {
                                                Label("Listen to Channel", systemImage: "ear")
                                            }
                                        }
                                    }

                                    if hasLinkPermission {
                                        if canListenToChannel {
                                            Divider()
                                        }

                                        if isLinkedToMyChannel {
                                            Button {
                                                unlinkFromMyChannel()
                                            } label: {
                                                Label("Unlink Channel", systemImage: "xmark.circle")
                                            }
                                        } else {
                                            Button {
                                                linkToMyChannel()
                                            } label: {
                                                Label("Link Channel", systemImage: "link.badge.plus")
                                            }
                                        }
                                        if hasLinkedChannels {
                                            Button(role: .destructive) {
                                                serverManager.unlinkAllForChannel(channel)
                                            } label: {
                                                Label("Unlink All", systemImage: "trash")
                                            }
                                        }
                                    }
                                } label: {
                                    Label("Audio & Links", systemImage: "ear.and.waveform")
                                }
                            }
                            
                            Divider()
                            Button {
                                copyChannelURL()
                            } label: {
                                Label("Copy URL", systemImage: "doc.on.doc")
                            }
                        }
                    #else
                    // iOS: 点击弹出菜单
                    Menu {
                        Text(channel.channelName() ?? NSLocalizedString("Channel", comment: ""))
                            .font(.subheadline)
                            .foregroundColor(.primary)
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

                        if hasChannelEditPermission || canManageChannelFilter {
                            Menu {
                                if hasChannelEditPermission {
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

                                if canManageChannelFilter {
                                    if hasChannelEditPermission {
                                        Divider()
                                    }

                                    Button {
                                        serverManager.toggleChannelPinned(channel)
                                    } label: {
                                        Label(
                                            pinToggleTitle,
                                            systemImage: serverManager.isChannelPinned(channel) ? "pin.slash" : "pin"
                                        )
                                    }

                                    if !isRootChannel {
                                        Button {
                                            serverManager.toggleChannelHidden(channel)
                                        } label: {
                                            Label(
                                                hideToggleTitle,
                                                systemImage: serverManager.isChannelHidden(channel) ? "eye" : "eye.slash"
                                            )
                                        }
                                    }
                                }
                            } label: {
                                Label("Channel Management", systemImage: "slider.horizontal.3")
                            }
                        }

                        if canListenToChannel || hasLinkPermission {
                            Menu {
                                if canListenToChannel {
                                    if serverManager.listeningChannels.contains(channel.channelId()) {
                                        Button {
                                            serverManager.stopListening(to: channel)
                                        } label: {
                                            Label("Stop Listening", systemImage: "ear.fill")
                                        }
                                    } else {
                                        Button {
                                            serverManager.startListening(to: channel)
                                        } label: {
                                            Label("Listen to Channel", systemImage: "ear")
                                        }
                                    }
                                }

                                if hasLinkPermission {
                                    if canListenToChannel {
                                        Divider()
                                    }

                                    if isLinkedToMyChannel {
                                        Button {
                                            unlinkFromMyChannel()
                                        } label: {
                                            Label("Unlink Channel", systemImage: "xmark.circle")
                                        }
                                    } else {
                                        Button {
                                            linkToMyChannel()
                                        } label: {
                                            Label("Link Channel", systemImage: "link.badge.plus")
                                        }
                                    }
                                    if hasLinkedChannels {
                                        Button(role: .destructive) {
                                            serverManager.unlinkAllForChannel(channel)
                                        } label: {
                                            Label("Unlink All", systemImage: "trash")
                                        }
                                    }
                                }
                            } label: {
                                Label("Audio & Links", systemImage: "ear.and.waveform")
                            }
                        }
                        
                        Divider()
                        Button {
                            copyChannelURL()
                        } label: {
                            Label("Copy URL", systemImage: "doc.on.doc")
                        }
                    } label: {
                        Color.clear
                    }
                    .frame(maxWidth: .infinity, maxHeight: kContentHeight + kRowPaddingV * 2)
                    .contentShape(Rectangle())
                    #endif
                }
                } // end else (not move mode)
            }
            .onDrag {
                NSItemProvider(object: "channel:\(channel.channelId())" as NSString)
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
                        onPMTap: onUserPMTap,
                        onStatsTap: onUserStatsTap,
                        onRenameTap: onUserRenameTap
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
                        onUserStatsTap: onUserStatsTap,
                        onUserRenameTap: onUserRenameTap,
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

    private var isRootChannel: Bool {
        channel.parent() == nil
    }

    private var canManageChannelFilter: Bool {
        serverManager.serverModel != nil
    }

    private var pinToggleTitle: String {
        let key = serverManager.isChannelPinned(channel) ? "Unpin Channel" : "Pin Channel"
        let zhFallback = serverManager.isChannelPinned(channel) ? "取消置顶频道" : "置顶频道"
        return localizedChannelActionTitle(key: key, zhHansFallback: zhFallback)
    }

    private var hideToggleTitle: String {
        let key = serverManager.isChannelHidden(channel) ? "Unhide Channel" : "Hide Channel"
        let zhFallback = serverManager.isChannelHidden(channel) ? "取消隐藏频道" : "隐藏频道"
        return localizedChannelActionTitle(key: key, zhHansFallback: zhFallback)
    }

    private func localizedChannelActionTitle(key: String, zhHansFallback: String) -> String {
        let localized = NSLocalizedString(key, comment: "")
        if localized != key {
            return localized
        }

        let preferredLanguages = Locale.preferredLanguages
        let isZhHans = preferredLanguages.contains { lang in
            lang.hasPrefix("zh-Hans") || lang.hasPrefix("zh-CN") || lang.hasPrefix("zh")
        }
        return isZhHans ? zhHansFallback : localized
    }
    
    /// 是否可以监听此频道（不是自己当前所在的频道 + 有 Listen 权限）
    private var canListenToChannel: Bool {
        guard let connectedUser = MUConnectionController.shared()?.serverModel?.connectedUser() else {
            return false
        }
        if connectedUser.channel()?.channelId() == channel.channelId() { return false }
        let channelId = channel.channelId()
        if serverManager.hasPermission(MKPermissionListen, forChannelId: channelId) ||
            serverManager.hasRootPermission(MKPermissionListen) {
            return true
        }
        // 权限尚未同步完成时允许显示入口，避免“功能有效但菜单入口消失”
        return serverManager.channelPermissions[channelId] == nil
    }
    
    /// 是否有频道链接权限
    private var hasLinkPermission: Bool {
        let chId = channel.channelId()
        return serverManager.hasPermission(MKPermissionLinkChannel, forChannelId: chId) ||
               serverManager.hasRootPermission(MKPermissionLinkChannel)
    }
    
    /// 当前频道是否已与我所在频道链接
    private var isLinkedToMyChannel: Bool {
        guard let myChannel = MUConnectionController.shared()?.serverModel?.connectedUser()?.channel() else { return false }
        return channel.isLinked(to: myChannel)
    }
    
    /// 频道是否有任何链接
    private var hasLinkedChannels: Bool {
        (channel.linkedChannels() as? [MKChannel])?.isEmpty == false
    }
    
    /// 将当前频道链接到自己所在频道
    private func linkToMyChannel() {
        guard let myChannel = MUConnectionController.shared()?.serverModel?.connectedUser()?.channel() else { return }
        serverManager.linkChannel(myChannel, to: channel)
    }
    
    /// 取消当前频道与自己所在频道的链接
    private func unlinkFromMyChannel() {
        guard let myChannel = MUConnectionController.shared()?.serverModel?.connectedUser()?.channel() else { return }
        serverManager.unlinkChannel(myChannel, from: channel)
    }
    
    /// 复制频道的 mumble:// URL 到剪贴板
    private func copyChannelURL() {
        guard let conn = MUConnectionController.shared()?.connection else { return }
        let host = conn.hostname() ?? "localhost"
        let port = conn.port()
        
        var pathComponents: [String] = []
        var current: MKChannel? = channel
        while let ch = current, ch.parent() != nil {
            if let name = ch.channelName() {
                pathComponents.insert(name, at: 0)
            }
            current = ch.parent()
        }
        let path = pathComponents.map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }.joined(separator: "/")
        
        let urlString: String
        if port == 64738 {
            urlString = "mumble://\(host)/\(path)"
        } else {
            urlString = "mumble://\(host):\(port)/\(path)"
        }
        
        #if os(iOS)
        UIPasteboard.general.string = urlString
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlString, forType: .string)
        #endif
    }
    
    /// 处理拖拽用户/频道到频道的 drop 操作
    private func handleUserDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.canLoadObject(ofClass: NSString.self) {
                provider.loadObject(ofClass: NSString.self) { item, _ in
                    guard let itemString = item as? String else { return }
                    DispatchQueue.main.async {
                        if itemString.hasPrefix("channel:") {
                            let idPart = itemString.dropFirst(8)
                            if let chanId = UInt(idPart),
                               let draggedChan = serverManager.serverModel?.channel(withId: chanId) {
                                serverManager.moveChannel(draggedChan, to: channel)
                            }
                        } else if let session = UInt(itemString) {
                            serverManager.moveUser(session: session, toChannelId: channel.channelId())
                        }
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
                    .foregroundColor(.secondary)
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
                
                Text(channel.channelName() ?? NSLocalizedString("Unknown", comment: ""))
                    .font(.system(size: kFontSize, weight: .medium))
                    .foregroundColor(isCurrentChannel ? .green : .primary)
                    .shadow(
                        color: isCurrentChannel ? .green.opacity(0.35) : .clear,
                        radius: isCurrentChannel ? 1.2 : 0,
                        x: 0,
                        y: 0
                    )
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
                        .background(Color.primary.opacity(0.12), in: Capsule())
                } else if userCount > 0 {
                    Text("\(userCount)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .frame(minHeight: 20)
                        .background(Color.primary.opacity(0.12), in: Capsule())
                }
                
                // 频道限制标记（最右侧）
                if isPinnedChannel {
                    HStack(spacing: 3) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundColor(.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 5)
                    .background(Color.orange.opacity(0.18), in: Circle())
                }
                let linkedCount = (channel.linkedChannels() as? [MKChannel])?.count ?? 0
                if linkedCount > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "link")
                            .font(.system(size: 9, weight: .semibold))
                        Text("\(linkedCount)")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundColor(.cyan)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 5)
                    .background(Color.cyan.opacity(0.18), in: Capsule())
                }
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

    private var isPinnedChannel: Bool {
        serverManager.isChannelPinned(channel)
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
    @ObservedObject var friendsManager = FriendsManager.shared
    @ObservedObject var ignoreManager = IgnoreManager.shared
    @State private var userStateRevision: Int = 0
    
    let onTap: () -> Void
    var onInfoTap: ((MKUser) -> Void)? = nil
    var onPMTap: ((MKUser) -> Void)? = nil
    var onStatsTap: ((MKUser) -> Void)? = nil
    var onRenameTap: ((MKUser) -> Void)? = nil

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
    
    private var isFriend: Bool {
        friendsManager.isFriend(userHash: user.userHash())
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
    
    private var hasKickPermission: Bool {
        let userChannelId = user.channel()?.channelId() ?? 0
        return serverManager.hasPermission(MKPermissionKick, forChannelId: userChannelId) ||
               serverManager.hasRootPermission(MKPermissionKick)
    }
    
    private var hasBanPermission: Bool {
        let userChannelId = user.channel()?.channelId() ?? 0
        return serverManager.hasPermission(MKPermissionBan, forChannelId: userChannelId) ||
               serverManager.hasRootPermission(MKPermissionBan)
    }
    
    var body: some View {
        let _ = userStateRevision
        ZStack(alignment: .leading) {
            HStack(spacing: kHSpacing) {
                let level = dynamicLevel
                let indentWidth = CGFloat(level) * kIndentUnit + kArrowWidth + 4
                // 缩进
                Spacer().frame(width: indentWidth)
                
                // Avatar
                TalkingAvatarView(
                    user: user,
                    avatar: serverManager.avatarImage(for: user.session())
                )
                
                // 用户名
                Text(serverManager.displayName(for: user))
                    .font(.system(size: kFontSize, weight: .medium))
                    .foregroundColor(isMyself ? .cyan : (isFriend ? .green : .primary))
                    .shadow(radius: isMyself || isFriend ? 1 : 0)
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
                                .fill(Color.primary.opacity(0.14))
                                .overlay(
                                    Capsule().stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
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
                    
                    if user.isRecording() {
                        Image(systemName: "record.circle").foregroundColor(.red).font(.caption).transition(.symbolEffect(.appear))
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
                    Button { onStatsTap?(user) } label: { Label("User Statistics", systemImage: "chart.bar") }
                    
                    if !isMyself {
                        Button { onPMTap?(user) } label: { Label("Private Message", systemImage: "envelope.fill") }
                    }

                    Menu {
                        Button { onRenameTap?(user) } label: { Label("Set Nickname", systemImage: "pencil") }

                        if !isMyself, let hash = user.userHash() {
                            Button {
                                friendsManager.toggleFriend(userHash: hash)
                            } label: {
                                if friendsManager.isFriend(userHash: hash) {
                                    Label("Remove Friend", systemImage: "person.badge.minus")
                                } else {
                                    Label("Add Friend", systemImage: "person.badge.plus")
                                }
                            }
                            
                            Button {
                                ignoreManager.toggleIgnore(userHash: hash)
                            } label: {
                                if ignoreManager.isIgnored(userHash: hash) {
                                    Label("Unignore Messages", systemImage: "message")
                                } else {
                                    Label("Ignore Messages", systemImage: "nosign")
                                }
                            }
                        }

                    } label: {
                        Label("Social", systemImage: "person.2")
                    }

                    if !isMyself,
                       (hasMovePermission || hasAdminPermission || hasKickPermission || hasBanPermission) {
                        Menu {
                        if hasMovePermission {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    serverManager.movingUser = user
                                }
                            } label: {
                                Label("Move to...", systemImage: "arrow.right.arrow.left")
                            }
                        }

                        if hasAdminPermission {
                            if hasMovePermission {
                                Divider()
                            }
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
                            Button {
                                serverManager.setPrioritySpeaker(!user.isPrioritySpeaker(), for: user)
                            } label: {
                                if user.isPrioritySpeaker() {
                                    Label("Remove Priority Speaker", systemImage: "star.slash")
                                } else {
                                    Label("Priority Speaker", systemImage: "star.fill")
                                }
                            }
                            Button(role: .destructive) {
                                serverManager.resetUserComment(for: user)
                            } label: {
                                Label("Reset Comment", systemImage: "text.badge.minus")
                            }
                        }

                        if hasKickPermission || hasBanPermission {
                            if hasMovePermission || hasAdminPermission {
                                Divider()
                            }
                        }
                        if hasKickPermission {
                            Button(role: .destructive) {
                                serverManager.kickUser(user)
                            } label: {
                                Label("Kick", systemImage: "xmark.circle")
                            }
                        }
                        if hasBanPermission {
                            Button(role: .destructive) {
                                serverManager.banUser(user)
                            } label: {
                                Label("Ban", systemImage: "nosign")
                            }
                        }

                        } label: {
                            Label("Moderation", systemImage: "shield.lefthalf.filled")
                        }
                    }
                }
            
            #if os(iOS)
            HStack(spacing: 0) {
                let level = dynamicLevel
                Spacer().frame(width: CGFloat(level) * kIndentUnit)
                
                Menu {
                    Text(user.userName() ?? NSLocalizedString("User", comment: ""))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Divider()
                    
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
                    
                    Button {
                        onInfoTap?(user)
                    } label: {
                        Label("User Info", systemImage: "person.circle")
                    }
                    
                    Button {
                        onStatsTap?(user)
                    } label: {
                        Label("User Statistics", systemImage: "chart.bar")
                    }

                    if !isMyself {
                        Button {
                            onPMTap?(user)
                        } label: {
                            Label("Private Message", systemImage: "envelope.fill")
                        }
                    }

                    Menu {
                        Button {
                            onRenameTap?(user)
                        } label: {
                            Label("Set Nickname", systemImage: "pencil")
                        }

                        if !isMyself, let hash = user.userHash() {
                            Button {
                                friendsManager.toggleFriend(userHash: hash)
                            } label: {
                                if friendsManager.isFriend(userHash: hash) {
                                    Label("Remove Friend", systemImage: "person.badge.minus")
                                } else {
                                    Label("Add Friend", systemImage: "person.badge.plus")
                                }
                            }

                            Button {
                                ignoreManager.toggleIgnore(userHash: hash)
                            } label: {
                                if ignoreManager.isIgnored(userHash: hash) {
                                    Label("Unignore Messages", systemImage: "message")
                                } else {
                                    Label("Ignore Messages", systemImage: "nosign")
                                }
                            }
                        }
                    } label: {
                        Label("Social", systemImage: "person.2")
                    }

                    if !isMyself,
                       (hasMovePermission || hasAdminPermission || hasKickPermission || hasBanPermission) {
                        Menu {
                        
                        if hasMovePermission {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    serverManager.movingUser = user
                                }
                            } label: {
                                Label("Move to...", systemImage: "arrow.right.arrow.left")
                            }
                        }
                        
                        if hasAdminPermission {
                            if hasMovePermission {
                                Divider()
                            }
                            
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
                            Button {
                                serverManager.setPrioritySpeaker(!user.isPrioritySpeaker(), for: user)
                            } label: {
                                if user.isPrioritySpeaker() {
                                    Label("Remove Priority Speaker", systemImage: "star.slash")
                                } else {
                                    Label("Priority Speaker", systemImage: "star.fill")
                                }
                            }
                            Button(role: .destructive) {
                                serverManager.resetUserComment(for: user)
                            } label: {
                                Label("Reset Comment", systemImage: "text.badge.minus")
                            }
                        }

                        if hasKickPermission || hasBanPermission {
                            if hasMovePermission || hasAdminPermission {
                                Divider()
                            }
                        }
                        if hasKickPermission {
                            Button(role: .destructive) {
                                serverManager.kickUser(user)
                            } label: {
                                Label("Kick", systemImage: "xmark.circle")
                            }
                        }
                        if hasBanPermission {
                            Button(role: .destructive) {
                                serverManager.banUser(user)
                            } label: {
                                Label("Ban", systemImage: "nosign")
                            }
                        }

                        } label: {
                            Label("Moderation", systemImage: "shield.lefthalf.filled")
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
        .onReceive(NotificationCenter.default.publisher(for: ServerModelNotificationManager.userStateUpdatedNotification)) { notification in
            guard let userInfo = notification.userInfo,
                  let changedSession = userInfo["userSession"] as? UInt,
                  changedSession == user.session() else { return }
            userStateRevision &+= 1
        }
    }
    
    private var isMyself: Bool {
        return user == MUConnectionController.shared()?.serverModel?.connectedUser()
    }
    
}

// MARK: - 6. Helper Components

private struct TalkingAvatarView: View {
    let user: MKUser
    let avatar: PlatformImage?
    @State private var talkStateRawValue: UInt32
    private var avatarDiameter: CGFloat { kIconSize + 2 }

    init(user: MKUser, avatar: PlatformImage?) {
        self.user = user
        self.avatar = avatar
        _talkStateRawValue = State(initialValue: user.talkState().rawValue)
    }

    var body: some View {
        Group {
            if let avatar {
                Image(platformImage: avatar)
                    .resizable()
                    .scaledToFill()
                    .frame(width: avatarDiameter, height: avatarDiameter)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(isTalking ? Color.green.opacity(0.95) : .clear, lineWidth: 2)
                    )
                    .shadow(color: isTalking ? Color.green.opacity(0.78) : .clear, radius: isTalking ? 6 : 0)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: kIconSize))
                    .foregroundColor(isTalking ? .green : .gray)
                    .shadow(color: isTalking ? Color.green.opacity(0.78) : .clear, radius: isTalking ? 6 : 0)
            }
        }
            .frame(width: kContentHeight, height: kContentHeight, alignment: .center)
            .animation(.easeInOut(duration: 0.18), value: isTalking)
            .onReceive(NotificationCenter.default.publisher(for: ServerModelNotificationManager.userTalkStateChangedNotification)) { notification in
                guard let userInfo = notification.userInfo,
                      let changedSession = userInfo["userSession"] as? UInt,
                      changedSession == user.session(),
                      let talkState = userInfo["talkState"] as? MKTalkState else { return }
                let newRaw = talkState.rawValue
                if newRaw != talkStateRawValue {
                    talkStateRawValue = newRaw
                }
            }
    }

    private var isTalking: Bool {
        switch talkStateRawValue {
        case 1, 2, 3:
            return true
        default:
            return false
        }
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
                .fill(isHovering ? Color.primary.opacity(0.35) : Color.primary.opacity(0.12))
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

private struct PendingPrivateImage: Identifiable {
    let id = UUID()
    let image: PlatformImage
}

struct PrivateMessageInputView: View {
    let targetUser: MKUser
    @ObservedObject var serverManager: ServerModelManager
    
    @State private var messageText: String = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var pendingPrivateImage: PendingPrivateImage?
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
                        Text("To: \(targetUser.userName() ?? NSLocalizedString("Unknown", comment: ""))")
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
                    .background(Color.secondarySystemBackground, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                    )
                    .padding(.horizontal)

                HStack {
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label("Send Image", systemImage: "photo.on.rectangle.angled")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
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
            .onChange(of: selectedPhoto) { _, item in
                Task {
                    guard let item,
                          let data = try? await item.loadTransferable(type: Data.self),
                          let image = PlatformImage(data: data) else {
                        await MainActor.run { selectedPhoto = nil }
                        return
                    }
                    await MainActor.run {
                        pendingPrivateImage = PendingPrivateImage(image: image)
                        selectedPhoto = nil
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 250)
        #endif
        .sheet(item: $pendingPrivateImage) { pending in
            ImageConfirmationView(
                image: pending.image,
                onCancel: { pendingPrivateImage = nil },
                onSend: { image in
                    await serverManager.sendPrivateImageMessage(image: image, to: targetUser)
                    await MainActor.run {
                        pendingPrivateImage = nil
                        dismiss()
                    }
                }
            )
            .presentationDetents([.medium, .large])
        }
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
    @State private var hasSpeaker: Bool = false
    
    private var isMyself: Bool {
        return listener == MUConnectionController.shared()?.serverModel?.connectedUser()
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
            Text(listener.userName() ?? NSLocalizedString("Unknown", comment: ""))
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
        .onAppear {
            refreshSpeakerState()
        }
        .onReceive(NotificationCenter.default.publisher(for: ServerModelNotificationManager.userTalkStateChangedNotification)) { _ in
            refreshSpeakerState()
        }
        .onReceive(NotificationCenter.default.publisher(for: ServerModelNotificationManager.userMovedNotification)) { _ in
            refreshSpeakerState()
        }
        .onReceive(NotificationCenter.default.publisher(for: ServerModelNotificationManager.userJoinedNotification)) { _ in
            refreshSpeakerState()
        }
        .onReceive(NotificationCenter.default.publisher(for: ServerModelNotificationManager.userLeftNotification)) { _ in
            refreshSpeakerState()
        }
    }

    private func refreshSpeakerState() {
        let newValue = serverManager.getSortedUsers(for: channel).contains { user in
            switch user.talkState().rawValue {
            case 1, 2, 3:
                return true
            default:
                return false
            }
        }
        if newValue != hasSpeaker {
            hasSpeaker = newValue
        }
    }
}
