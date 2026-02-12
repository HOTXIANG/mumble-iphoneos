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
            .toolbar { toolbarContent }
            // --- 导入功能 ---
            #if os(iOS)
            .fileImporter(isPresented: $showingImportPicker, allowedContentTypes: [.pkcs12], allowsMultipleSelection: false, onCompletion: handleImportSelection)
            #endif
            .alert("Import Certificate", isPresented: $showingImportPasswordAlert, actions: {
                SecureField("Password", text: $importPassword)
                Button("Cancel", role: .cancel) {
                    #if os(iOS)
                    selectedFileForImport?.stopAccessingSecurityScopedResource()
                    #endif
                }
                Button("Import") {
                    performImport()
                }
            }, message: {
                Text("Enter the password for the .p12 file.")
            })
            .alert("Import Failed", isPresented: $showingImportErrorAlert, actions: {
                Button("OK", role: .cancel) { }
            }, message: {
                Text(certModel.importError ?? "Invalid password or corrupted file.")
            })
            // --- 导出功能 ---
            .alert("Export Certificate", isPresented: $showingExportPasswordAlert, actions: {
                SecureField("Password", text: $exportPassword)
                Button("Cancel", role: .cancel) {}
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
                Button("Cancel", role: .cancel) { }
            }, message: { cert in
                Text("Warning: If you do not have a backup of '\(cert.name)', you may permanently lose access to servers and usernames registered with this identity.\n\nAre you sure you want to delete it?")
            })
            .onAppear {
                certModel.refreshCertificates()
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
            }
        }
    }
    
    private var certificateList: some View {
        Group {
            #if os(macOS)
            Form {
                certificateContent
            }
            .formStyle(.grouped)
            #else
            List {
                certificateContent
            }
            #endif
        }
    }
    
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Button(action: {
                #if os(macOS)
                openImportPanelMacOS()
                #else
                showingImportPicker = true
                #endif
            }) {
                Label("Import", systemImage: "square.and.arrow.down")
            }
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
            .foregroundColor(.gray)
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
            print("Import picker failed: \(error.localizedDescription)")
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
            print("❌ Export failed: unable to generate PKCS12 for \(cert.name)")
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
                print("ℹ️ Export cancelled by user for \(cert.name)")
                try? FileManager.default.removeItem(at: tempURL)
                return
            }

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: tempURL, to: destinationURL)

            print("✅ Export succeeded: \(destinationURL.path)")
            exportResultMessage = "Certificate exported to:\n\(destinationURL.path)"
            showingExportResultAlert = true
        } catch {
            print("❌ Export save failed: \(error.localizedDescription)")
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
            print("ℹ️ Failed to remove temporary export file: \(error.localizedDescription)")
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
            print("ℹ️ Import cancelled by user")
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
                    .foregroundColor(.gray)
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
