// 文件: FavouriteServerListView.swift (已修复UI问题)

import SwiftUI
import UIKit

// FavouriteServerListNavigationConfig 保持不变
struct FavouriteServerListNavigationConfig: NavigationConfigurable {
    let onAdd: () -> Void; var title: String {
        NSLocalizedString(
            "Favourite Servers",
            comment: ""
        )
    }; var leftBarItems: [NavigationBarItem] {
        []
    }; var rightBarItems: [NavigationBarItem] {
        [NavigationBarItem(
            systemImage: "plus",
            action: onAdd
        )]
    }
}


// --- 核心修改在这里 ---
struct FavouriteServerRowView: View {
    let server: MUFavouriteServer
    
    var body: some View {
        HStack(
            spacing: 16
        ) {
            // 左侧信息区
            VStack(
                alignment: .leading,
                spacing: 4
            ) {
                // 服务器显示名称
                Text(
                    server.displayName ?? "Unknown Server"
                )
                .font(
                    .system(
                        size: 17,
                        weight: .semibold
                    )
                )
                
                // 地址和端口号
                // 修复 1：将 port (UInt) 转换为不带逗号的 String
                Text("\(server.hostName ?? ""):\(String(server.port))")
                .font(
                    .system(
                        size: 14
                    )
                )
                .foregroundColor(
                    .secondary
                )
                
                // 用户名
                if let userName = server.userName, !userName.isEmpty {
                    HStack(
                        spacing: 4
                    ) {
                        Image(
                            systemName: "person.fill"
                        )
                        Text(
                            userName
                        )
                    }
                    .font(
                        .system(
                            size: 12
                        )
                    )
                    .foregroundColor(
                        .secondary
                    )
                }
            }
            
            Spacer()
            
            // 右侧的 chevron 图标
            Image(
                systemName: "chevron.right"
            )
            .font(
                .system(
                    size: 14,
                    weight: .medium
                )
            )
            .foregroundColor(
                .indigo
            )
        }
        // 修复 2：为整个 HStack 设置主颜色，确保文本默认为白色
        .foregroundColor(
            .primary
        )
        .padding(
            .horizontal,
            16
        )
        .padding(
            .vertical,
            12
        )
        // 修复 3：使用更明显的背景和边框，增强卡片感
        .background(
            .thinMaterial,
            in: RoundedRectangle(
                cornerRadius: 12,
                style: .continuous
            )
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: 12
            )
            .stroke(
                Color.white.opacity(
                    0.25
                ),
                lineWidth: 1.5
            )
        )
    }
}


// 主内容视图：移除了所有与在线人数相关的逻辑
struct FavouriteServerListContentView: View {
    var navigationManager: NavigationManager
    
    @State private var favouriteServers: [MUFavouriteServer] = []
    @State private var serverToDelete: MUFavouriteServer?
    @State private var showingDeleteAlert = false
    @State private var showingConnectionAlert = false
    @State private var connectionMessage = ""
    
    private let connectionSuccessNotificationName = Notification.Name(
        "MUConnectionOpenedNotification"
    )
    
    var body: some View {
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
            )
            .ignoresSafeArea(
                .all
            )
            
            if favouriteServers.isEmpty {
                emptyStateView
            } else {
                List {
                    ForEach(
                        favouriteServers,
                        id: \.primaryKey
                    ) { server in
                        Menu {
                            Button(
                                "Connect",
                                systemImage: "bolt.fill"
                            ) {
                                connectToServer(
                                    server
                                )
                            }
                            Button(
                                "Edit",
                                systemImage: "pencil"
                            ) {
                                editServer(
                                    server
                                )
                            }
                            Button(
                                "Delete",
                                systemImage: "trash",
                                role: .destructive
                            ) {
                                self.serverToDelete = server
                                self.showingDeleteAlert = true
                            }
                        } label: {
                            FavouriteServerRowView(
                                server: server
                            )
                        }
                    }
                    .onDelete(
                        perform: deleteServers
                    )
                    .listRowBackground(
                        Color.clear
                    )
                    .listRowSeparator(
                        .hidden
                    )
                    .listRowInsets(
                        EdgeInsets(
                            top: 8,
                            leading: 16,
                            bottom: 8,
                            trailing: 16
                        )
                    )
                }
                .listStyle(
                    .plain
                )
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: connectionSuccessNotificationName
            )
        ) {
            _ in handleConnectionSuccess()
        }
        .onAppear(
            perform: loadFavouriteServers
        )
        .alert(
            "Delete Favourite",
            isPresented: $showingDeleteAlert,
            presenting: serverToDelete
        ) { server in
            Button(
                "Delete",
                role: .destructive
            ) {
                deleteFavouriteServer(
                    server
                )
            }
        } message: { server in
            Text(
                "Are you sure you want to delete '\(server.displayName ?? "this server")'?"
            )
        }
        .alert(
            "Connecting",
            isPresented: $showingConnectionAlert
        ) {
            Button(
                "Cancel"
            ) {
                showingConnectionAlert = false
            }
        } message: {
            Text(
                connectionMessage
            )
        }
    }
    
    private var emptyStateView: some View {
        VStack(
            spacing: 20
        ) {
            Image(
                systemName: "heart.slash"
            )
            .font(
                .system(
                    size: 60,
                    weight: .light
                )
            )
            .foregroundColor(
                .gray
            )
            Text(
                NSLocalizedString(
                    "No Favourite Servers",
                    comment: ""
                )
            )
            .font(
                .title2
            )
            .foregroundColor(
                .white
            )
            Text(
                NSLocalizedString(
                    "Tap + to add a favourite server",
                    comment: ""
                )
            )
            .font(
                .body
            )
            .foregroundColor(
                .gray
            )
            .multilineTextAlignment(
                .center
            )
        }.padding()
    }
    
    private func handleConnectionSuccess() {
        Task {
            @MainActor in print(
                "✅ Received 'MUConnectionOpenedNotification'! Updating global state."
            ); self.showingConnectionAlert = false; withAnimation(
                .spring()
            ) {
                AppState.shared.isConnected = true
            }
        }
    }
    private func connectToServer(
        _ server: MUFavouriteServer
    ) {
        AppState.shared.serverDisplayName = server.displayName; connectionMessage = "Connecting to \(server.displayName ?? "server")..."; showingConnectionAlert = true; MUConnectionController.shared()?.connet(
            toHostname: server.hostName,
            port: UInt(
                server.port
            ),
            withUsername: server.userName,
            andPassword: server.password,
            withParentViewController: nil
        )
    }
    private func loadFavouriteServers() {
        let serversArray = MUDatabase.fetchAllFavourites(); if let array = serversArray as? [MUFavouriteServer] {
            favouriteServers = array.sorted {
                $0.compare(
                    $1
                ) == .orderedAscending
            }
        } else if let nsArray = serversArray as NSArray? {
            let servers = nsArray.compactMap {
                $0 as? MUFavouriteServer
            }; favouriteServers = servers.sorted {
                $0.compare(
                    $1
                ) == .orderedAscending
            }
        } else {
            favouriteServers = []
        }
    }
    private func deleteServers(
        offsets: IndexSet
    ) {
        for index in offsets {
            deleteFavouriteServer(
                favouriteServers[index]
            )
        }
    }
    private func deleteFavouriteServer(
        _ server: MUFavouriteServer
    ) {
        MUDatabase.deleteFavourite(
            server
        ); loadFavouriteServers()
    }
    private func editServer(
        _ server: MUFavouriteServer
    ) {
        navigationManager.navigate(
            to: .swiftUI(
                .favouriteServerEdit(
                    primaryKey: server.primaryKey
                )
            )
        )
    }
}

// FavouriteServerListView 定义保持不变
struct FavouriteServerListView: MumbleContentView {
    @EnvironmentObject var navigationManager: NavigationManager
    var navigationConfig: any NavigationConfigurable {
        FavouriteServerListNavigationConfig(
            onAdd: {
                navigationManager.navigate(
                    to: .swiftUI(
                        .favouriteServerEdit(
                            primaryKey: nil
                        )
                    )
                )
            })
    }
    var contentBody: some View {
        FavouriteServerListContentView(
            navigationManager: navigationManager
        )
    }
}
