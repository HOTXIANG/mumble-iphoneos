//
//  HandoffProfilePicker.swift
//  Mumble
//

import SwiftUI

/// Handoff profile 选项模型
struct HandoffProfileOption: Identifiable {
    let primaryKey: Int
    let shortLabel: String
    let menuLabel: String
    let hasCertificate: Bool
    var id: Int { primaryKey }
}

/// 独立的 Handoff Profile 选择器，在 init 时即加载 profiles，避免 @State + onAppear 时序问题
struct HandoffProfilePicker: View {
    @Binding var selectedKey: Int
    @State private var profiles: [HandoffProfileOption] = []

    var body: some View {
        LabeledContent("Handoff Profile") {
            Menu {
                Button {
                    selectedKey = -1
                } label: {
                    HStack(spacing: 8) {
                        selectionMarker(selectedKey == -1)
                        Text("Automatic")
                    }
                }

                if !profiles.isEmpty {
                    Divider()
                }

                ForEach(profiles) { profile in
                    Button {
                        selectedKey = profile.primaryKey
                    } label: {
                        HStack(spacing: 8) {
                            selectionMarker(selectedKey == profile.primaryKey)
                            Text(profile.menuLabel)
                            if profile.hasCertificate {
                                Image(systemName: "checkmark.shield.fill")
                            }
                        }
                    }
                }
            } label: {
                #if os(iOS)
                HStack(spacing: 6) {
                    Text(selectedLabel)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.secondary)
                #else
                Text(selectedLabel)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                #endif
            }
        }
        .onAppear {
            loadProfiles()
        }
        .onChange(of: selectedKey) { _ in
            // 确保 selection 有效：如果选中的 key 不在 profiles 中也不是 -1，重置为 Automatic
            if selectedKey != -1 && !profiles.contains(where: { $0.primaryKey == selectedKey }) {
                selectedKey = -1
            }
        }
    }

    private func loadProfiles() {
        guard let servers = MUDatabase.fetchVisibleFavourites() as? [MUFavouriteServer] else {
            profiles = []
            validateSelection()
            return
        }
        profiles = servers.compactMap { server in
            guard server.hasPrimaryKey() else { return nil }
            let name = server.displayName ?? server.hostName ?? "Unknown"
            let user = (server.userName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let host = server.hostName ?? ""
            let port = server.port
            let shortLabel = name
            let menuLabel = user.isEmpty
                ? "\(name) — \(host):\(port)"
                : "\(name) — \(user) @ \(host):\(port)"
            return HandoffProfileOption(
                primaryKey: Int(server.primaryKey),
                shortLabel: shortLabel,
                menuLabel: menuLabel,
                hasCertificate: server.certificateRef != nil
            )
        }
        validateSelection()
    }

    /// 确保当前 selection 对应一个有效的 tag，否则重置为 Automatic
    private func validateSelection() {
        if selectedKey != -1 && !profiles.contains(where: { $0.primaryKey == selectedKey }) {
            selectedKey = -1
        }
    }

    private var selectedLabel: String {
        if selectedKey == -1 {
            return "Automatic"
        }
        if let selected = profiles.first(where: { $0.primaryKey == selectedKey }) {
            return selected.shortLabel
        }
        return "Automatic"
    }

    @ViewBuilder
    private func selectionMarker(_ isSelected: Bool) -> some View {
        if isSelected {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
        } else {
            Color.clear
                .frame(width: 12, height: 12)
        }
    }
}
