// 文件: ChannelListView.swift (已更新“更多”选项样式)

import SwiftUI

struct ChannelListView: View {
    @EnvironmentObject var serverManager: ServerModelManager
    @ObservedObject var appState = AppState.shared
    @Environment(\.colorScheme) private var colorScheme
    #if os(iOS)
    @State private var showingPrefs = false
    #endif
    @State private var showingCertInfo = false
    @State private var showingBanList = false
    @State private var showingUserList = false
    @State private var showingTokens = false
    @State private var channelSearchText = ""
    
    #if os(macOS)
    // macOS: 监听菜单栏通知
    private let showCertInfoPublisher = NotificationCenter.default.publisher(for: .mumbleShowCertInfo)
    private let disconnectPublisher = NotificationCenter.default.publisher(for: .mumbleInitiateDisconnect)
    private let registerUserPublisher = NotificationCenter.default.publisher(for: .mumbleRegisterUser)
    private let toggleMutePublisher = NotificationCenter.default.publisher(for: .mumbleToggleMute)
    private let toggleDeafenPublisher = NotificationCenter.default.publisher(for: .mumbleToggleDeafen)
    private let showAccessTokensPublisher = NotificationCenter.default.publisher(for: .mumbleShowAccessTokens)
    private let showBanListPublisher = NotificationCenter.default.publisher(for: .mumbleShowBanList)
    private let showRegisteredUsersPublisher = NotificationCenter.default.publisher(for: .mumbleShowRegisteredUsers)
    #endif
    
    // --- 核心修改 1：注入 NavigationManager ---
    @EnvironmentObject var navigationManager: NavigationManager
        
    // --- 核心修改 2：创建一个触感反馈生成器 ---
    private let hapticGenerator = PlatformImpactFeedback(style: .medium)
    private let notificationHaptic = PlatformNotificationFeedback()

    var body: some View {
        ZStack {
            // 背景由 ChannelView 内部提供
            ChannelView(serverManager: serverManager)
            
            if appState.isRegistering {
                ZStack {
                    // 半透明背景，遮住底下的列表可能变空的过程
                    Color.black.opacity(colorScheme == .dark ? 0.58 : 0.28)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.accentColor)
                        
                        VStack(spacing: 8) {
                            Text("Registering...")
                                .font(.headline)
                                .foregroundColor(.primary)
                            Text("Generating certificate and reconnecting")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 48).padding(.vertical, 32)
                    .modifier(GlassEffectModifier(cornerRadius: 32))
                    .shadow(radius: 10)
                }
                .transition(.opacity)
                .zIndex(9999) // 确保在最上层
            }
        }
        .navigationBarBackButtonHidden(true)
        // 注意：这里 serverName 可能是可选的，提供默认值
        .navigationTitle(Text(serverManager.serverName ?? NSLocalizedString("Channel", comment: "")))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        // 隐藏系统默认背景，使用自定义渐变
        .toolbarBackground(.hidden, for: .navigationBar)
        #else
        .toolbarTitleDisplayMode(.inline)
        .toolbarBackground(.clear, for: .windowToolbar)
        .toolbarBackground(.hidden, for: .windowToolbar)
        #endif
        #if os(iOS)
        // iPad 上不显示搜索框，避免占用服务器界面空间
        .modifier(ChannelSearchModifier(searchText: $channelSearchText))
        #endif
        .toolbar {
            leadingToolbarItems
            trailingToolbarItems
        }
        #if os(iOS)
        .sheet(isPresented: $showingPrefs) {
            NavigationStack {
                PreferencesView()
                    .environmentObject(serverManager)
            }
        }
        #endif
        .sheet(isPresented: $showingCertInfo) {
            ServerCertificateDetailView()
        }
        .sheet(isPresented: $showingBanList) {
            BanListView(serverManager: serverManager)
        }
        .sheet(isPresented: $showingUserList) {
            RegisteredUserListView(serverManager: serverManager)
        }
        .sheet(isPresented: $showingTokens) {
            AccessTokensView(serverManager: serverManager)
        }
        #if os(macOS)
        .onReceive(showCertInfoPublisher) { _ in showingCertInfo = true }
        .onReceive(disconnectPublisher) { _ in initiateDisconnect() }
        .onReceive(registerUserPublisher) { _ in
            guard appState.isConnected else { return }
            serverManager.registerSelf()
        }
        .onReceive(toggleMutePublisher) { _ in
            guard appState.isConnected else { return }
            serverManager.toggleSelfMute()
        }
        .onReceive(toggleDeafenPublisher) { _ in
            guard appState.isConnected else { return }
            serverManager.toggleSelfDeafen()
        }
        .onReceive(showAccessTokensPublisher) { _ in
            guard appState.isConnected else { return }
            showingTokens = true
        }
        .onReceive(showBanListPublisher) { _ in
            guard appState.isConnected else { return }
            guard serverManager.hasRootPermission(MKPermissionBan) else { return }
            showingBanList = true
        }
        .onReceive(showRegisteredUsersPublisher) { _ in
            guard appState.isConnected else { return }
            guard serverManager.hasRootPermission(MKPermissionRegister) else { return }
            showingUserList = true
        }
        #endif
    }
    
    // MARK: - Extracted Toolbar Views
    
    // 左侧工具栏：静音/耳聋按钮
    @ToolbarContentBuilder
    private var leadingToolbarItems: some ToolbarContent {
        #if os(iOS)
        ToolbarItemGroup(placement: .navigationBarLeading) {
            leadingButtonsContent
        }
        #else
        // macOS: 不需要左侧按钮，所有控件在右侧或菜单栏
        ToolbarItem(placement: .navigation) {
            EmptyView()
        }
        #endif
    }
    
    @ViewBuilder
    private var leadingButtonsContent: some View {
        HStack(alignment: .center, spacing: 0) {
            Button(action: {
                hapticGenerator.impactOccurred()
                serverManager.toggleSelfDeafen()
            }) {
                ZStack {
                    // 使用可选链安全访问 connectedUserState
                    Image(systemName: serverManager.connectedUserState?.isSelfDeafened == true ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 24, height: 24)
                        .foregroundColor(serverManager.connectedUserState?.isSelfDeafened == true ? .red : .primary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
            }
            
            Button(action: {
                hapticGenerator.impactOccurred()
                serverManager.toggleSelfMute()
            }) {
                ZStack {
                    Image(systemName: serverManager.connectedUserState?.isSelfMuted == true ? "mic.slash.fill" : "mic.fill")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 24, height: 24)
                        .foregroundColor(serverManager.connectedUserState?.isSelfDeafened == true ? .red : (serverManager.connectedUserState?.isSelfMuted == true ? .orange : .primary))
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
            }
        }
        .tint(.primary)
    }
    
    // 右侧工具栏：菜单和断开连接
    @ToolbarContentBuilder
    private var trailingToolbarItems: some ToolbarContent {
        #if os(iOS)
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            trailingButtonsContent
        }
        #else
        ToolbarItemGroup(placement: .primaryAction) {
            trailingButtonsContent
        }
        #endif
    }
    
    @ViewBuilder
    private var trailingButtonsContent: some View {
        HStack(alignment: .center, spacing: 16) {
            #if os(iOS)
            // iOS: 三个点菜单（包含注册/证书/设置）
            Menu {
                menuContent
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            #else
            // macOS: 不听+闭麦放在右上角（无三个点菜单）
            Button(action: {
                hapticGenerator.impactOccurred()
                serverManager.toggleSelfDeafen()
            }) {
                Image(systemName: serverManager.connectedUserState?.isSelfDeafened == true ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 18))
                    .foregroundColor(serverManager.connectedUserState?.isSelfDeafened == true ? .red : .primary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            
            Button(action: {
                hapticGenerator.impactOccurred()
                serverManager.toggleSelfMute()
            }) {
                Image(systemName: serverManager.connectedUserState?.isSelfMuted == true ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 18))
                    .foregroundColor(serverManager.connectedUserState?.isSelfDeafened == true ? .red : (serverManager.connectedUserState?.isSelfMuted == true ? .orange : .primary))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            #endif
            
            // 断开连接按钮（两个平台都有）
            Button(action: {
                hapticGenerator.impactOccurred()
                initiateDisconnect()
            }) {
                Image(systemName: "phone.down.fill")
                    .foregroundColor(.red)
                    #if os(macOS)
                    .font(.system(size: 18))
                    .frame(width: 28, height: 28)
                    #endif
            }
            #if os(macOS)
            .buttonStyle(.borderless)
            #endif
        }
        .tint(.primary)
        .padding(.horizontal, 8)
    }
    
    // 菜单内容 (进一步提取以降低复杂度)
    @ViewBuilder
    private var menuContent: some View {
        // --- 核心互斥逻辑 ---
        if let currentUser = serverManager.connectedUserState {
            if currentUser.isAuthenticated {
                Button(action: { showingCertInfo = true }) {
                    Label("View Certificate", systemImage: "lock.doc")
                }
            } else {
                Button(action: { serverManager.registerSelf() }) {
                    Label("Register User", systemImage: "person.badge.plus")
                }
            }
        } else {
            Button(action: { serverManager.registerSelf() }) {
                Label("Register User", systemImage: "person.badge.plus")
            }
        }
        
        Divider()
        
        Button(action: { showingTokens = true }) {
            Label("Access Tokens", systemImage: "key")
        }
        
        if serverManager.hasRootPermission(MKPermissionBan) {
            Button(action: { showingBanList = true }) {
                Label("Ban List", systemImage: "nosign")
            }
        }
        
        if serverManager.hasRootPermission(MKPermissionRegister) {
            Button(action: { showingUserList = true }) {
                Label("Registered Users", systemImage: "person.2")
            }
        }
        
        #if os(iOS)
        Divider()
        
        Button(action: { showingPrefs = true }) {
            Label("Settings", systemImage: "gearshape")
        }
        #endif
    }

    // MARK: - Logic
    
    @State private var disconnectObserver: Any?
    
    private func initiateDisconnect() {
        guard disconnectObserver == nil else { MumbleLogger.connection.debug("Disconnect sequence already in progress"); return }
        notificationHaptic.prepare()
        notificationHaptic.notificationOccurred(.warning)
        MumbleLogger.connection.info("Initiating disconnect sequence")
        disconnectObserver = NotificationCenter.default.addObserver(forName: .muConnectionClosed, object: nil, queue: .main) { [self] _ in
            Task { @MainActor in
                MumbleLogger.connection.info("Disconnection confirmed by notification")
                withAnimation(.spring()) { AppState.shared.isConnected = false }
                if let observer = self.disconnectObserver { NotificationCenter.default.removeObserver(observer); self.disconnectObserver = nil }
            }
        }
        MUConnectionController.shared()?.disconnectFromServer()
    }
    private func registerUserOnServer() {
        // 调用 serverManager 的注册逻辑
        serverManager.registerSelf()
    }
}

// MARK: - iPad 上隐藏搜索框

#if os(iOS)
private struct ChannelSearchModifier: ViewModifier {
    @Binding var searchText: String
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        if sizeClass == .compact {
            content.searchable(text: $searchText, prompt: "Search channels and users")
        } else {
            content
        }
    }
}
#endif
