//
//  WelcomeView.swift
//  Mumble
//
//  Created by 王梓田 on 2025/6/27.
//

import SwiftUI
import UIKit

struct WelcomeNavigationConfig: NavigationConfigurable {
    let onPreferences: () -> Void
    let onAbout: () -> Void
    
    var title: String { "Mumble" }
    var leftBarItems: [NavigationBarItem] {
        [NavigationBarItem(systemImage: "gearshape", action: onPreferences)]
    }
    var rightBarItems: [NavigationBarItem] {
        [NavigationBarItem(systemImage: "info.circle", action: onAbout)]
    }
}

struct WelcomeContentView: View {
    @EnvironmentObject var navigationManager: NavigationManager
    @StateObject private var lanModel = LanDiscoveryModel()
    @ObservedObject private var recentManager = RecentServerManager.shared
    
    @State private var favouriteServers: [MUFavouriteServer] = []
    
    var body: some View {
        ZStack {
            // 背景
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.20, green: 0.20, blue: 0.20),
                    Color(red: 0.10, green: 0.10, blue: 0.10)
                ]),
                startPoint: .top,
                endPoint: .bottom
            ).ignoresSafeArea()
            
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
                        .contentShape(Rectangle())
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 27))
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
                        .listRowBackground(Rectangle().fill(.regularMaterial))
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
        }
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
        
        MUConnectionController.shared()?.connet(
            toHostname: hostname,
            port: UInt(port),
            withUsername: username,
            andPassword: "", // 最近列表/LAN 暂不存储密码，需要的话可以在 Model 里加 password 字段
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
                    .font(.system(size: 18)) // 稍微调整一下图标大小
                
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
    
    var navigationConfig: any NavigationConfigurable {
        WelcomeNavigationConfig(
            onPreferences: { showingPreferences = true },
            onAbout: { showingAbout = true }
        )
    }

    var contentBody: some View {
        WelcomeContentView()
            .sheet(isPresented: $showingPreferences) {
                NavigationStack {
                    PreferencesView()
                }
            }
            .alert("About", isPresented: $showingAbout) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Mumble for iOS\nRefactored with SwiftUI")
            }
    }
}

struct MumbleNavigationModifier: ViewModifier {
    let config: NavigationConfigurable
    
    func body(content: Content) -> some View {
        content
            .navigationTitle(config.title)
            .navigationBarTitleDisplayMode(.inline)
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

struct WelcomeRootView: View {
    @StateObject private var navigationManager = NavigationManager()
    
    var body: some View {
        NavigationStack(path: $navigationManager.navigationPath) {
            WelcomeView()
                .navigationDestination(for: NavigationDestination.self) { destination in
                    // 这里只是一个简单的预览实现，实际逻辑在 AppRootView
                    Text("Destination: \(String(describing: destination))")
                }
                .environmentObject(navigationManager)
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - 核心修改后的 AppRootView

struct AppRootView: View {
    @ObservedObject private var appState = AppState.shared

    // 统一使用一个 NavigationManager，不再区分连接前后的栈
    @StateObject private var navigationManager = NavigationManager()

    var body: some View {
        ZStack {
            // 单一 NavigationStack，以 WelcomeView 为根
            NavigationStack(path: $navigationManager.navigationPath) {
                WelcomeView()
                    .navigationDestination(for: NavigationDestination.self) { destination in
                        destinationView(for: destination)
                    }
            }
            .environmentObject(navigationManager)
            .preferredColorScheme(.dark)
        }
        // --- 全局覆盖层 (Toast, PTT, Connect Loading) ---
        .overlay(alignment: .top) {
            if let toast = appState.activeToast {
                ToastView(toast: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(2000)
                    .onTapGesture {
                        withAnimation { appState.activeToast = nil }
                    }
            }
        }
        .overlay(alignment: .bottom) {
            // 只有连接成功后才显示 PTT 按钮
            if appState.isConnected {
                PTTButton()
                    .padding(.bottom, 20)
            }
        }
        .overlay {
            if appState.isConnecting {
                ZStack {
                    // 全屏半透明背景防止误触
                    Color.black.opacity(0.6)
                        .ignoresSafeArea()
                        .onTapGesture { }
                    
                    // Loading 内容框
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                        
                        Text(appState.isReconnecting ? "Reconnecting..." : "Connecting...")
                            .font(.headline)
                            .foregroundColor(.white)
                        Button(action: {
                            appState.cancelConnection()
                        }) {
                            Text("Cancel")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                                .padding(.horizontal, 32)
                                .padding(.vertical, 10)
                                .glassEffect(.regular.tint(.red.opacity(0.5)).interactive(), in: Capsule())
                        }
                    }
                    .padding(.horizontal, 64)
                    .padding(.vertical, 24)
                    .glassEffect(.regular.interactive(),in: .rect(cornerRadius: 32))
                    .shadow(radius: 10)
                }
                .ignoresSafeArea()
                .zIndex(9999)
                .transition(.opacity.animation(.easeInOut(duration: 0.3)))
            }
        }
        .alert(item: $appState.activeError) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
        // --- 核心逻辑：根据连接状态驱动导航 ---
        .onChange(of: appState.isConnected) { isConnected in
            if isConnected {
                // 连接成功 -> 推入 ChannelList
                // 避免重复推入（虽然通常 isConnected 只会变一次）
                navigationManager.navigate(to: .swiftUI(.channelList))
            } else {
                // 连接断开 -> 返回根视图 (WelcomeView)
                navigationManager.goToRoot()
            }
        }
        .animation(.default, value: appState.isConnecting)
        .animation(.spring(), value: appState.isConnected)
    }
    
    @ViewBuilder
    private func destinationView(for destination: NavigationDestination) -> some View {
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
