// 文件: WelcomeView.swift (最终修复版)

import SwiftUI
import UIKit

struct WelcomeNavigationConfig: NavigationConfigurable {
    let onPreferences: () -> Void; let onAbout: () -> Void; var title: String {
        "Mumble"
    }; var leftBarItems: [NavigationBarItem] {
        [NavigationBarItem(
            systemImage: "gearshape",
            action: onPreferences
        )]
    }; var rightBarItems: [NavigationBarItem] {
        [NavigationBarItem(
            systemImage: "ellipsis",
            action: onAbout
        )]
    }
}
struct WelcomeContentView: View {
    @EnvironmentObject var navigationManager: NavigationManager; var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(
                    colors: [
                        Color(
                            red: 0.20,
                            green: 0.20,
                            blue: 0.20
                        ),
                        Color(
                            red: 0.10,
                            green: 0.10,
                            blue: 0.10
                        )
                    ]
                ),
                startPoint: .top,
                endPoint: .bottom
            ).ignoresSafeArea(); VStack(
                spacing: 0
            ) {
                WelcomeHeaderView().padding(
                    .top
                ).padding(
                    .bottom,
                    20
                ); VStack(
                    spacing: 8
                ) {
                    MenuRowView(
                        title: NSLocalizedString(
                            "Public Servers",
                            comment: ""
                        ),
                        icon: "network"
                    ) {
                        navigationManager.navigate(
                            to: .objectiveC(
                                .publicServers
                            )
                        )
                    }; MenuRowView(
                        title: NSLocalizedString(
                            "Favourite Servers",
                            comment: ""
                        ),
                        icon: "heart.fill"
                    ) {
                        navigationManager.navigate(
                            to: .swiftUI(
                                .favouriteServerList
                            )
                        )
                    }; MenuRowView(
                        title: NSLocalizedString(
                            "LAN Servers",
                            comment: ""
                        ),
                        icon: "wifi"
                    ) {
                        navigationManager.navigate(
                            to: .objectiveC(
                                .lanServers
                            )
                        )
                    }
                }.padding(
                    .horizontal,
                    20
                ); Spacer()
            }
        }.toolbarBackground(
            .hidden,
            for: .navigationBar
        ).toolbarColorScheme(
            .dark,
            for: .navigationBar
        )
    }
}
struct WelcomeView: MumbleContentView {
    @State private var showingPreferences = false
    @State private var showingAbout = false;
    @EnvironmentObject var navigationManager: NavigationManager;
    var navigationConfig: any NavigationConfigurable {
        WelcomeNavigationConfig(
            onPreferences: {
                showingPreferences = true // 触发 Sheet
            },
            onAbout: { showingAbout = true }
        )
    }
    var contentBody: some View {
        WelcomeContentView()
            .sheet(isPresented: $showingPreferences) { // 新增 Sheet
                    NavigationStack {
                    PreferencesView()
                }
            }.alert(
            "About",
            isPresented: $showingAbout
        ) {
            Button(
                NSLocalizedString(
                    "OK",
                    comment: ""
                ),
                role: .cancel
            ) {
                
            }; Button(
                NSLocalizedString(
                    "Website",
                    comment: ""
                )
            ) {
                if let url = URL(
                    string: "https://www.mumble.info/"
                ) {
                    UIApplication.shared.open(
                        url
                    )
                }
            }; Button(
                NSLocalizedString(
                    "Legal",
                    comment: ""
                )
            ) {
                navigationManager.navigate(
                    to: .objectiveC(
                        .legal
                    )
                )
            }; Button(
                NSLocalizedString(
                    "Support",
                    comment: ""
                )
            ) {
                if let url = URL(
                    string: "https://github.com/mumble-voip/mumble-iphoneos/issues"
                ) {
                    UIApplication.shared.open(
                        url
                    )
                }
            }
        } message: {
            let bundleVersion = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? ""; Text("Mumble \(bundleVersion)\n\(NSLocalizedString("Low latency, high quality voice chat",comment: ""))")}
    }
}
struct MumbleNavigationModifier: ViewModifier {
    let config: NavigationConfigurable; func body(
        content: Content
    ) -> some View {
        content.navigationTitle(
            config.title
        ).navigationBarTitleDisplayMode(
            .inline
        ).toolbar {
            ToolbarItemGroup(
                placement: .navigationBarLeading
            ) {
                ForEach(
                    Array(
                        config.leftBarItems.enumerated()
                    ),
                    id: \.offset
                ) {
                    _,
                    item in createBarButton(
                        item
                    )
                }
            }; ToolbarItemGroup(
                placement: .navigationBarTrailing
            ) {
                ForEach(
                    Array(
                        config.rightBarItems.enumerated()
                    ),
                    id: \.offset
                ) {
                    _,
                    item in createBarButton(
                        item
                    )
                }
            }
        }
    }; @ViewBuilder private func createBarButton(
        _ item: NavigationBarItem
    ) -> some View {
        Button(
            action: item.action
        ) {
            if let title = item.title {
                Text(
                    NSLocalizedString(
                        title,
                        comment: ""
                    )
                )
            } else if let systemImage = item.systemImage {
                Image(
                    systemName: systemImage
                )
            }
        }.foregroundStyle(
            .primary
        )
    }
}
struct WelcomeRootView: View {
    @StateObject private var navigationManager = NavigationManager(); var body: some View {
        NavigationStack(
            path: $navigationManager.navigationPath
        ) {
            WelcomeView().navigationDestination(
                for: NavigationDestination.self
            ) {
                destination in destinationView(
                    for: destination
                ).environmentObject(
                    navigationManager
                )
            }.environmentObject(
                navigationManager
            )
        }.preferredColorScheme(
            .dark
        )
    }; @ViewBuilder private func destinationView(
        for destination: NavigationDestination
    ) -> some View {
        switch destination {
        case .objectiveC(
            let type
        ): ObjectiveCViewWrapper(
            controllerType: type
        ); case .swiftUI(
            let type
        ): switch type {
        case .favouriteServerList: FavouriteServerListView(); case .favouriteServerEdit(
            let primaryKey
        ): let server: MUFavouriteServer? = {
            guard let key = primaryKey else {
                return nil
            }; if let allFavourites = MUDatabase.fetchAllFavourites() as? [MUFavouriteServer] {
                return allFavourites.first {
                    $0.primaryKey == key
                }
            }; return nil
        }(); FavouriteServerEditView(
            server: server
        ) {
            serverToSave in MUDatabase.storeFavourite(
                serverToSave
            ); navigationManager.goBack()
        }; case .channelList: ChannelListView()
        }
        }
    }
} // AppRootView 保持不变
struct AppRootView: View {
    @ObservedObject private var appState = AppState.shared

    // 为两个独立的导航栈分别创建 NavigationManager
    @StateObject private var disconnectedNavManager = NavigationManager()
    @StateObject private var connectedNavManager = NavigationManager()

    var body: some View {
            ZStack {
                // 主界面逻辑
                if appState.isConnected {
                    NavigationStack(path: $connectedNavManager.navigationPath) {
                        ChannelListView()
                            .navigationDestination(for: NavigationDestination.self) { destination in
                                destinationView(for: destination, with: connectedNavManager)
                            }
                    }
                    .environmentObject(connectedNavManager)
                    .preferredColorScheme(.dark)
                    .transition(.move(edge: .trailing))
                } else {
                    NavigationStack(path: $disconnectedNavManager.navigationPath) {
                        WelcomeView()
                            .navigationDestination(for: NavigationDestination.self) { destination in
                                destinationView(for: destination, with: disconnectedNavManager)
                            }
                    }
                    .environmentObject(disconnectedNavManager)
                    .preferredColorScheme(.dark)
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .top) {
                if let toast = appState.activeToast {
                    ToastView(toast: toast)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(2000) // 确保在 PTT 按钮和普通内容之上
                        // 点击 Toast 可以立即关闭
                        .onTapGesture {
                            withAnimation {
                                appState.activeToast = nil
                            }
                        }
                }
            }
            .overlay(alignment: .bottom) {
                // 只有连接成功后才显示 PTT 按钮
                if appState.isConnected {
                    PTTButton()
                        // 确保它不遮挡底部的某些操作，或者根据需要调整位置
                        .padding(.bottom, 20)
                }
            }
            // 修改点 2: 使用 .overlay 将遮罩层置于一切之上
            .overlay {
                if appState.isConnecting {
                    ZStack {
                        // 全屏半透明背景
                        Color.black.opacity(0.6)
                            .ignoresSafeArea()
                            // 添加点击拦截，防止连接时误触底部按钮
                            .onTapGesture { }
                        
                        // Loading 内容框
                        VStack(spacing: 24) {
                            ProgressView()
                                .controlSize(.large)
                                .tint(.white)
                            
                            Text("Connecting...")
                                .font(.headline)
                                .foregroundColor(.white)
                        }
                        .padding(30)
                        .background(.ultraThinMaterial) // 漂亮的毛玻璃
                        .clipShape(RoundedRectangle(cornerRadius: 30))
                        .shadow(radius: 10)
                    }
                    .ignoresSafeArea()
                    .zIndex(9999) // 确保在最上层
                    .transition(.opacity.animation(.easeInOut(duration: 0.3)))
                }
            }
            // 全局错误弹窗
            .alert(item: $appState.activeError) { error in
                Alert(
                    title: Text(error.title),
                    message: Text(error.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .animation(.default, value: appState.isConnecting)
            .animation(.spring(), value: appState.isConnected)
        }
    
    @ViewBuilder
    private func destinationView(for destination: NavigationDestination, with manager: NavigationManager) -> some View {
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
                    manager.goBack()
                }
            case .channelList:
                EmptyView()
            }
        }
    }
}
