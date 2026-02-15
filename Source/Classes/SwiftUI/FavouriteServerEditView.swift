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
    @State private var selectedCertificateTag: String
    @State private var didEditCertificateSelection: Bool
    @State private var suppressCertificateSelectionTracking: Bool
    
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
        let normalizedRef: Data? = {
            guard let ref = server?.certificateRef else { return nil }
            return MUCertificateController.normalizedIdentityPersistentRef(forPersistentRef: ref) ?? ref
        }()
        _selectedCertificateTag = State(initialValue: normalizedRef?.base64EncodedString() ?? "")
        _didEditCertificateSelection = State(initialValue: false)
        _suppressCertificateSelectionTracking = State(initialValue: false)
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

            Section(header: Text("Certificate"), footer: certificateFooter) {
                LabeledContent("Bound Certificate") {
                    Menu {
                        Button {
                            selectedCertificateTag = ""
                        } label: {
                            HStack {
                                Text("None")
                                if selectedCertificateTag.isEmpty {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }

                        if !sortedCertificates.isEmpty || (!selectedCertificateTag.isEmpty && !selectedCertificateExists) {
                            Divider()
                        }

                        if !selectedCertificateTag.isEmpty, !selectedCertificateExists {
                            Button {
                                // 当前绑定存在但无法在列表中解析时，允许保留该值
                            } label: {
                                HStack {
                                    Text("Missing bound certificate")
                                    Image(systemName: "checkmark")
                                }
                            }
                        }

                        ForEach(sortedCertificates, id: \.id) { cert in
                            let tag = cert.id.base64EncodedString()
                            Button {
                                selectedCertificateTag = tag
                            } label: {
                                HStack {
                                    Text(fullCertificateLabel(for: cert))
                                    if selectedCertificateTag == tag {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        #if os(iOS)
                        HStack(spacing: 6) {
                            Text(boundCertificateCompactLabel)
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(.secondary)
                        #else
                        Text(boundCertificateCompactLabel)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        #endif
                    }
                }
                .onChange(of: selectedCertificateTag) { _ in
                    if suppressCertificateSelectionTracking {
                        suppressCertificateSelectionTracking = false
                        return
                    }
                    didEditCertificateSelection = true
                }
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
            reconcileSelectedCertificateTagIfNeeded()
        }
        .onChange(of: certModel.certificates) { _ in
            reconcileSelectedCertificateTagIfNeeded()
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

    @ViewBuilder
    private var certificateFooter: some View {
        Text("You can manually bind a certificate for this profile. The selected certificate will be used when connecting from Favourite Servers.")
    }

    private var sortedCertificates: [CertificateItem] {
        certModel.certificates.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var selectedCertificateRef: Data? {
        guard !selectedCertificateTag.isEmpty else { return nil }
        return Data(base64Encoded: selectedCertificateTag)
    }

    private var canonicalSelectedCertificateRef: Data? {
        guard let selected = selectedCertificateRef else { return nil }
        return MUCertificateController.normalizedIdentityPersistentRef(forPersistentRef: selected) ?? selected
    }

    private var selectedCertificateExists: Bool {
        guard let selected = selectedCertificateRef else { return true }
        if certModel.certificates.contains(where: { $0.id == selected }) {
            return true
        }
        guard let selectedHash = certificateHash(forPersistentRef: selected) else {
            return false
        }
        return certModel.certificates.contains(where: { normalizedHash($0.hash) == selectedHash })
    }

    private func fullCertificateLabel(for cert: CertificateItem) -> String {
        let parsed = parseCertificateCommonName(cert.name)
        let user = parsed.user
        let host = parsed.host ?? currentServerHostForDisplay
        return "\(user) @ \(host):\(currentServerPortForDisplay)"
    }

    private var boundCertificateCompactLabel: String {
        guard let selected = selectedCertificateRef else { return "None" }

        if let exact = certModel.certificates.first(where: { $0.id == selected }) {
            return compactUserName(fromCertificateName: exact.name)
        }

        if let normalized = MUCertificateController.normalizedIdentityPersistentRef(forPersistentRef: selected),
           let exact = certModel.certificates.first(where: { $0.id == normalized }) {
            return compactUserName(fromCertificateName: exact.name)
        }

        if let cert = MUCertificateController.certificate(withPersistentRef: selected),
           let name = cert.commonName(), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return compactUserName(fromCertificateName: name)
        }

        return "Missing"
    }

    private func compactUserName(fromCertificateName raw: String) -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Unknown" }
        if let at = name.firstIndex(of: "@"), at > name.startIndex {
            return String(name[..<at])
        }
        return name
    }

    private func parseCertificateCommonName(_ raw: String) -> (user: String, host: String?) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return ("Unknown", nil)
        }
        if let at = name.firstIndex(of: "@"), at > name.startIndex {
            let user = String(name[..<at]).trimmingCharacters(in: .whitespacesAndNewlines)
            let hostPart = String(name[name.index(after: at)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let host = hostPart.isEmpty ? nil : hostPart
            return (user.isEmpty ? "Unknown" : user, host)
        }
        return (name, nil)
    }

    private var currentServerHostForDisplay: String {
        let host = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !host.isEmpty { return host }
        let fallback = server?.hostName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fallback.isEmpty ? "Unknown" : fallback
    }

    private var currentServerPortForDisplay: UInt {
        if let p = UInt(port.trimmingCharacters(in: .whitespacesAndNewlines)), p > 0 {
            return p
        }
        if let fallback = server?.port, fallback > 0 {
            return fallback
        }
        return 64738
    }

    private func normalizedHash(_ digest: String) -> String {
        digest.replacingOccurrences(of: ":", with: "").uppercased()
    }

    private func certificateHash(forPersistentRef ref: Data) -> String? {
        guard let cert = MUCertificateController.certificate(withPersistentRef: ref),
              let digest = cert.hexDigest() else {
            return nil
        }
        return normalizedHash(digest)
    }

    private func reconcileSelectedCertificateTagIfNeeded() {
        guard let selected = selectedCertificateRef else { return }

        if certModel.certificates.contains(where: { $0.id == selected }) {
            return
        }

        if let normalized = MUCertificateController.normalizedIdentityPersistentRef(forPersistentRef: selected),
           let exact = certModel.certificates.first(where: { $0.id == normalized }) {
            suppressCertificateSelectionTracking = true
            selectedCertificateTag = exact.id.base64EncodedString()
            return
        }

        guard let selectedHash = certificateHash(forPersistentRef: selected),
              let matchedByHash = certModel.certificates.first(where: { normalizedHash($0.hash) == selectedHash }) else {
            return
        }
        suppressCertificateSelectionTracking = true
        selectedCertificateTag = matchedByHash.id.base64EncodedString()
    }
    
    // MARK: - Save Logic
    
    private func saveServer() {
        let finalPort = UInt(port) ?? 64738
        let finalUserName: String? = userName.isEmpty ? nil : userName
        let finalPassword: String? = password.isEmpty ? nil : password
        let finalDisplayName = displayName.isEmpty ? (hostName.isEmpty ? "Mumble Server" : hostName) : displayName
        
        let serverToSave: MUFavouriteServer
        if let existingServer = server {
            serverToSave = existingServer.copy() as! MUFavouriteServer
        } else {
            serverToSave = MUFavouriteServer()
        }
        
        serverToSave.displayName = finalDisplayName
        serverToSave.hostName = hostName
        serverToSave.port = finalPort
        serverToSave.userName = finalUserName
        serverToSave.password = finalPassword

        if didEditCertificateSelection {
            serverToSave.certificateRef = canonicalSelectedCertificateRef
        } else if !selectedCertificateTag.isEmpty {
            // 保留原有绑定（包含暂时找不到的证书 ref）
            serverToSave.certificateRef = canonicalSelectedCertificateRef
        } else {
            serverToSave.certificateRef = nil
        }

        if !didEditCertificateSelection,
           serverToSave.certificateRef == nil,
           let user = serverToSave.userName,
           let host = serverToSave.hostName {
            // 确保证书列表是最新的
            certModel.refreshCertificates()
            
            let potentialCertName = "\(user)@\(host)"
            
            // 尝试在证书库里找找有没有同名的（大小写不敏感）
            if let matchRef = certModel.findCertificateReference(name: potentialCertName) {
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
