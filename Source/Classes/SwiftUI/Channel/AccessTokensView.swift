//
//  AccessTokensView.swift
//  Mumble
//
//  访问令牌管理视图，支持查看、编辑、添加和删除令牌。
//

import SwiftUI

// MARK: - Access Tokens View

struct AccessTokensView: View {
    @ObservedObject var serverManager: ServerModelManager
    @Environment(\.dismiss) private var dismiss

    @State private var tokens: [TokenItem] = []
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading tokens…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if tokens.isEmpty {
                    ContentUnavailableView(
                        "No Tokens",
                        systemImage: "key",
                        description: Text("Add access tokens to enter password-protected channels.")
                    )
                } else {
                    tokenList
                }
            }
            #if os(macOS)
            .frame(minWidth: 400, minHeight: 300)
            #endif
            .navigationTitle("Access Tokens")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 12) {
                        Button {
                            withAnimation {
                                tokens.append(TokenItem(value: ""))
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                        Button { saveTokens() } label: {
                            Image(systemName: "square.and.arrow.down")
                        }
                    }
                }
            }
            .onAppear { loadTokens() }
        }
    }

    // MARK: - Subviews

    private var tokenList: some View {
        List {
            ForEach($tokens) { $token in
                HStack {
                    Image(systemName: "key")
                        .foregroundStyle(.secondary)
                    TextField("Token", text: $token.value)
                        #if os(macOS)
                        .textFieldStyle(.roundedBorder)
                        #endif
                }
            }
            .onDelete { offsets in
                withAnimation { tokens.remove(atOffsets: offsets) }
            }
        }
        #if os(macOS)
        .listStyle(.inset(alternatesRowBackgrounds: true))
        #endif
    }

    // MARK: - Actions

    private func loadTokens() {
        isLoading = true
        guard let conn = MUConnectionController.shared()?.connection else {
            tokens = serverManager.currentAccessTokens.map { TokenItem(value: $0) }
            isLoading = false
            return
        }

        let hostname = conn.hostname() ?? ""
        let port = Int(conn.port())

        Task {
            let dbTokens = await DatabaseAsync.accessTokensForServer(hostname: hostname, port: port) ?? []
            await MainActor.run {
                // 合并数据库和内存中的令牌，去重
                var merged = dbTokens
                for t in serverManager.currentAccessTokens where !merged.contains(t) {
                    merged.append(t)
                }
                tokens = merged.map { TokenItem(value: $0) }
                isLoading = false
            }
        }
    }

    private func saveTokens() {
        let validTokens = tokens.map(\.value).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        MUConnectionController.shared()?.serverModel?.setAccessTokens(validTokens)
        serverManager.currentAccessTokens = validTokens

        if let conn = MUConnectionController.shared()?.connection {
            let hostname = conn.hostname() ?? ""
            let port = Int(conn.port())
            Task {
                await DatabaseAsync.storeAccessTokens(validTokens, hostname: hostname, port: port)
            }
        }

        dismiss()
    }
}

// MARK: - Token Item

private struct TokenItem: Identifiable {
    let id = UUID()
    var value: String
}
