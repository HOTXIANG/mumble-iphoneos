//
//  WelcomeView.swift
//  Mumble
//
//  Created by 王梓田 on 2025/6/27.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Navigation Configurations

struct WelcomeNavigationConfig: NavigationConfigurable {
    let onPreferences: () -> Void
    let onAbout: () -> Void
    
    var title: String { "Mumble" }
    var leftBarItems: [NavigationBarItem] {
        #if os(macOS)
        [] // macOS: Settings is in the app menu bar
        #else
        [NavigationBarItem(systemImage: "gearshape", action: onPreferences)]
        #endif
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
    @State private var showFavouritesSheet = false
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部 Logo 区域
            WelcomeHeaderView()
                #if os(macOS)
                .padding(.top, 4)
                .padding(.bottom, 8)
                #else
                .padding(.top, 10)
                .padding(.bottom, 20)
                #endif
            
            VStack(spacing: 0) {
                
                Button(action: {
                    #if os(iOS)
                    if UIDevice.current.userInterfaceIdiom == .phone {
                        navigationManager.navigate(to: .swiftUI(.favouriteServerList))
                    } else {
                        showFavouritesSheet = true
                    }
                    #else
                    showFavouritesSheet = true
                    #endif
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
                    .modifier(GlassEffectModifier(cornerRadius: 27))
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
                            #if os(macOS)
                            .contextMenu {
                                Button(role: .destructive) {
                                    deleteRecentConnection(hostname: server.hostname, port: server.port, username: server.username)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            #endif
                        }
                        #if os(iOS)
                        .onDelete { indexSet in
                            recentManager.recents.remove(atOffsets: indexSet)
                        }
                        #endif
                    }
                    #if os(macOS)
                    .listRowBackground(Color.clear)
                    #else
                    .listRowBackground(Rectangle().fill(.regularMaterial.opacity(0.6))).listRowBackground(Rectangle().fill(.regularMaterial.opacity(0.6)))
                    #endif
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
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
        }
        .background(Color.clear)
        .onAppear {
            lanModel.start()
        }
        .onDisappear {
            lanModel.stop()
        }
        .sheet(isPresented: $showFavouritesSheet) {
            NavigationStack {
                FavouriteServerListView(isModalPresentation: true)
                    .environmentObject(navigationManager)
            }
            #if os(macOS)
            .frame(minWidth: 500, idealWidth: 600, minHeight: 450, idealHeight: 550)
            #elseif os(iOS)
            .presentationDetents([.large])
            #endif
        }
    }
    
    private func connectTo(hostname: String, port: Int, username: String, displayName: String) {
        // 触发连接
        AppState.shared.serverDisplayName = hostname
        PlatformImpactFeedback(style: .medium).impactOccurred()
        
        // 尝试从收藏夹查找匹配的证书和密码
        var certRef: Data? = nil
        var password: String = ""
        let allFavs = MUDatabase.fetchAllFavourites() as? [MUFavouriteServer] ?? []
        if let match = allFavs.first(where: { $0.hostName == hostname && $0.port == UInt(port) && $0.userName == username }) {
            certRef = match.certificateRef
            password = match.password ?? ""
        }
        
        MUConnectionController.shared()?.connet(
            toHostname: hostname,
            port: UInt(port),
            withUsername: username,
            andPassword: password,
            certificateRef: certRef,
            displayName: displayName
        )
        
        // 最近连接由 MUConnectionController 内部调用 RecentServerManager.addRecent 自动记录
        // Widget 数据也由 RecentServerManager 自动同步
    }

    private func deleteRecentConnection(hostname: String, port: Int, username: String) {
        recentManager.recents.removeAll { item in
            item.hostname == hostname && item.port == port && item.username == username
        }
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
                #if os(macOS)
                .frame(minWidth: 500, idealWidth: 600, minHeight: 500, idealHeight: 650)
                #endif
            }
            #if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: .mumbleShowSettings)) { _ in
                guard !AppState.shared.isConnected else { return }
                showingPreferences = true
            }
            #endif
    }
}

struct MumbleNavigationModifier: ViewModifier {
    let config: NavigationConfigurable
    
    func body(content: Content) -> some View {
        content
            .navigationTitle(config.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            #endif
            .toolbar {
                #if os(iOS)
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
                #else
                ToolbarItemGroup(placement: .automatic) {
                    ForEach(Array(config.leftBarItems.enumerated()), id: \.offset) { _, item in
                        createBarButton(item)
                    }
                    ForEach(Array(config.rightBarItems.enumerated()), id: \.offset) { _, item in
                        createBarButton(item)
                    }
                }
                #endif
            }
    }
    
    @ViewBuilder
    private func createBarButton(_ item: NavigationBarItem) -> some View {
        Button(action: item.action) {
            if let title = item.title {
                Text(NSLocalizedString(title, comment: ""))
            } else if let systemImage = item.systemImage {
                Image(systemName: systemImage)
                    #if os(macOS)
                    .font(.system(size: 16))
                    #endif
            }
        }
        .buttonStyle(.borderless)
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
    @State private var splitVisibility: NavigationSplitViewVisibility = .automatic

    private let narrowWindowThreshold: CGFloat = 1100
    
    var body: some View {
        // 内容区域
        Group {
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .pad {
                iPadLayout
            } else {
                iPhoneLayout
            }
            #else
            iPadLayout
            #endif
        }
        .environmentObject(serverManager)
        .focusedValue(\.serverManager, serverManager)
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
                                .padding(.horizontal, 32).padding(.vertical, 4)
                        }
                        .modifier(RedGlassCapsuleModifier())
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                    }
                    .padding(.horizontal, 64).padding(.vertical, 24)
                    .modifier(GlassEffectModifier(cornerRadius: 32))
                    .shadow(radius: 10)
                }
                .ignoresSafeArea().zIndex(9999)
                .transition(.opacity.animation(.easeInOut(duration: 0.3)))
            }
        }
        // macOS 全窗口图片预览 overlay（覆盖整个 App 界面，包括分栏）
        #if os(macOS)
        .overlay {
            if let image = appState.previewImage {
                MacImagePreviewOverlay(image: image) {
                    appState.previewImage = nil
                }
                .transition(.opacity)
                .zIndex(10000)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.previewImage != nil)
        #endif
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
        GeometryReader { geo in
            NavigationSplitView(columnVisibility: $splitVisibility, preferredCompactColumn: $preferredCompactColumn) {
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
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 480)
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
                preferredCompactColumn = isConnected ? .detail : .sidebar
                updateSplitVisibility(width: geo.size.width)
            }
            .onChange(of: geo.size.width) { width in
                updateSplitVisibility(width: width)
            }
            .onAppear {
                if appState.isConnected {
                    preferredCompactColumn = .detail
                }
                updateSplitVisibility(width: geo.size.width)
            }
            #if os(iOS)
            .navigationSplitViewStyle(.balanced)
            #else
            .navigationSplitViewStyle(.prominentDetail)
            #endif
            .background(Color.clear)
            .preferredColorScheme(.dark)
        }
    }

    private func updateSplitVisibility(width: CGFloat) {
        #if os(iOS)
        // iPad: 保持 sidebar 与 detail 同层，不使用覆盖式 detailOnly
        splitVisibility = .all
        #else
        if appState.isConnected && width < narrowWindowThreshold {
            splitVisibility = .detailOnly
        } else {
            splitVisibility = .all
        }
        #endif
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
            #if os(iOS)
            ObjectiveCViewWrapper(controllerType: type)
            #else
            Text("Not available on macOS")
            #endif
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
