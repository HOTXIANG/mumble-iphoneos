// 文件: ChannelListView.swift (已更新“更多”选项样式)

import SwiftUI

struct ChannelListView: View {
    @StateObject private var serverManager = ServerModelManager()
    @ObservedObject var appState = AppState.shared
    @State private var showingPrefs = false
    @State private var showingCertInfo = false
    
    // --- 核心修改 1：注入 NavigationManager ---
    @EnvironmentObject var navigationManager: NavigationManager
        
    // --- 核心修改 2：创建一个触感反馈生成器 ---
    private let hapticGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let notificationHaptic = UINotificationFeedbackGenerator()

    var body: some View {
        ZStack {
            // 背景由 ChannelView 内部提供
            ChannelView(serverManager: serverManager)
            
            if appState.isRegistering {
                ZStack {
                    // 半透明背景，遮住底下的列表可能变空的过程
                    Color.black.opacity(0.6)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                        
                        VStack(spacing: 8) {
                            Text("Registering...")
                                .font(.headline)
                                .foregroundColor(.white)
                            Text("Generating certificate and reconnecting")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                    .padding(.horizontal, 48).padding(.vertical, 32)
                    .glassEffect(.regular.interactive(),in: .rect(cornerRadius: 32))
                    .shadow(radius: 10)
                }
                .transition(.opacity)
                .zIndex(9999) // 确保在最上层
            }
        }
        .navigationBarBackButtonHidden(true)
        // 注意：这里 serverName 可能是可选的，提供默认值
        .navigationTitle(Text(serverManager.serverName ?? "Channel"))
        .navigationBarTitleDisplayMode(.inline)
        // 隐藏系统默认背景，使用自定义渐变
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            leadingToolbarItems
            trailingToolbarItems
        }
        .sheet(isPresented: $showingPrefs) {
            NavigationStack {
                PreferencesView()
            }
        }
        .sheet(isPresented: $showingCertInfo) {
            ServerCertificateDetailView()
        }
    }
    
    // MARK: - Extracted Toolbar Views
    
    // 左侧工具栏：静音/耳聋按钮
    @ToolbarContentBuilder
    private var leadingToolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarLeading) {
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
                            .foregroundColor(serverManager.connectedUserState?.isSelfMuted == true ? .orange : .primary)
                    }
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
                }
            }
            .tint(.primary)
        }
    }
    
    // 右侧工具栏：菜单和断开连接
    @ToolbarContentBuilder
    private var trailingToolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            HStack(alignment: .center, spacing: 16) {
                // 菜单按钮
                Menu {
                    menuContent
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                
                // 断开连接按钮
                Button(action: {
                    hapticGenerator.impactOccurred()
                    initiateDisconnect()
                }) {
                    Image(systemName: "phone.down.fill")
                        .foregroundColor(.red)
                }
            }
            .tint(.primary)
            .padding(.horizontal, 8)
        }
    }
    
    // 菜单内容 (进一步提取以降低复杂度)
    @ViewBuilder
    private var menuContent: some View {
        // --- 核心互斥逻辑 ---
        if let currentUser = serverManager.connectedUserState {
            // 这里假设 isAuthenticated 是属性(Boolean)，如果是方法请改为 isAuthenticated()
            // 根据 MumbleKit 通常习惯，OC boolean property 映射为 Swift 属性
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
            // 如果 userState 还没准备好，默认显示注册或者什么都不显示
            Button(action: { serverManager.registerSelf() }) {
                Label("Register User", systemImage: "person.badge.plus")
            }
        }
        
        Divider()
        
        Button(action: { showingPrefs = true }) {
            Label("Settings", systemImage: "gearshape")
        }
    }

    // MARK: - Logic
    
    @State private var disconnectObserver: Any?
    
    private func initiateDisconnect() {
        guard disconnectObserver == nil else { print("🟡 Disconnect sequence already in progress."); return }
        notificationHaptic.prepare()
        notificationHaptic.notificationOccurred(.warning)
        print("🟡 Initiating disconnect sequence...")
        disconnectObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name("MUConnectionClosedNotification"), object: nil, queue: .main) { [self] _ in
            Task { @MainActor in
                print("✅ Disconnection confirmed by notification.")
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
