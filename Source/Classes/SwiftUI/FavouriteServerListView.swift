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

struct FavouriteServerRowView: View {
    let server: MUFavouriteServer
    
    @StateObject private var pingModel: ServerPingModel
    
    init(server: MUFavouriteServer) {
        self.server = server
        // 在 init 中初始化 StateObject
        _pingModel = StateObject(wrappedValue: ServerPingModel(hostname: server.hostName, port: UInt(server.port)))
    }
    
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
            
            VStack(alignment: .trailing, spacing: 4) {
                // 1. 延迟显示
                HStack(spacing: 4) {
                    Text(pingModel.pingLabel)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(pingModel.pingColor)
                    
                    Image(systemName: "network")
                        .font(.system(size: 12))
                        .foregroundColor(pingModel.pingColor)
                }
                
                // 2. 人数显示
                if !pingModel.usersLabel.isEmpty {
                    HStack(spacing: 4) {
                        Text(pingModel.usersLabel)
                            .font(.system(size: 13))
                            .foregroundColor(pingModel.userCountColor)
                        
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }
            // 确保不被压缩
            .fixedSize(horizontal: true, vertical: false)
            
            // 右侧的 chevron 图标
            Image(
                systemName: "chevron.right"
            )
            .font(.caption)
            .fontWeight(.bold)
            .foregroundColor(.indigo)
        }
        .foregroundColor(
            .primary
        )
        .padding(
            .horizontal,
            20
        )
        .padding(
            .vertical,
            16
        )
        .glassEffect(.regular.interactive(),in: .rect(cornerRadius: 27))
        .onAppear {
            pingModel.startPinging()
        }
        .onDisappear {
            pingModel.stopPinging()
        }
    }
}

struct FavouriteServerListContentView: View {
    var navigationManager: NavigationManager
    
    @State private var favouriteServers: [MUFavouriteServer] = []
    @State private var serverToDelete: MUFavouriteServer?
    @State private var showingDeleteAlert = false
    
    private let connectionSuccessNotificationName = Notification.Name(
        "MUConnectionOpenedNotification"
    )
    private let connectionConnectingNotificationName = Notification.Name("MUConnectionConnectingNotification")
    private let connectionErrorNotificationName = Notification.Name("MUConnectionErrorNotification")
    
    private let successHaptic = UINotificationFeedbackGenerator()
    
    var body: some View {
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
            .scrollContentBackground(.hidden)
            .listStyle(
                .plain
            )
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
            );
            // 1. 准备并触发第一次强烈的震动
            successHaptic.prepare()
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                        
            // 2. 延迟一小段时间后，触发震动
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
    }
    private func connectToServer(_ server: MUFavouriteServer) {
        // 只负责更新名字和发起连接，UI 由 AppState 接管
        AppState.shared.serverDisplayName = server.displayName
        
        // 触发触感反馈
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        
        MUConnectionController.shared()?.connet(
            toHostname: server.hostName,
            port: UInt(server.port),
            withUsername: server.userName,
            andPassword: server.password,
            displayName: server.displayName
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
