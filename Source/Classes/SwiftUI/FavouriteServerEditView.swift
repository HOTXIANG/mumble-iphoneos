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
    
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject private var navigationManager: NavigationManager
    @ObservedObject private var certModel = CertificateModel.shared
    
    let server: MUFavouriteServer?
    let onSave: (MUFavouriteServer) -> Void
    private var isEditMode: Bool { server != nil }
    private var hasCertificateRecord: Bool { server?.certificateRef != nil }
    
    private var isLocked: Bool {
        guard let ref = server?.certificateRef else { return false }
        return certModel.isCertificateValid(ref)
    }
    
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
        Form {
            // 1. Server Details Section
            Section(header: Text("Server Details"), footer: detailsFooter) {
                // Description (始终可改)
                settingInputRow(
                    title: "Description",
                    placeholder: "Mumble Server",
                    text: $displayName,
                    isLocked: false
                )
                
                // Address (锁定逻辑)
                settingInputRow(
                    title: "Address",
                    placeholder: "Hostname or IP",
                    text: $hostName,
                    isLocked: isLocked,
                    lockedText: hostName,
                    isURLField: true
                )
                
                // Port (锁定逻辑)
                settingInputRow(
                    title: "Port",
                    placeholder: "64738",
                    text: $port,
                    isLocked: isLocked,
                    lockedText: port,
                    isNumberField: true
                )
            }
            
            // 2. Authentication Section
            Section(header: Text("Authentication"), footer: authFooter) {
                // Username (锁定逻辑)
                settingInputRow(
                    title: "Username",
                    placeholder: UserDefaults.standard.string(forKey: "DefaultUserName") ?? "User",
                    text: $userName,
                    isLocked: isLocked,
                    lockedText: userName,
                    isUsernameField: true
                )
                
                // Password (锁定逻辑)
                settingInputRow(
                    title: "Password",
                    placeholder: "Optional",
                    text: $password,
                    isLocked: isLocked,
                    lockedText: "••••••",
                    isSecure: true
                )
            }
            
            // 3. Status Section (显示证书状态)
            if hasCertificateRecord {
                Section {
                    if isLocked {
                        // 正常状态：绿色盾牌
                        HStack {
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundColor(.green)
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Registered Server")
                                    .font(.headline)
                                Text("This server profile is bound to a secure certificate. Core details are locked.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        // 异常状态：黄色盾牌
                        HStack {
                            Image(systemName: "exclamationmark.shield.fill")
                                .foregroundColor(.yellow)
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Certificate Missing")
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Text("The certificate bound to this server cannot be found. Authentication may fail, but you can now edit the server details.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        .controlSize(.regular)
        #endif
        .navigationTitle(isEditMode ? "Edit Favourite" : "New Favourite")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    saveServer()
                }
                .fontWeight(.semibold)
                .disabled(hostName.isEmpty)
            }
        }
        .onAppear {
            // 确保证书状态是最新的
            certModel.refreshCertificates()
        }
    }
    
    // MARK: - Helper Views

    @ViewBuilder
    private func settingInputRow(
        title: String,
        placeholder: String,
        text: Binding<String>,
        isLocked: Bool,
        lockedText: String? = nil,
        isSecure: Bool = false,
        isURLField: Bool = false,
        isNumberField: Bool = false,
        isUsernameField: Bool = false
    ) -> some View {
        #if os(macOS)
        LabeledContent {
            if isLocked {
                lockedField(text: lockedText ?? text.wrappedValue)
            } else {
                Group {
                    if isSecure {
                        SecureField("", text: text)
                    } else {
                        TextField("", text: text)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
            }
        } label: {
            Text("\(title)  (\(placeholder))")
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 1)
        #else
        HStack {
            Text(title)
                .foregroundColor(.primary)
            Spacer()
            if isLocked {
                lockedField(text: lockedText ?? text.wrappedValue)
            } else {
                Group {
                    if isSecure {
                        SecureField(placeholder, text: text)
                    } else {
                        TextField(placeholder, text: text)
                    }
                }
                .multilineTextAlignment(.trailing)
                #if os(iOS)
                .keyboardType(isURLField ? .URL : (isNumberField ? .numberPad : .default))
                .autocapitalization((isURLField || isUsernameField) ? .none : .sentences)
                #endif
                .autocorrectionDisabled(isURLField || isUsernameField)
                .foregroundColor(.secondary)
            }
        }
        #endif
    }
    
    private func lockedField(text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(text)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
    
    @ViewBuilder
    private var detailsFooter: some View {
        if isLocked {
            Text("Address and Port are locked because this server is registered with a secure certificate.")
        } else if hasCertificateRecord {
            Text("Fields are unlocked because the associated certificate is missing.")
        }
        // 如果都不满足，ViewBuilder 会自动返回 EmptyView
    }
    
    @ViewBuilder
    private var authFooter: some View {
        if isLocked {
            Text("Identity fields are locked to maintain certificate integrity.")
        } else if hasCertificateRecord {
            Text("You can update your username/password since the original certificate is lost.")
        }
    }
    
    // MARK: - Save Logic
    
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
        
        if serverToSave.certificateRef == nil, let user = serverToSave.userName, let host = serverToSave.hostName {
            let potentialCertName = "\(user)@\(host)" // e.g. "UserA@mumble.com" (这是之前生成证书时的命名规则)
            
            // 尝试在证书库里找找有没有同名的
            if let matchRef = CertificateModel.shared.findCertificateReference(name: potentialCertName) {
                print("♻️ Auto-matched existing certificate for \(potentialCertName)")
                serverToSave.certificateRef = matchRef
            }
        }
        
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
