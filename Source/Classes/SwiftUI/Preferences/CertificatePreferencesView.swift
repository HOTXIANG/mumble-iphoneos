//
//  CertificatePreferencesView.swift
//  Mumble
//
//  Created by 王梓田 on 1/2/26.
//

import SwiftUI
import UniformTypeIdentifiers

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
    
    // 删除相关
    @State private var certToDelete: CertificateItem?
    @State private var showingDeleteConfirmation = false
    
    var body: some View {
        certificateList
            .navigationTitle("Certificates")
            .toolbar { toolbarContent }
            // --- 导入功能 ---
            .fileImporter(isPresented: $showingImportPicker, allowedContentTypes: [.pkcs12], allowsMultipleSelection: false, onCompletion: handleImportSelection)
            .alert("Import Certificate", isPresented: $showingImportPasswordAlert, actions: {
                SecureField("Password", text: $importPassword)
                Button("Cancel", role: .cancel) {
                    selectedFileForImport?.stopAccessingSecurityScopedResource()
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
            .sheet(isPresented: $showingShareSheet) {
                if let url = exportedFileURL {
                    ShareSheet(activityItems: [url])
                }
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
    
    private var certificateList: some View {
        List {
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
    }
    
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button(action: { showingImportPicker = true }) {
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
                Text("Long press on a certificate to Export or Delete.")
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
            url.stopAccessingSecurityScopedResource()
            
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
        if let cert = certToExport {
            if let url = certModel.exportCertificate(cert, password: exportPassword) {
                self.exportedFileURL = url
                self.showingShareSheet = true
            }
        }
    }
    
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

struct ShareSheet: UIViewControllerRepresentable {
    var activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

extension UTType {
    static var pkcs12: UTType {
        UTType(filenameExtension: "p12") ?? .data
    }
}
