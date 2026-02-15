//
//  ChannelACLRows.swift
//  Mumble
//

import SwiftUI

// MARK: - ACL Entry Row

struct ACLEntryRow: View {
    @ObservedObject var entry: ACLEntryModel
    var resolvedUserName: String? = nil

    private var titleText: String {
        if entry.isGroupBased {
            return "@\(entry.group)"
        }
        if let name = resolvedUserName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return "User #\(entry.userID)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: entry.isGroupBased ? "person.3" : "person")
                    .foregroundColor(entry.isInherited ? .secondary : .accentColor)
                    .frame(width: 20)

                Text(titleText)
                    .font(.headline)

                Spacer()

                if entry.isInherited {
                    Text("Inherited")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(4)
                }
            }

            HStack(spacing: 12) {
                if entry.applyHere {
                    Label("Here", systemImage: "checkmark")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
                if entry.applySubs {
                    Label("Subs", systemImage: "checkmark")
                        .font(.caption)
                        .foregroundColor(.purple)
                }

                Spacer()

                // 简要显示 grant/deny 数量
                let grantCount = countBits(entry.grant)
                let denyCount = countBits(entry.deny)

                if grantCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                        Text("\(grantCount)")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }

                if denyCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                            .font(.caption)
                        Text("\(denyCount)")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func countBits(_ value: UInt32) -> Int {
        var count = 0
        var v = value
        while v != 0 {
            count += Int(v & 1)
            v >>= 1
        }
        return count
    }
}

// MARK: - Group Entry Row

struct GroupEntryRow: View {
    @ObservedObject var entry: GroupEntryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "person.3.fill")
                    .foregroundColor(entry.isInherited ? .secondary : .accentColor)
                    .frame(width: 20)

                Text(entry.name)
                    .font(.headline)

                Spacer()

                if entry.isInherited {
                    Text("Inherited")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(4)
                }
            }

            HStack(spacing: 12) {
                if entry.inherit {
                    Label("Inherit", systemImage: "arrow.down")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
                if entry.inheritable {
                    Label("Inheritable", systemImage: "arrow.up")
                        .font(.caption)
                        .foregroundColor(.purple)
                }

                Spacer()

                Text("\(entry.members.count) members")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if !entry.inheritedMembers.isEmpty {
                    Text("+\(entry.inheritedMembers.count) inherited")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
