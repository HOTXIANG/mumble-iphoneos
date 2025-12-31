// 文件: ChannelListView.swift (已更新“更多”选项样式)

import SwiftUI

struct ChannelListView: View {
    @StateObject private var serverManager = ServerModelManager()
    @State private var showingPrefs = false
    
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
        .toolbarBackground(.hidden, for: .navigationBar)
        .background(Color.clear)
        .toolbar {
            // 左上角按钮组
            ToolbarItemGroup(placement: .navigationBarLeading) {
                HStack(alignment: .center, spacing: 0) {
                    // Self-Deafen 按钮
                    Button(action: {
                        hapticGenerator.impactOccurred()
                        serverManager.toggleSelfDeafen()
                    }) {
                        ZStack {
                            Image(systemName: serverManager.connectedUserState?.isSelfDeafened == true ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .resizable() // 允许调整大小
                                .aspectRatio(contentMode: .fit) // 保持比例
                                .frame(width: 24, height: 24) // 强制固定图标渲染尺寸
                                .foregroundColor(serverManager.connectedUserState?.isSelfDeafened == true ? .red : .primary)
                        }
                        .frame(width: 40, height: 44) // 增大点击热区，并固定整个按钮容器的宽度
                        .contentShape(Rectangle()) // 确保点击区域填满 40x44
                    }
                    // Self-Mute 按钮
                    Button(action: {
                        hapticGenerator.impactOccurred()
                        serverManager.toggleSelfMute()
                    }) {
                        ZStack {
                            Image(systemName: serverManager.connectedUserState?.isSelfMuted == true ? "mic.slash.fill" : "mic.fill")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 24, height: 24)
                                .foregroundColor(serverManager.connectedUserState?.isSelfMuted == true ? .orange : .primary)
                        }
                        .frame(width: 40, height: 44) // 同样的固定容器宽度
                        .contentShape(Rectangle())
                    }
                }
                .tint(.primary)
            }

            // 右上角按钮组
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                HStack(alignment: .center, spacing: 16) {
                    // “更多”菜单按钮 - 保留图标样式
                    Menu {
                        // 1. 切换视图模式
                        Button(action: {
                            serverManager.toggleMode()
                        }) {
                            Label("Switch View Mode", systemImage: "arrow.left.arrow.right")
                        }
                                            
                        Divider()
                                            
                        // 2. 设置
                        Button(action: {
                            showingPrefs = true
                        }) {
                            Label("Settings", systemImage: "gearshape")
                        }
                                            
                        Divider()
                                            
                        // 3. 其他功能占位
                        Button(action: { /* TODO */ }) {
                            Label("Access Tokens", systemImage: "key")
                        }
                                            
                        Button(action: { /* TODO */ }) {
                            Label("Certificates", systemImage: "lock.shield")
                        }
                                            
                    } label: {
                        // 菜单的触发图标
                        Image(systemName: "ellipsis")
                            .frame(width: 30, height: 30) // 增加一点点击热区
                            .contentShape(Rectangle())
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
                .padding(.horizontal,8)
            }
        }
        .background(Color.clear)
        .sheet(isPresented: $showingPrefs) {
            NavigationStack {
                PreferencesView()
            }
        }
    }

    @ViewBuilder private func serverMenuButtons() -> some View {
        Button("Switch View Mode") { serverManager.toggleMode() }; Divider()
        Button("Settings", systemImage: "gearshape") {
                showingPrefs = true
        };Divider()
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
