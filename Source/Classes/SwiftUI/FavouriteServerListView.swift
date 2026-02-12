// 文件: FavouriteServerListView.swift

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import WidgetKit

// MARK: - Identifiable wrapper（ObjC 的 MUFavouriteServer 无法直接遵循 Identifiable）

struct EditableServer: Identifiable {
    let id: NSInteger
    let server: MUFavouriteServer
    init(_ server: MUFavouriteServer) {
        self.id = server.primaryKey
        self.server = server
    }
}

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
    @ObservedObject var certModel = CertificateModel.shared
    
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

                        if let certRef = server.certificateRef {
                            if certModel.isCertificateValid(certRef) {
                                // 证书有效：绿色盾牌
                                Image(systemName: "checkmark.shield.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.green)
                            } else {
                                // 证书失效 (丢失)：黄色警告盾牌
                                Image(systemName: "exclamationmark.shield.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.yellow)
                            }
                        }
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
        .modifier(ClearGlassModifier(cornerRadius: 27))
        .onAppear {
            pingModel.startPinging()
            if certModel.certificates.isEmpty {
                certModel.refreshCertificates()
            }
        }
        .onDisappear { pingModel.stopPinging() }
    }
}

struct FavouriteServerListContentView: View {
    var navigationManager: NavigationManager
    
    @Binding var serverToEdit: EditableServer?
    var refreshTrigger: UUID
    
    @State private var favouriteServers: [MUFavouriteServer] = []
    @State private var serverToDelete: MUFavouriteServer?
    @State private var showingDeleteAlert = false
    
    private let successHaptic = PlatformNotificationFeedback()
    
    var body: some View {
        Group {
            if favouriteServers.isEmpty {
                emptyStateView
            } else {
                #if os(macOS)
                // macOS: ScrollView + LazyVStack (List 在 NavigationSplitView sidebar 中渲染不可靠)
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(favouriteServers, id: \.primaryKey) { server in
                            FavouriteServerRowView(server: server)
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                                .onTapGesture { connectToServer(server) }
                                .contextMenu {
                                    Button("Connect", systemImage: "bolt.fill") { connectToServer(server) }
                                    Button("Edit", systemImage: "pencil") { editServer(server) }
                                    
                                    if isServerPinned(server) {
                                        Button("Remove from Widget", systemImage: "minus.square") {
                                            unpinFromWidget(server)
                                        }
                                    } else {
                                        Button("Add to Widget", systemImage: "plus.square.on.square") {
                                            pinToWidget(server)
                                        }
                                    }
                                    
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        self.serverToDelete = server
                                        self.showingDeleteAlert = true
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 20)
                }
                #else
                List {
                    ForEach(favouriteServers, id: \.primaryKey) { server in
                        Menu {
                            Button("Connect", systemImage: "bolt.fill") { connectToServer(server) }
                            Button("Edit", systemImage: "pencil") { editServer(server) }
                            
                            if isServerPinned(server) {
                                Button("Remove from Widget", systemImage: "minus.square") {
                                    unpinFromWidget(server)
                                }
                            } else {
                                Button("Add to Widget", systemImage: "plus.square.on.square") {
                                    pinToWidget(server)
                                }
                            }
                            
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
                .scrollContentBackground(.hidden)
                #endif
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.20, green: 0.20, blue: 0.25),
                    Color(red: 0.07, green: 0.07, blue: 0.10)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .onAppear {
            loadFavouriteServers()
        }
        .onChange(of: refreshTrigger) { _ in
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
        PlatformImpactFeedback(style: .medium).impactOccurred()
        
        MUConnectionController.shared()?.connet(
            toHostname: server.hostName,
            port: UInt(server.port),
            withUsername: server.userName,
            andPassword: server.password,
            certificateRef: server.certificateRef,
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
            
            print("📋 FavouriteServers: loaded \(servers.count) servers from database")
            
            // 排序
            favouriteServers = servers.sorted {
                ($0.displayName ?? "").localizedCaseInsensitiveCompare($1.displayName ?? "") == .orderedAscending
            }
        } else {
            print("⚠️ FavouriteServers: fetchAllFavourites returned nil")
            favouriteServers = []
        }
    }
    
    private func deleteServers(offsets: IndexSet) {
        for index in offsets {
            deleteFavouriteServer(favouriteServers[index])
        }
    }
    
    private func deleteFavouriteServer(_ server: MUFavouriteServer) {
        // 如果该服务器已固定到 Widget，同时移除
        let widgetId = WidgetServerItem.makeId(
            hostname: server.hostName ?? "",
            port: Int(server.port),
            username: server.userName ?? ""
        )
        WidgetDataManager.shared.unpinServer(id: widgetId)
        
        MUDatabase.deleteFavourite(server)
        loadFavouriteServers()
    }
    
    // MARK: - Widget Pin/Unpin
    
    private func isServerPinned(_ server: MUFavouriteServer) -> Bool {
        WidgetDataManager.shared.isPinned(
            hostname: server.hostName ?? "",
            port: Int(server.port),
            username: server.userName ?? ""
        )
    }
    
    private func pinToWidget(_ server: MUFavouriteServer) {
        let item = WidgetServerItem(
            id: WidgetServerItem.makeId(
                hostname: server.hostName ?? "",
                port: Int(server.port),
                username: server.userName ?? ""
            ),
            displayName: server.displayName ?? server.hostName ?? "Unknown",
            hostname: server.hostName ?? "",
            port: Int(server.port),
            username: server.userName ?? "",
            hasCertificate: server.certificateRef != nil,
            lastConnected: nil
        )
        WidgetDataManager.shared.pinServer(item)
        
        PlatformNotificationFeedback().notificationOccurred(.success)
        withAnimation {
            AppState.shared.activeToast = AppToast(message: "Added to Widget", type: .success)
        }
    }
    
    private func unpinFromWidget(_ server: MUFavouriteServer) {
        let id = WidgetServerItem.makeId(
            hostname: server.hostName ?? "",
            port: Int(server.port),
            username: server.userName ?? ""
        )
        WidgetDataManager.shared.unpinServer(id: id)
        
        withAnimation {
            AppState.shared.activeToast = AppToast(message: "Removed from Widget", type: .info)
        }
    }
    
    private func editServer(_ server: MUFavouriteServer) {
        // 延迟 0.4s 等待 Menu 动画完全退出，避免 _UIReparentingView 冲突
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            serverToEdit = EditableServer(server)
        }
    }
}

struct FavouriteServerListView: MumbleContentView {
    @EnvironmentObject var navigationManager: NavigationManager
    
    @State private var showingNewSheet = false
    @State private var serverToEdit: EditableServer?
    @State private var refreshTrigger = UUID()
    
    var navigationConfig: any NavigationConfigurable {
        FavouriteServerListNavigationConfig(onAdd: {
            showingNewSheet = true
        })
    }
    var contentBody: some View {
        FavouriteServerListContentView(
            navigationManager: navigationManager,
            serverToEdit: $serverToEdit,
            refreshTrigger: refreshTrigger
        )
        // 新建收藏
        .sheet(isPresented: $showingNewSheet, onDismiss: {
            // Sheet 完全关闭后再刷新列表，避免 macOS 上 SwiftUI 在 sheet 动画期间不传播状态
            refreshTrigger = UUID()
        }) {
            NavigationStack {
                FavouriteServerEditView(server: nil) { savedServer in
                    MUDatabase.storeFavourite(savedServer)
                    showingNewSheet = false
                }
            }
        }
        // 编辑收藏 —— 使用 .sheet(item:) 保证 server 一定非 nil
        .sheet(item: $serverToEdit, onDismiss: {
            refreshTrigger = UUID()
        }) { editable in
            NavigationStack {
                FavouriteServerEditView(server: editable.server) { savedServer in
                    MUDatabase.storeFavourite(savedServer)
                    serverToEdit = nil
                }
            }
        }
    }
}
