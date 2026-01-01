// 文件: FavouriteServerListView.swift

import SwiftUI
import UIKit

// FavouriteServerListNavigationConfig 保持不变
struct FavouriteServerListNavigationConfig: NavigationConfigurable {
    let onAdd: () -> Void
    var title: String { NSLocalizedString("Favourite Servers", comment: "") }
    var leftBarItems: [NavigationBarItem] { [] }
    var rightBarItems: [NavigationBarItem] { [NavigationBarItem(systemImage: "plus", action: onAdd)] }
}

struct FavouriteServerRowView: View {
    let server: MUFavouriteServer
    @StateObject private var pingModel: ServerPingModel
    
    init(server: MUFavouriteServer) {
        self.server = server
        _pingModel = StateObject(wrappedValue: ServerPingModel(hostname: server.hostName, port: UInt(server.port)))
    }
    
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(server.displayName ?? "Unknown Server")
                    .font(.system(size: 17, weight: .semibold))
                
                Text("\(server.hostName ?? ""):\(String(server.port))")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                
                if let userName = server.userName, !userName.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "person.fill")
                        Text(userName)
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    Text(pingModel.pingLabel)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(pingModel.pingColor)
                    
                    Image(systemName: "network")
                        .font(.system(size: 12))
                        .foregroundColor(pingModel.pingColor)
                }
                
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
            .fixedSize(horizontal: true, vertical: false)
            
            Image(systemName: "chevron.right")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.indigo)
        }
        .foregroundColor(.primary)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .glassEffect(.clear.interactive(), in: .rect(cornerRadius: 27))
        .onAppear { pingModel.startPinging() }
        .onDisappear { pingModel.stopPinging() }
    }
}

struct FavouriteServerListContentView: View {
    var navigationManager: NavigationManager
    
    @State private var favouriteServers: [MUFavouriteServer] = []
    @State private var serverToDelete: MUFavouriteServer?
    @State private var showingDeleteAlert = false
    
    private let successHaptic = UINotificationFeedbackGenerator()
    
    var body: some View {
        ZStack {
            if favouriteServers.isEmpty {
                emptyStateView
            } else {
                List {
                    ForEach(favouriteServers, id: \.primaryKey) { server in
                        Menu {
                            Button("Connect", systemImage: "bolt.fill") { connectToServer(server) }
                            Button("Edit", systemImage: "pencil") { editServer(server) }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                self.serverToDelete = server
                                self.showingDeleteAlert = true
                            }
                        } label: {
                            FavouriteServerRowView(server: server)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
                .listStyle(.plain)
            }
        }
        .onAppear {
            loadFavouriteServers()
        }
        .alert("Delete Favourite", isPresented: $showingDeleteAlert, presenting: serverToDelete) { server in
            Button("Delete", role: .destructive) { deleteFavouriteServer(server) }
        } message: { server in
            Text("Are you sure you want to delete '\(server.displayName ?? "this server")'?")
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "heart.slash")
                .font(.system(size: 60, weight: .light))
                .foregroundColor(.gray)
            Text("No Favourite Servers")
                .font(.title2)
                .foregroundColor(.white)
            Text("Tap + to add a favourite server")
                .font(.body)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }.padding()
    }
    
    private func connectToServer(_ server: MUFavouriteServer) {
        AppState.shared.serverDisplayName = server.displayName
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
        // 调用 OC 数据库接口
        let result = MUDatabase.fetchAllFavourites()
        
        // 安全类型转换
        if let nsArray = result as NSArray? {
            // 强制转换为 Swift 数组并过滤无效对象
            let servers = nsArray.compactMap { $0 as? MUFavouriteServer }
            
            // 排序
            favouriteServers = servers.sorted {
                ($0.displayName ?? "").localizedCaseInsensitiveCompare($1.displayName ?? "") == .orderedAscending
            }
        } else {
            favouriteServers = []
        }
    }
    
    private func deleteServers(offsets: IndexSet) {
        for index in offsets {
            deleteFavouriteServer(favouriteServers[index])
        }
    }
    
    private func deleteFavouriteServer(_ server: MUFavouriteServer) {
        MUDatabase.deleteFavourite(server)
        loadFavouriteServers()
    }
    
    private func editServer(_ server: MUFavouriteServer) {
        navigationManager.navigate(to: .swiftUI(.favouriteServerEdit(primaryKey: server.primaryKey)))
    }
}

struct FavouriteServerListView: MumbleContentView {
    @EnvironmentObject var navigationManager: NavigationManager
    var navigationConfig: any NavigationConfigurable {
        FavouriteServerListNavigationConfig(onAdd: {
            navigationManager.navigate(to: .swiftUI(.favouriteServerEdit(primaryKey: nil)))
        })
    }
    var contentBody: some View {
        FavouriteServerListContentView(navigationManager: navigationManager)
    }
}
