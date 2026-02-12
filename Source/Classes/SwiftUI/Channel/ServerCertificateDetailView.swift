//
//  ServerCertificateDetailView.swift
//  Mumble
//
//  Created by 王梓田 on 1/2/26.
//

import SwiftUI

struct ServerCertificateDetailView: View {
    @Environment(\.dismiss) var dismiss
    
    @State private var certName: String = "Loading..."
    @State private var certHash: String = ""
    @State private var isAnonymous = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Current Session Identity")) {
                    if isAnonymous {
                        HStack {
                            Image(systemName: "person.crop.circle.badge.questionmark")
                                .font(.system(size: 40))
                                .foregroundColor(.orange)
                            VStack(alignment: .leading) {
                                Text("Anonymous")
                                    .font(.headline)
                                Text("You are not using a certificate for this connection.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical)
                    } else {
                        HStack {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.system(size: 40))
                                .foregroundColor(.green)
                            VStack(alignment: .leading) {
                                Text(certName)
                                    .font(.headline)
                                Text("Authenticated Identity")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical)
                        
                        LabeledContent("SHA1 Fingerprint") {
                            Text(certHash)
                                .font(.caption)
                                .monospaced()
                        }
                    }
                }
                
                if isAnonymous {
                    Section {
                        Text("Tip: You can generate a certificate and register this username by tapping 'Register User' in the menu.")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
            }
            .navigationTitle("Certificate Info")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear(perform: loadCurrentCert)
        }
        .presentationDetents([.medium])
    }
    
    private func loadCurrentCert() {
        // 从 MUConnectionController 获取当前使用的证书引用
        if let ref = MUConnectionController.shared()?.currentCertificateRef,
           let cert = MUCertificateController.certificate(withPersistentRef: ref) {
            
            self.certName = cert.commonName() ?? "Unknown"
            self.certHash = cert.hexDigest() ?? ""
            self.isAnonymous = false
        } else {
            self.isAnonymous = true
        }
    }
}
