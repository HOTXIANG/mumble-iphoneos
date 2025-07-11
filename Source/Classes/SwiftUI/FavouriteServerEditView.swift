//
//  FavouriteServerEditView.swift
//  Mumble
//
//  Created by 王梓田 on 2025/6/27.
//

import SwiftUI
import UIKit

struct FavouriteServerEditView: View {
    // --- State and Environment properties remain the same ---
    @State private var displayName: String
    @State private var hostName: String
    @State private var port: String
    @State private var userName: String
    @State private var password: String
    @EnvironmentObject private var navigationManager: NavigationManager
    
    // --- Initializer remains the same ---
    let server: MUFavouriteServer?
    let onSave: (MUFavouriteServer) -> Void
    private var isEditMode: Bool { server != nil }
    
    init(server: MUFavouriteServer?, onSave: @escaping (MUFavouriteServer) -> Void) {
        self.server = server
        self.onSave = onSave
        _displayName = State(initialValue: server?.displayName ?? "")
        _hostName = State(initialValue: server?.hostName ?? "")
        let portValue = server?.port ?? 0
        _port = State(initialValue: portValue == 0 ? "" : "\(portValue)")
        _userName = State(initialValue: server?.userName ?? "")
        _password = State(initialValue: server?.password ?? "")
    }
    
    var body: some View {
        ZStack {
            // 统一的渐变背景
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.20, green: 0.20, blue: 0.20),
                    Color(red: 0.10, green: 0.10, blue: 0.10)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(.all)
            
            // --- 布局修改：使用 VStack 替代 Form，以获得更多自定义控制 ---
            ScrollView {
                VStack(spacing: 16) {
                    // 将每个表单行放入一个带 Material 背景的容器中
                    VStack {
                        FormRowView(title: "Description") {
                            TextField("Mumble Server", text: $displayName)
                                .textFieldStyle(CustomTextFieldStyle())
                        }
                        Divider().background(Color.white.opacity(0.2)).padding(.leading, 100)
                        FormRowView(title: "Address") {
                            TextField("Hostname or IP", text: $hostName)
                                .textFieldStyle(CustomTextFieldStyle())
                                .keyboardType(.URL)
                                .autocapitalization(.none)
                                .autocorrectionDisabled(true)
                        }
                        Divider().background(Color.white.opacity(0.2)).padding(.leading, 100)
                        FormRowView(title: "Port") {
                            TextField("64738", text: $port)
                                .textFieldStyle(CustomTextFieldStyle())
                                .keyboardType(.numberPad)
                        }
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    
                    VStack {
                        FormRowView(title: "Username") {
                            TextField(UserDefaults.standard.string(forKey: "DefaultUserName") ?? "User", text: $userName)
                                .textFieldStyle(CustomTextFieldStyle())
                                .autocapitalization(.none)
                                .autocorrectionDisabled(true)
                        }
                        Divider().background(Color.white.opacity(0.2)).padding(.leading, 100)
                        FormRowView(title: "Password") {
                            SecureField("Optional", text: $password)
                                .textFieldStyle(CustomTextFieldStyle())
                        }
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .padding()
            }
        }
        .navigationTitle(isEditMode ? "Edit Favourite" : "New Favourite")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar) // 保持导航栏透明
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") {
                    saveServer()
                }
                .foregroundStyle(.primary)
                .fontWeight(.semibold)
                .disabled(hostName.isEmpty) // 当地址为空时禁用完成按钮
            }
        }
    }
    
    private func saveServer() {
        // ... (saveServer 函数逻辑保持不变)
        let serverToSave: MUFavouriteServer
        if let existingServer = server {
            serverToSave = existingServer.copy() as! MUFavouriteServer
        } else {
            serverToSave = MUFavouriteServer()
        }
        serverToSave.displayName = displayName.isEmpty ? (hostName.isEmpty ? "Mumble Server" : hostName) : displayName
        serverToSave.hostName = hostName
        serverToSave.port = UInt(port) ?? 64738
        serverToSave.userName = userName.isEmpty ? nil : userName
        serverToSave.password = password.isEmpty ? nil : password
        onSave(serverToSave)
    }
}

// 表单行视图 (微调)
struct FormRowView<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(NSLocalizedString(title, comment: ""))
                .foregroundStyle(.secondary)
                .font(.system(size: 17))
                .frame(width: 100, alignment: .trailing)
            
            content()
        }
        .frame(minHeight: 44)
    }
}

// --- 核心修改：升级输入框样式 ---
struct CustomTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .foregroundStyle(.primary)
            .font(.system(size: 17))
            // 移除独立的背景，使其与外部容器融合
            .padding(.vertical, 4)
            .multilineTextAlignment(.leading)
    }
}

#Preview {
    NavigationStack {
        // For preview, we need to provide a dummy onSave closure
        FavouriteServerEditView(server: nil) { server in
            print("Server saved: \(server.displayName ?? "")")
        }
        .environmentObject(NavigationManager())
    }
}
