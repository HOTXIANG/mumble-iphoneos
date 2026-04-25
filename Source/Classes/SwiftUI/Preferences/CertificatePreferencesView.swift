//
//  CertificatePreferencesView.swift
//  Mumble
//
//  Created by 王梓田 on 1/2/26.
//

import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct CertificatePreferencesView: View {
    @StateObject private var certModel = CertificateModel.shared
    
    // --- 状态变量声明 ---
    @State private var showingImportPicker = false
    
    // 导入相关
    @State private var showingImportPasswordAlert = false
    @State private var showingImportErrorAlert = false
    @State private var selectedFileForImport: URL?
    @State private var importPassword = ""
    
    // 导出相关
    @State private var certToExport: CertificateItem?
    @State private var exportPassword = ""
    @State private var showingExportPasswordAlert = false
    @State private var exportedFileURL: URL?
    @State private var showingShareSheet = false
    @State private var exportResultMessage: String = ""
    @State private var showingExportResultAlert = false
    
    // 删除相关
    @State private var certToDelete: CertificateItem?
    @State private var showingDeleteConfirmation = false
    
    var body: some View {
        certificateList
            .navigationTitle("Certificates")
            // --- 导入功能 ---
            #if os(iOS)
            .fileImporter(isPresented: $showingImportPicker, allowedContentTypes: [.pkcs12], allowsMultipleSelection: false, onCompletion: handleImportSelection)
            #endif
            .alert("Import Certificate", isPresented: $showingImportPasswordAlert, actions: {
                SecureField("Password", text: $importPassword)
                Button("Cancel", role: .cancel) {
                    InteractionFeedback.cancel()
                    #if os(iOS)
                    selectedFileForImport?.stopAccessingSecurityScopedResource()
                    #endif
                }
                Button("Import") {
                    performImport()
                }
            }, message: {
                Text("Enter the password for the .p12 file. Leave empty if none.")
            })
            .alert("Import Failed", isPresented: $showingImportErrorAlert, actions: {
                Button("OK", role: .cancel) { }
            }, message: {
                Text(certModel.importError ?? NSLocalizedString("Invalid password or corrupted file.", comment: ""))
            })
            // --- 导出功能 ---
            .alert("Export Certificate", isPresented: $showingExportPasswordAlert, actions: {
                SecureField("Password", text: $exportPassword)
                Button("Cancel", role: .cancel) {
                    InteractionFeedback.cancel()
                }
                Button("Export") {
                    performExport()
                }
            }, message: {
                Text("Set a password to protect the exported .p12 file.")
            })
            .alert("Export Result", isPresented: $showingExportResultAlert, actions: {
                Button("OK", role: .cancel) {}
            }, message: {
                Text(exportResultMessage)
            })
            .sheet(isPresented: $showingShareSheet) {
                #if os(iOS)
                if let url = exportedFileURL {
                    ShareSheet(activityItems: [url])
                }
                #else
                Text("Sharing not available on macOS")
                #endif
            }
            // --- 删除功能 ---
            .alert("Delete Certificate?", isPresented: $showingDeleteConfirmation, presenting: certToDelete, actions: { cert in
                Button("Delete", role: .destructive) {
                    certModel.deleteCertificate(cert)
                }
                Button("Cancel", role: .cancel) {
                    InteractionFeedback.cancel()
                }
            }, message: { cert in
                Text(
                    String(
                        format: NSLocalizedString(
                            "Warning: If you do not have a backup of '%@', you may permanently lose access to servers and usernames registered with this identity.\\n\\nAre you sure you want to delete it?",
                            comment: ""
                        ),
                        cert.name
                    )
                )
            })
            .onAppear {
                AppState.shared.setAutomationCurrentScreen("certificateSettings")
                certModel.refreshCertificates()
            }
            .onReceive(NotificationCenter.default.publisher(for: .muAutomationOpenUI)) { notification in
                guard let target = notification.userInfo?["target"] as? String else { return }
                switch target {
                case "certificateDelete":
                    if let cert = automationCertificate(from: notification.userInfo) {
                        prepareDelete(cert)
                    }
                case "certificateExportPassword":
                    if let cert = automationCertificate(from: notification.userInfo) {
                        prepareExport(cert)
                    }
                default:
                    break
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .muAutomationDismissUI)) { notification in
                let target = notification.userInfo?["target"] as? String
                switch target {
                case nil:
                    showingImportPasswordAlert = false
                    showingImportErrorAlert = false
                    showingExportPasswordAlert = false
                    showingExportResultAlert = false
                    showingShareSheet = false
                    showingDeleteConfirmation = false
                case "certificateImportPassword":
                    showingImportPasswordAlert = false
                case "certificateImportError":
                    showingImportErrorAlert = false
                case "certificateExportPassword":
                    showingExportPasswordAlert = false
                case "certificateExportResult":
                    showingExportResultAlert = false
                case "certificateExportShare":
                    showingShareSheet = false
                case "certificateDelete":
                    showingDeleteConfirmation = false
                default:
                    break
                }
            }
            .onChange(of: showingImportPasswordAlert) { _, _ in syncAutomationAlertState() }
            .onChange(of: showingImportErrorAlert) { _, _ in syncAutomationAlertState() }
            .onChange(of: showingExportPasswordAlert) { _, _ in syncAutomationAlertState() }
            .onChange(of: showingExportResultAlert) { _, _ in syncAutomationAlertState() }
            .onChange(of: showingDeleteConfirmation) { _, _ in syncAutomationAlertState() }
            .onChange(of: showingShareSheet) { _, isPresented in
                if isPresented {
                    AppState.shared.setAutomationPresentedSheet("certificateExportShare")
                } else {
                    AppState.shared.clearAutomationPresentedSheet(ifMatches: "certificateExportShare")
                }
            }
    }
    
    // MARK: - Subviews

    @ViewBuilder
    private var certificateContent: some View {
        Section(header: Text("Saved Identities"), footer: footerText) {
            if certModel.certificates.isEmpty {
                Text("No certificates found.")
                    .foregroundColor(.secondary)
                    .padding(.vertical)
            } else {
                #if os(macOS)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(certModel.certificates) { cert in
                            CertificateRow(cert: cert)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contextMenu {
                                    Button {
                                        prepareExport(cert)
                                    } label: {
                                        Label("Export .p12", systemImage: "square.and.arrow.up")
                                    }
                                    
                                    Button(role: .destructive) {
                                        prepareDelete(cert)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
                .frame(minHeight: 180, maxHeight: 340)
                #else
                ForEach(certModel.certificates) { cert in
                    CertificateRow(cert: cert)
                        .contextMenu {
                            Button {
                                prepareExport(cert)
                            } label: {
                                Label("Export .p12", systemImage: "square.and.arrow.up")
                            }
                            
                            Button(role: .destructive) {
                                prepareDelete(cert)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
                #endif
            }
            
            Button(action: triggerImport) {
                Label("Import Certificate", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .center)
                    .foregroundColor(.white)
            }
            .buttonStyle(.borderedProminent)
            .padding(.vertical, 6)
        }
    }
    
    private var certificateList: some View {
        Group {
            #if os(macOS)
            Form {
                certificateContent
            }
            #else
            List {
                certificateContent
            }
            #endif
        }
    }
    
    private var footerText: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Identities are .p12 certificates used for server authentication.")
            
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "hand.tap.fill")
                    .font(.caption)
                #if os(macOS)
                Text("Right-click a certificate to Export or Delete.")
                #else
                Text("Long press on a certificate to Export or Delete.")
                #endif
            }
            .foregroundColor(.secondary)
            .font(.caption)
        }
        .padding(.top, 8)
    }
    
    // MARK: - Actions
    
    private func handleImportSelection(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let url = urls.first {
                if url.startAccessingSecurityScopedResource() {
                    self.selectedFileForImport = url
                    self.importPassword = ""
                    self.showingImportPasswordAlert = true
                }
            }
        case .failure(let error):
            MumbleLogger.certificate.error("Import picker failed: \(error.localizedDescription)")
        }
    }
    
    private func performImport() {
        if let url = selectedFileForImport {
            let success = certModel.importCertificate(from: url, password: importPassword)
            #if os(iOS)
            url.stopAccessingSecurityScopedResource()
            #endif
            
            if !success {
                // 延迟显示错误，避免 Alert 冲突
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.showingImportErrorAlert = true
                }
            }
        }
    }
    
    private func prepareExport(_ cert: CertificateItem) {
        self.certToExport = cert
        self.exportPassword = ""
        self.showingExportPasswordAlert = true
    }
    
    private func performExport() {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.performExport()
            }
            return
        }

        guard let cert = certToExport else { return }

        guard let tempURL = certModel.exportCertificate(cert, password: exportPassword) else {
            MumbleLogger.certificate.error("Export failed: unable to generate PKCS12 for \(cert.name)")
            exportResultMessage = "Failed to export certificate. Please verify this identity still contains a valid private key."
            showingExportResultAlert = true
            return
        }

        #if os(macOS)
        do {
            let savePanel = NSSavePanel()
            savePanel.canCreateDirectories = true
            savePanel.allowedContentTypes = [.pkcs12]
            savePanel.nameFieldStringValue = cert.name.replacingOccurrences(of: "/", with: "_") + ".p12"
            savePanel.title = "Export Certificate"
            savePanel.message = "Choose where to save the exported .p12 file."

            let response = savePanel.runModal()
            guard response == .OK, let destinationURL = savePanel.url else {
                MumbleLogger.certificate.info("Export cancelled by user for \(cert.name)")
                try? FileManager.default.removeItem(at: tempURL)
                return
            }

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: tempURL, to: destinationURL)

            MumbleLogger.certificate.info("Export succeeded: \(destinationURL.path)")
            exportResultMessage = "Certificate exported to:\n\(destinationURL.path)"
            showingExportResultAlert = true
        } catch {
            MumbleLogger.certificate.error("Export save failed: \(error.localizedDescription)")
            exportResultMessage = "Failed to save exported file:\n\(error.localizedDescription)"
            showingExportResultAlert = true
        }
        #else
        self.exportedFileURL = tempURL
        self.showingShareSheet = true
        #endif
        
        do {
            try FileManager.default.removeItem(at: tempURL)
        } catch {
            MumbleLogger.certificate.warning("Failed to remove temporary export file: \(error.localizedDescription)")
        }
    }

    #if os(macOS)
    private func openImportPanelMacOS() {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.openImportPanelMacOS()
            }
            return
        }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pkcs12]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Import Certificate"
        panel.message = "Choose a .p12 certificate file to import."

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            MumbleLogger.certificate.info("Import cancelled by user")
            return
        }

        self.selectedFileForImport = url
        self.importPassword = ""
        self.showingImportPasswordAlert = true
    }
    #endif
    
    private func prepareDelete(_ cert: CertificateItem) {
        self.certToDelete = cert
        self.showingDeleteConfirmation = true
    }
    
    private func triggerImport() {
        #if os(macOS)
        openImportPanelMacOS()
        #else
        showingImportPicker = true
        #endif
    }

    private func automationCertificate(from userInfo: [AnyHashable: Any]?) -> CertificateItem? {
        if let id = userInfo?["id"] as? Data,
           let cert = certModel.certificates.first(where: { $0.id == id }) {
            return cert
        }
        if let name = userInfo?["name"] as? String,
           let cert = certModel.certificates.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return cert
        }
        return nil
    }

    private func syncAutomationAlertState() {
        if showingDeleteConfirmation {
            AppState.shared.setAutomationPresentedAlert("certificateDelete")
        } else if showingExportResultAlert {
            AppState.shared.setAutomationPresentedAlert("certificateExportResult")
        } else if showingExportPasswordAlert {
            AppState.shared.setAutomationPresentedAlert("certificateExportPassword")
        } else if showingImportErrorAlert {
            AppState.shared.setAutomationPresentedAlert("certificateImportError")
        } else if showingImportPasswordAlert {
            AppState.shared.setAutomationPresentedAlert("certificateImportPassword")
        } else if ["certificateDelete", "certificateExportResult", "certificateExportPassword", "certificateImportError", "certificateImportPassword"].contains(AppState.shared.automationPresentedAlert ?? "") {
            AppState.shared.setAutomationPresentedAlert(nil)
        }
    }
}

// --- Helper Views ---

struct CertificateRow: View {
    let cert: CertificateItem
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "person.text.rectangle.fill")
                    .foregroundColor(.green)
                Text(cert.name)
                    .font(.headline)
            }
            
            Text("SHA1: \(cert.hash)")
                .font(.caption)
                .foregroundColor(.secondary)
                .monospaced()
            
            if let date = cert.expiry {
                Text("Expires: \(date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

#if os(iOS)
struct ShareSheet: UIViewControllerRepresentable {
    var activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

extension UTType {
    static var pkcs12: UTType {
        UTType(filenameExtension: "p12") ?? .data
    }
}
