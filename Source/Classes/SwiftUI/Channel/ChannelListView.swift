// 文件: ChannelListView.swift (已更新“更多”选项样式)

import SwiftUI

struct ChannelListView: View {
    @StateObject private var serverManager = ServerModelManager()
    @State private var showingMenu = false
    
    // --- 核心修改 1：注入 NavigationManager ---
    @EnvironmentObject var navigationManager: NavigationManager
        
    // --- 核心修改 2：创建一个触感反馈生成器 ---
    private let hapticGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let notificationHaptic = UINotificationFeedbackGenerator()

    var body: some View {
        ZStack {
            // 背景由其子视图 ChannelView 提供
            ChannelView(serverManager: serverManager)
        }
        .navigationBarBackButtonHidden(true)
        .navigationTitle(Text(serverManager.serverName ?? "Channel"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 左上角按钮组
            ToolbarItemGroup(placement: .navigationBarLeading) {
                HStack(spacing: 16) {
                    // Self-Deafen 按钮
                    Button(action: {
                        hapticGenerator.impactOccurred()
                        serverManager.toggleSelfDeafen()
                    }) {
                        Image(systemName: serverManager.connectedUserState?.isSelfDeafened == true ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .foregroundColor(serverManager.connectedUserState?.isSelfDeafened == true ? .red : .primary)
                    }

                    // Self-Mute 按钮
                    Button(action: {
                        hapticGenerator.impactOccurred()
                        serverManager.toggleSelfMute()
                    }) {
                        Image(systemName: serverManager.connectedUserState?.isSelfMuted == true ? "mic.slash.fill" : "mic.fill")
                            .foregroundColor(serverManager.connectedUserState?.isSelfMuted == true ? .orange : .primary)
                    }
                }
                .tint(.primary)
            }

            // 右上角按钮组
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    // “更多”菜单按钮 - 保留图标样式
                    Button(action: {
                        hapticGenerator.impactOccurred()
                        showingMenu = true
                    }) {
                        Image(systemName: "ellipsis")
                    }

                    // “离开”按钮
                    Button(action: {
                        hapticGenerator.impactOccurred()
                        initiateDisconnect()
                    }) {
                        Image(systemName: "phone.down.fill")
                            .foregroundColor(.red) // 使用红色以示警告
                    }
                }
                .tint(.primary)
            }
        }
        .confirmationDialog("Server Menu", isPresented: $showingMenu, titleVisibility: .visible) {
            serverMenuButtons()
        }
    }

    @ViewBuilder private func serverMenuButtons() -> some View {
        Button("Switch View Mode") { serverManager.toggleMode() }; Divider()
        Button("Settings", systemImage: "gearshape") { navigationManager.navigate(to: .objectiveC(.preferences ))}; Divider()
        Button("Access Tokens") { /* TODO */ }; Button("Certificates") { /* TODO */ }; Divider()
        Button("Cancel", role: .cancel) {}
    }

    @State private var disconnectObserver: Any?; private func initiateDisconnect() {
        guard disconnectObserver == nil else { print("🟡 Disconnect sequence already in progress."); return }
        notificationHaptic.prepare()
        notificationHaptic.notificationOccurred(.warning)
        print("🟡 Initiating disconnect sequence...")
        disconnectObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name("MUConnectionClosedNotification"), object: nil, queue: .main) { [self] _ in
            Task { @MainActor in
                print("✅ Disconnection confirmed by notification.")
                withAnimation(.spring()) { AppState.shared.isConnected = false }
                if let observer = self.disconnectObserver { NotificationCenter.default.removeObserver(observer); self.disconnectObserver = nil }
            }
        }
        MUConnectionController.shared()?.disconnectFromServer()
    }
}
