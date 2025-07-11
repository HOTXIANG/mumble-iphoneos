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
    @State private var showingAbout = false; @EnvironmentObject var navigationManager: NavigationManager; var navigationConfig: any NavigationConfigurable {
        WelcomeNavigationConfig(
            onPreferences: {
                navigationManager.navigate(
                    to: .objectiveC(
                        .preferences
                    )
                )
            },
            onAbout: {
                showingAbout = true
            })
    }; var contentBody: some View {
        WelcomeContentView().alert(
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
    // 监听我们创建的全局状态
    @StateObject private var appState = AppState.shared

    var body: some View {
        // 使用ZStack可以帮助动画系统在过渡期间更好地管理两个视图
        ZStack {
            // 根据 isConnected 的值来决定显示哪个界面
            if appState.isConnected {
                // 如果已连接，直接显示频道界面
                NavigationStack {
                    ChannelListView()
                }
                .preferredColorScheme(.dark)
                // 频道视图的动画：总是从右侧滑入和滑出
                .transition(.move(edge: .trailing))
                .zIndex(1) // 确保它在顶层
            } else {
                // 如果未连接，显示我们现有的欢迎界面流程
                WelcomeRootView()
                    // 欢迎页的动画：原地淡入淡出，不滑动
                    .transition(.opacity)
                    .zIndex(0) // 确保它在底层
            }
        }
    }
}
