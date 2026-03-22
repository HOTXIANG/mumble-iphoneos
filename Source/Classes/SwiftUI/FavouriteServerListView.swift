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
    let onClose: (() -> Void)?
    var title: String { NSLocalizedString("Favourite Servers", comment: "") }
    var leftBarItems: [NavigationBarItem] {
        guard let onClose else { return [] }
        return [NavigationBarItem(systemImage: "xmark", action: onClose)]
    }
    var rightBarItems: [NavigationBarItem] { [NavigationBarItem(systemImage: "plus", action: onAdd)] }
}

struct FavouriteServerRowView: View {
    let server: MUFavouriteServer
    @StateObject private var pingModel: ServerPingModel
    @ObservedObject var certModel = CertificateModel.shared
    @Environment(\.colorScheme) private var colorScheme

    #if os(macOS)
    private let rowHStackSpacing: CGFloat = 10
    private let rowVerticalStackSpacing: CGFloat = 3
    private let rowHorizontalPadding: CGFloat = 16
    private let rowVerticalPadding: CGFloat = 10
    private let rowCornerRadius: CGFloat = 18
    private let titleFontSize: CGFloat = 14
    private let hostFontSize: CGFloat = 12
    private let usernameFontSize: CGFloat = 11
    private let pingFontSize: CGFloat = 12
    private let usersFontSize: CGFloat = 11
    #else
    private let rowHStackSpacing: CGFloat = 16
    private let rowVerticalStackSpacing: CGFloat = 4
    private let rowHorizontalPadding: CGFloat = 20
    private let rowVerticalPadding: CGFloat = 16
    private let rowCornerRadius: CGFloat = 27
    private let titleFontSize: CGFloat = 17
    private let hostFontSize: CGFloat = 14
    private let usernameFontSize: CGFloat = 12
    private let pingFontSize: CGFloat = 14
    private let usersFontSize: CGFloat = 13
    #endif
    
    init(server: MUFavouriteServer) {
        self.server = server
        _pingModel = StateObject(wrappedValue: ServerPingModel(hostname: server.hostName, port: UInt(server.port)))
    }
    
    var body: some View {
        HStack(spacing: rowHStackSpacing) {
            VStack(alignment: .leading, spacing: rowVerticalStackSpacing) {
                Text(server.displayName ?? NSLocalizedString("Unknown Server", comment: ""))
                    .font(.system(size: titleFontSize, weight: .semibold))
                
                Text("\(server.hostName ?? ""):\(String(server.port))")
                    .font(.system(size: hostFontSize))
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
                    .font(.system(size: usernameFontSize))
                    .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: rowVerticalStackSpacing) {
                HStack(spacing: 4) {
                    Text(pingModel.pingLabel)
                        .font(.system(size: pingFontSize, weight: .bold))
                        .foregroundColor(pingModel.pingColor)
                    
                    Image(systemName: "network")
                        .font(.system(size: 12))
                        .foregroundColor(pingModel.pingColor)
                }
                
                if !pingModel.usersLabel.isEmpty {
                    HStack(spacing: 4) {
                        Text(pingModel.usersLabel)
                            .font(.system(size: usersFontSize))
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
        .padding(.horizontal, rowHorizontalPadding)
        .padding(.vertical, rowVerticalPadding)
        #if os(macOS)
        .modifier(
            ClearGlassModifier(
                cornerRadius: rowCornerRadius,
                lightTintOpacity: colorScheme == .light ? 0.0 : 0.12,
                lightFallbackOverlayOpacity: colorScheme == .light ? 0.0 : 0.05,
                lightShadowOpacity: 0.16,
                lightShadowRadius: 10,
                lightShadowYOffset: 3
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous)
                .fill(colorScheme == .light ? Color.white.opacity(0.08) : Color.clear)
        )
        #else
        .modifier(ClearGlassModifier(cornerRadius: rowCornerRadius))
        #endif
        .onAppear {
            // startPinging 内部已异步化（不会阻塞主线程）
            pingModel.startPinging()
        }
        .onDisappear {
            pingModel.stopPinging()
        }
    }
}

// MARK: - ViewModel for stable data lifecycle (fixes macOS sidebar rendering)
@MainActor
class FavouriteServerListViewModel: ObservableObject {
    @Published var servers: [MUFavouriteServer] = []
    
    func loadServers() {
        let result = MUDatabase.fetchVisibleFavourites()
        if let nsArray = result as NSArray? {
            var loaded = nsArray.compactMap { $0 as? MUFavouriteServer }

            // 修复历史/异常证书引用：归一化为 identity ref；若失效则按 user@host 自动重匹配
            var repaired = false
            for server in loaded {
                guard let certRef = server.certificateRef else { continue }

                let normalized = MUCertificateController.normalizedIdentityPersistentRef(forPersistentRef: certRef)
                if let normalized, normalized != certRef {
                    server.certificateRef = normalized
                    MUDatabase.storeFavourite(server)
                    repaired = true
                    continue
                }

                if normalized == nil,
                   let user = server.userName, !user.isEmpty,
                   let host = server.hostName {
                    let certName = "\(user)@\(host)"
                    if let rematched = CertificateModel.shared.findCertificateReference(name: certName) {
                        server.certificateRef = rematched
                        MUDatabase.storeFavourite(server)
                        repaired = true
                    }
                }
            }

            // 重新读取，确保 UI 与数据库持久化一致
            if repaired, let refreshed = MUDatabase.fetchVisibleFavourites() as? [MUFavouriteServer] {
                loaded = refreshed
            }

            let sorted = loaded.sorted {
                ($0.displayName ?? "").localizedCaseInsensitiveCompare($1.displayName ?? "") == .orderedAscending
            }
            MumbleLogger.database.debug("FavouriteServers: loaded \(sorted.count) visible servers from database")
            self.servers = sorted
        } else {
            MumbleLogger.database.warning("FavouriteServers: fetchVisibleFavourites returned nil")
            self.servers = []
        }
    }
}

struct FavouriteServerListContentView: View {
    var navigationManager: NavigationManager
    
    @Binding var serverToEdit: EditableServer?
    var refreshTrigger: UUID
    var dismissOnConnect: Bool

    @Environment(\.dismiss) private var dismiss
    
    @StateObject private var viewModel = FavouriteServerListViewModel()
    @State private var serverToDelete: MUFavouriteServer?
    @State private var showingDeleteAlert = false
    @State private var didRefreshCertificates = false
    
    private let successHaptic = PlatformNotificationFeedback()
    
    var body: some View {
        Group {
            if viewModel.servers.isEmpty {
                emptyStateView
            } else {
                serverListView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .task {
            MumbleLogger.ui.verbose("FavouriteServers: .task fired")
            viewModel.loadServers()
        }
        .onAppear {
            MumbleLogger.ui.verbose("FavouriteServers: .onAppear fired")
            viewModel.loadServers()
            if !didRefreshCertificates {
                didRefreshCertificates = true
                DispatchQueue.main.async {
                    CertificateModel.shared.refreshCertificates()
                }
            }
        }
        .onChange(of: refreshTrigger) { _, _ in
            viewModel.loadServers()
        }
        .alert("Delete Favourite", isPresented: $showingDeleteAlert, presenting: serverToDelete) { server in
            Button("Delete", role: .destructive) { deleteFavouriteServer(server) }
        } message: { server in
            Text("Are you sure you want to delete '\(server.displayName ?? NSLocalizedString("this server", comment: ""))'?")
        }
        .onReceive(NotificationCenter.default.publisher(for: .muAutomationOpenUI)) { notification in
            guard let target = notification.userInfo?["target"] as? String, target == "favouriteDelete" else { return }
            if let primaryKey = notification.userInfo?["primaryKey"] as? Int,
               let server = viewModel.servers.first(where: { $0.primaryKey == primaryKey }) {
                serverToDelete = server
                showingDeleteAlert = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .muAutomationDismissUI)) { notification in
            let target = notification.userInfo?["target"] as? String
            if target == nil || target == "favouriteDelete" {
                showingDeleteAlert = false
                serverToDelete = nil
            }
        }
        .onChange(of: showingDeleteAlert) { _, isPresented in
            if isPresented {
                AppState.shared.setAutomationPresentedAlert("favouriteDelete")
            } else if AppState.shared.automationPresentedAlert == "favouriteDelete" {
                AppState.shared.setAutomationPresentedAlert(nil)
            }
        }
    }
    
    @ViewBuilder
    private var serverListView: some View {
        #if os(macOS)
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(viewModel.servers, id: \.primaryKey) { server in
                    FavouriteServerRowView(server: server)
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
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                }
            }
        }
        .scrollContentBackground(.hidden)
        #else
        List {
            ForEach(viewModel.servers, id: \.primaryKey) { server in
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
    
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "heart.slash")
                .font(.system(size: 60, weight: .light))
                .foregroundColor(.secondary)
            Text("No Favourite Servers")
                .font(.title2)
                .foregroundColor(.primary)
            Text("Tap + to add a favourite server")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }.padding()
    }
    
    @MainActor
    private func connectToServer(_ server: MUFavouriteServer) {
        AppState.shared.serverDisplayName = server.displayName
        PlatformImpactFeedback(style: .medium).impactOccurred()
        
        MUConnectionController.shared()?.connect(
            toHostname: server.hostName,
            port: UInt(server.port),
            withUsername: server.userName,
            andPassword: server.password,
            certificateRef: server.certificateRef,
            displayName: server.displayName
        )

        if dismissOnConnect {
            dismiss()
        }
    }
    
    @MainActor
    private func deleteServers(offsets: IndexSet) {
        for index in offsets {
            deleteFavouriteServer(viewModel.servers[index])
        }
    }
    
    @MainActor
    private func deleteFavouriteServer(_ server: MUFavouriteServer) {
        // 如果该服务器已固定到 Widget，同时移除
        let widgetId = WidgetServerItem.makeId(
            hostname: server.hostName ?? "",
            port: Int(server.port),
            username: server.userName ?? ""
        )
        WidgetDataManager.shared.unpinServer(id: widgetId)

        // 现在统一使用真实删除，不再保留 hidden profile
        MUDatabase.deleteFavourite(server)
        MumbleLogger.database.info("Deleted favourite '\(server.displayName ?? "")'")
        viewModel.loadServers()
    }
    
    // MARK: - Widget Pin/Unpin
    
    private func isServerPinned(_ server: MUFavouriteServer) -> Bool {
        WidgetDataManager.shared.isPinned(
            hostname: server.hostName ?? "",
            port: Int(server.port),
            username: server.userName ?? ""
        )
    }
    
    @MainActor
    private func pinToWidget(_ server: MUFavouriteServer) {
        let item = WidgetServerItem(
            id: WidgetServerItem.makeId(
                hostname: server.hostName ?? "",
                port: Int(server.port),
                username: server.userName ?? ""
            ),
            displayName: server.displayName ?? server.hostName ?? NSLocalizedString("Unknown", comment: ""),
            hostname: server.hostName ?? "",
            port: Int(server.port),
            username: server.userName ?? "",
            hasCertificate: server.certificateRef != nil,
            lastConnected: nil
        )
        WidgetDataManager.shared.pinServer(item)
        
        PlatformNotificationFeedback().notificationOccurred(.success)
        withAnimation {
            AppState.shared.activeToast = AppToast(message: NSLocalizedString("Added to Widget", comment: ""), type: .success)
        }
    }
    
    @MainActor
    private func unpinFromWidget(_ server: MUFavouriteServer) {
        let id = WidgetServerItem.makeId(
            hostname: server.hostName ?? "",
            port: Int(server.port),
            username: server.userName ?? ""
        )
        WidgetDataManager.shared.unpinServer(id: id)
        
        withAnimation {
            AppState.shared.activeToast = AppToast(message: NSLocalizedString("Removed from Widget", comment: ""), type: .info)
        }
    }
    
    @MainActor
    private func editServer(_ server: MUFavouriteServer) {
        // 延迟 0.4s 等待 Menu 动画完全退出，避免 _UIReparentingView 冲突
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            serverToEdit = EditableServer(server)
        }
    }
}

struct FavouriteServerListView: MumbleContentView {
    @EnvironmentObject var navigationManager: NavigationManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appState = AppState.shared

    var isModalPresentation: Bool = false
    
    @State private var showingNewSheet = false
    @State private var serverToEdit: EditableServer?
    @State private var refreshTrigger = UUID()
    
    var navigationConfig: any NavigationConfigurable {
        FavouriteServerListNavigationConfig(onAdd: {
            showingNewSheet = true
        }, onClose: isModalPresentation ? { dismiss() } : nil)
    }
    var contentBody: some View {
        FavouriteServerListContentView(
            navigationManager: navigationManager,
            serverToEdit: $serverToEdit,
            refreshTrigger: refreshTrigger,
            dismissOnConnect: isModalPresentation
        )
        .onAppear {
            appState.setAutomationCurrentScreen("favouriteList")
        }
        .onReceive(NotificationCenter.default.publisher(for: .muAutomationOpenUI)) { notification in
            guard let target = notification.userInfo?["target"] as? String else { return }
            switch target {
            case "favouriteNew":
                showingNewSheet = true
            case "favouriteEdit":
                let primaryKey =
                    (notification.userInfo?["primaryKey"] as? NSNumber)?.intValue
                    ?? (notification.userInfo?["primaryKey"] as? Int)
                guard let primaryKey,
                      let server = (MUDatabase.fetchAllFavourites() as? [MUFavouriteServer])?.first(where: { $0.primaryKey == primaryKey }) else {
                    return
                }
                serverToEdit = EditableServer(server)
            default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .muAutomationDismissUI)) { notification in
            let target = notification.userInfo?["target"] as? String
            if target == nil || target == "favouriteNew" {
                showingNewSheet = false
            }
            if target == nil || target == "favouriteEdit" {
                serverToEdit = nil
            }
        }
        .onChange(of: showingNewSheet) { _, isPresented in
            if isPresented {
                appState.setAutomationPresentedSheet("favouriteNew")
            } else {
                appState.clearAutomationPresentedSheet(ifMatches: "favouriteNew")
            }
        }
        .onChange(of: serverToEdit?.id) { _, newValue in
            if newValue != nil {
                appState.setAutomationPresentedSheet("favouriteEdit")
            } else {
                appState.clearAutomationPresentedSheet(ifMatches: "favouriteEdit")
            }
        }
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
