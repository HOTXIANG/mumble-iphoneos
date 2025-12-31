//
//  FavouriteServerEditView.swift
//  Mumble
//
//  Created by 王梓田 on 2025/6/27.
//

import SwiftUI

struct FavouriteServerEditView: View {
    @State private var displayName: String
    @State private var hostName: String
    @State private var port: String
    @State private var userName: String
    @State private var password: String
    @EnvironmentObject private var navigationManager: NavigationManager
    
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
        // 使用原生 Form 替代自定义的 ZStack/VStack
        Form {
            Section(header: Text("Server Details")) {
                // Label + Input 的原生组合方式
                HStack {
                    Text("Description")
                        .foregroundColor(.primary)
                    Spacer()
                    TextField("Mumble Server", text: $displayName)
                        .multilineTextAlignment(.trailing) // 右对齐，符合 iOS 设置页风格
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("Address")
                        .foregroundColor(.primary)
                    Spacer()
                    TextField("Hostname or IP", text: $hostName)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled(true)
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("Port")
                        .foregroundColor(.primary)
                    Spacer()
                    TextField("64738", text: $port)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                        .foregroundColor(.secondary)
                }
            }
            
            Section(header: Text("Authentication")) {
                HStack {
                    Text("Username")
                        .foregroundColor(.primary)
                    Spacer()
                    TextField(UserDefaults.standard.string(forKey: "DefaultUserName") ?? "User", text: $userName)
                        .multilineTextAlignment(.trailing)
                        .autocapitalization(.none)
                        .autocorrectionDisabled(true)
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("Password")
                        .foregroundColor(.primary)
                    Spacer()
                    SecureField("Optional", text: $password)
                        .multilineTextAlignment(.trailing)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle(isEditMode ? "Edit Favourite" : "New Favourite")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") {
                    saveServer()
                }
                .fontWeight(.semibold)
                .disabled(hostName.isEmpty) // 地址为空时禁用保存
            }
        }
    }
    
    private func saveServer() {
        let serverToSave: MUFavouriteServer
        if let existingServer = server {
            serverToSave = existingServer.copy() as! MUFavouriteServer
        } else {
            serverToSave = MUFavouriteServer()
        }
        
        // 逻辑保持不变：如果显示名称为空，则使用主机名或默认值
        serverToSave.displayName = displayName.isEmpty ? (hostName.isEmpty ? "Mumble Server" : hostName) : displayName
        serverToSave.hostName = hostName
        serverToSave.port = UInt(port) ?? 64738
        serverToSave.userName = userName.isEmpty ? nil : userName
        serverToSave.password = password.isEmpty ? nil : password
        
        onSave(serverToSave)
    }
}

#Preview {
    NavigationStack {
        FavouriteServerEditView(server: nil) { server in
            print("Server saved: \(server.displayName ?? "")")
        }
    }
}
