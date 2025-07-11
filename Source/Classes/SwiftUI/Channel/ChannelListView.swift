// 文件: ChannelListView.swift (已更新“更多”选项样式)

import SwiftUI

struct ChannelListView: View {
    @StateObject private var serverManager = ServerModelManager()
    @State private var showingMenu = false

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
                    Button(action: { serverManager.toggleSelfDeafen() }) {
                        Image(systemName: serverManager.connectedUserState?.isSelfDeafened == true ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .foregroundColor(serverManager.connectedUserState?.isSelfDeafened == true ? .red : .primary)
                    }

                    // Self-Mute 按钮
                    Button(action: { serverManager.toggleSelfMute() }) {
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
                    Button(action: { showingMenu = true }) {
                        Image(systemName: "ellipsis")
                    }

                    // “离开”按钮
                    Button(action: { initiateDisconnect() }) {
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
        Button("Access Tokens") { /* TODO */ }; Button("Certificates") { /* TODO */ }; Divider()
        Button("Cancel", role: .cancel) {}
    }

    @State private var disconnectObserver: Any?; private func initiateDisconnect() {
        guard disconnectObserver == nil else { print("🟡 Disconnect sequence already in progress."); return }
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
