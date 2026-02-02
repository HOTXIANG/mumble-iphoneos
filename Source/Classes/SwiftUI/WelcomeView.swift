//
//  WelcomeView.swift
//  Mumble
//
//  Created by 王梓田 on 2025/6/27.
//

import SwiftUI
import UIKit

// MARK: - Navigation Configurations

struct WelcomeNavigationConfig: NavigationConfigurable {
    let onPreferences: () -> Void
    let onAbout: () -> Void
    
    var title: String { "Mumble" }
    var leftBarItems: [NavigationBarItem] {
        [NavigationBarItem(systemImage: "gearshape", action: onPreferences)]
    }
    var rightBarItems: [NavigationBarItem] {
        []
    }
}

// MARK: - Welcome Content View

struct WelcomeContentView: View {
    @EnvironmentObject var navigationManager: NavigationManager
    @StateObject private var lanModel = LanDiscoveryModel()
    @ObservedObject private var recentManager = RecentServerManager.shared
    
    @State private var favouriteServers: [MUFavouriteServer] = []
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部 Logo 区域
            WelcomeHeaderView()
                .padding(.top, 10)
                .padding(.bottom, 20)
            
            VStack(spacing: 0) {
                
                Button(action: {
                    navigationManager.navigate(to: .swiftUI(.favouriteServerList))
                }) {
                    HStack(spacing: 16) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.yellow)
                            .frame(width: 30)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Favourite Servers")
                                .font(.headline)
                                .foregroundColor(.white)
                            Text("Manage your saved servers")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.indigo)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .contentShape(Rectangle()) // 修复点击热区问题
                    .glassEffect(.clear.interactive(), in: .rect(cornerRadius: 27))
                }
                .padding(.horizontal, 20)
                .buttonStyle(.plain)
            }
            .padding(.bottom, 20)
            
            List {
                // --- 最近访问 ---
                if !recentManager.recents.isEmpty {
                    Section(header: Text("Recent Connections")) {
                        ForEach(recentManager.recents) { server in
                            ServerListRow(
                                title: server.displayName,
                                subtitle: "\(server.username) @ \(server.hostname):\(server.port)",
                                icon: "clock.fill",
                                iconColor: .blue
                            ) {
                                connectTo(hostname: server.hostname, port: server.port, username: server.username, displayName: server.displayName)
                            }
                        }
                        .onDelete { indexSet in
                            recentManager.recents.remove(atOffsets: indexSet)
                        }
                    }
                    .listRowBackground(Rectangle().fill(.regularMaterial.opacity(0.6)))
                } else if lanModel.servers.isEmpty {
                    // 如果既没有最近记录，也没有 LAN 服务器，显示一个占位提示
                    Section {
                        Text("No recent connections.")
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .foregroundColor(.secondary)
                            .listRowBackground(Color.clear)
                    }
                }
                
                // --- LAN ---
                if !lanModel.servers.isEmpty {
                    Section(header: Text("Local Network")) {
                        ForEach(lanModel.servers) { server in
                            ServerListRow(
                                title: server.name,
                                subtitle: "\(server.hostname):\(server.port)",
                                icon: "network",
                                iconColor: .green
                            ) {
                                let defaultUser = UserDefaults.standard.string(forKey: "DefaultUserName") ?? "MumbleUser"
                                connectTo(hostname: server.hostname, port: server.port, username: defaultUser, displayName: server.name)
                            }
                        }
                    }
                    .listRowBackground(Rectangle().fill(.regularMaterial))
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.insetGrouped)
        }
        .background(Color.clear)
        .onAppear {
            lanModel.start()
        }
        .onDisappear {
            lanModel.stop()
        }
    }
    
    private func connectTo(hostname: String, port: Int, username: String, displayName: String) {
        // 触发连接
        AppState.shared.serverDisplayName = hostname
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        
        // 尝试从收藏夹查找匹配的证书
        var certRef: Data? = nil
        let allFavs = MUDatabase.fetchAllFavourites() as? [MUFavouriteServer] ?? []
        if let match = allFavs.first(where: { $0.hostName == hostname && $0.port == UInt(port) && $0.userName == username }) {
            certRef = match.certificateRef
        }
        
        MUConnectionController.shared()?.connet(
            toHostname: hostname,
            port: UInt(port),
            withUsername: username,
            andPassword: "",
            certificateRef: certRef,
            displayName: displayName
        )
    }
}

struct ServerListRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let iconColor: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(iconColor)
                    .frame(width: 24)
                    .font(.system(size: 18))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }
}

struct WelcomeView: MumbleContentView {
    @State private var showingPreferences = false
    @State private var showingAbout = false
    @EnvironmentObject var navigationManager: NavigationManager
    @EnvironmentObject var serverManager: ServerModelManager
    
    var navigationConfig: any NavigationConfigurable {
        WelcomeNavigationConfig(
            onPreferences: { showingPreferences = true },
            onAbout: { showingAbout = true }
        )
    }
    
    var contentBody: some View {
        WelcomeContentView()
            .sheet(isPresented: $showingPreferences, onDismiss: {
                serverManager.stopAudioTest()
            }) {
                NavigationStack {
                    PreferencesView()
                        .environmentObject(serverManager)
                }
            }
    }
}

struct MumbleNavigationModifier: ViewModifier {
    let config: NavigationConfigurable
    
    func body(content: Content) -> some View {
        content
            .navigationTitle(config.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    ForEach(Array(config.leftBarItems.enumerated()), id: \.offset) { _, item in
                        createBarButton(item)
                    }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    ForEach(Array(config.rightBarItems.enumerated()), id: \.offset) { _, item in
                        createBarButton(item)
                    }
                }
            }
    }
    
    @ViewBuilder
    private func createBarButton(_ item: NavigationBarItem) -> some View {
        Button(action: item.action) {
            if let title = item.title {
                Text(NSLocalizedString(title, comment: ""))
            } else if let systemImage = item.systemImage {
                Image(systemName: systemImage)
            }
        }
        .foregroundStyle(.primary)
    }
}

// MARK: - App Root View (Split View & Stack Logic)

struct AppRootView: View {
    @ObservedObject private var appState = AppState.shared
    
    @StateObject private var serverManager = ServerModelManager()
    
    // iPhone 使用的单一导航管理器
    @StateObject private var navigationManager = NavigationManager()
    
    // iPad 使用的侧边栏导航管理器 (让 Detail 独立变化)
    @StateObject private var sidebarNavigationManager = NavigationManager()
 
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
    
    var body: some View {
        // 内容区域
        Group {
            if UIDevice.current.userInterfaceIdiom == .pad {
                iPadLayout
            } else {
                iPhoneLayout
            }
        }
        .environmentObject(serverManager)
        // --- 全局覆盖层 (Toast, PTT, Connect Loading) ---
        .overlay(alignment: .top) {
            if let toast = appState.activeToast {
                ToastView(toast: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(2000)
                    .onTapGesture { withAnimation { appState.activeToast = nil } }
            }
        }
        .overlay(alignment: .bottom) {
            // 连接成功后显示 PTT 按钮
            if appState.isConnected {
                PTTButton()
                    .padding(.bottom, 20)
            }
        }
        .overlay {
            if appState.isConnecting {
                ZStack {
                    Color.black.opacity(0.6).ignoresSafeArea().onTapGesture { }
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large).tint(.white)
                        Text(appState.isReconnecting ? "Reconnecting..." : "Connecting...")
                            .font(.headline).foregroundColor(.white)
                        Button(action: { appState.cancelConnection() }) {
                            Text("Cancel")
                                .font(.subheadline).fontWeight(.semibold).foregroundColor(.white)
                                .padding(.horizontal, 32).padding(.vertical, 10)
                                .glassEffect(.regular.tint(.red.opacity(0.5)).interactive(), in: Capsule())
                        }
                    }
                    .padding(.horizontal, 64).padding(.vertical, 24)
                    .glassEffect(.regular.interactive(),in: .rect(cornerRadius: 32))
                    .shadow(radius: 10)
                }
                .ignoresSafeArea().zIndex(9999)
                .transition(.opacity.animation(.easeInOut(duration: 0.3)))
            }
        }
        .alert(item: $appState.activeError) { error in
            Alert(title: Text(error.title), message: Text(error.message), dismissButton: .default(Text("OK")))
        }
        .onAppear {
            serverManager.activate()
        }
        .animation(.default, value: appState.isConnecting)
        .animation(.spring(), value: appState.isConnected)
    }
    
    // MARK: - iPad Split View Layout
    
    var iPadLayout: some View {
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            // 左侧 Sidebar：使用独立的 sidebarNavigationManager
            NavigationStack(path: $sidebarNavigationManager.navigationPath) {
                WelcomeView()
                    .navigationDestination(for: NavigationDestination.self) { destination in
                        destinationView(for: destination, navigationManager: sidebarNavigationManager)
                            .environmentObject(sidebarNavigationManager)
                    }
                    .background(Color.clear)
            }
            .environmentObject(sidebarNavigationManager)
            .navigationSplitViewColumnWidth(min: 320, ideal: 380)
            .background(Color.clear)
        } detail: {
            ZStack {
                if appState.isConnected {
                    NavigationStack {
                        ChannelListView()
                            .environmentObject(NavigationManager())
                    }
                } else {
                    ContentUnavailableView {
                        Label("No Server Connected", systemImage: "server.rack")
                    } description: {
                        Text("Select a server from the sidebar to start chatting.")
                    }
                }
            }
            .background(Color.clear) // Detail 区域透明
        }
        .onChange(of: appState.isConnected) { isConnected in
            // 如果连接成功，在窄屏模式下优先显示 Detail (频道页)
            // 如果断开连接，优先显示 Sidebar (欢迎页)
            preferredCompactColumn = isConnected ? .detail : .sidebar
        }
        .onAppear {
            // 初始化检查：如果启动时已经连接，确保显示 Detail
            if appState.isConnected {
                preferredCompactColumn = .detail
            }
        }
        .navigationSplitViewStyle(.balanced)
        .background(Color.clear)
        .preferredColorScheme(.dark)
    }
    
    // MARK: - iPhone Stack Layout
    
    var iPhoneLayout: some View {
        NavigationStack(path: $navigationManager.navigationPath) {
            WelcomeView()
                .navigationDestination(for: NavigationDestination.self) { destination in
                    destinationView(for: destination, navigationManager: navigationManager)
                        .environmentObject(navigationManager)
                }
        }
        .environmentObject(navigationManager)
        .preferredColorScheme(.dark)
        .background(Color.clear)
        // iPhone 需要手动监听连接状态来 Push 界面
        .onChange(of: appState.isConnected) { isConnected in
            if isConnected {
                navigationManager.navigate(to: .swiftUI(.channelList))
            } else {
                navigationManager.goToRoot()
            }
        }
    }
    
    // MARK: - Helper
    
    @ViewBuilder
    private func destinationView(for destination: NavigationDestination, navigationManager: NavigationManager) -> some View {
        switch destination {
        case .objectiveC(let type):
            ObjectiveCViewWrapper(controllerType: type)
        case .swiftUI(let type):
            switch type {
            case .favouriteServerList:
                FavouriteServerListView()
            case .favouriteServerEdit(let primaryKey):
                let server: MUFavouriteServer? = {
                    guard let key = primaryKey else { return nil }
                    if let allFavourites = MUDatabase.fetchAllFavourites() as? [MUFavouriteServer] {
                        return allFavourites.first { $0.primaryKey == key }
                    }
                    return nil
                }()
                FavouriteServerEditView(server: server) { serverToSave in
                    MUDatabase.storeFavourite(serverToSave)
                    navigationManager.goBack()
                }
            case .channelList:
                ChannelListView()
            }
        }
    }
}
