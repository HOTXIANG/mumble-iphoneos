// 文件: MumbleServerWidget.swift
// 显示收藏服务器列表的 Widget，单击直接连接

import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Widget Timeline Provider

struct ServerWidgetProvider: AppIntentTimelineProvider {
    typealias Entry = ServerWidgetEntry
    typealias Intent = ServerWidgetConfigIntent
    
    func placeholder(in context: Context) -> ServerWidgetEntry {
        ServerWidgetEntry(
            date: Date(),
            favouriteServers: [
                WidgetServerItem(id: "demo:64738:User", displayName: "My Server", hostname: "demo.mumble.info", port: 64738, username: "User", hasCertificate: true, lastConnected: Date()),
            ],
            recentServers: [
                WidgetServerItem(id: "test:64738:Guest", displayName: "Test Server", hostname: "test.mumble.info", port: 64738, username: "Guest", hasCertificate: false, lastConnected: Date())
            ],
            displayMode: .favourites
        )
    }
    
    func snapshot(for configuration: ServerWidgetConfigIntent, in context: Context) async -> ServerWidgetEntry {
        let limit = serverLimit(for: context.family)
        return ServerWidgetEntry(
            date: Date(),
            favouriteServers: WidgetDataManager.shared.loadPinnedServers(limit: limit),
            recentServers: WidgetDataManager.shared.loadRecentServers(limit: limit),
            displayMode: configuration.displayMode
        )
    }
    
    func timeline(for configuration: ServerWidgetConfigIntent, in context: Context) async -> Timeline<ServerWidgetEntry> {
        let limit = serverLimit(for: context.family)
        let entry = ServerWidgetEntry(
            date: Date(),
            favouriteServers: WidgetDataManager.shared.loadPinnedServers(limit: limit),
            recentServers: WidgetDataManager.shared.loadRecentServers(limit: limit),
            displayMode: configuration.displayMode
        )
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date()
        return Timeline(entries: [entry], policy: .after(nextUpdate))
    }
    
    private func serverLimit(for family: WidgetFamily) -> Int {
        switch family {
        case .systemSmall: return 3
        case .systemMedium: return 3
        case .systemLarge: return 6
        default: return 3
        }
    }
}

// MARK: - Widget Entry

struct ServerWidgetEntry: TimelineEntry {
    let date: Date
    let favouriteServers: [WidgetServerItem]
    let recentServers: [WidgetServerItem]
    let displayMode: ServerDisplayMode   // 仅 small 尺寸使用
}

// MARK: - App Intent 配置

enum ServerDisplayMode: String, AppEnum {
    case favourites
    case recent
    
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Display Mode"
    static var caseDisplayRepresentations: [ServerDisplayMode: DisplayRepresentation] = [
        .favourites: DisplayRepresentation(title: "Favourites", subtitle: "Show favourite servers"),
        .recent: DisplayRepresentation(title: "Recent", subtitle: "Show recently connected servers")
    ]
}

struct ServerWidgetConfigIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Server List"
    static var description: IntentDescription = IntentDescription("Choose which servers to display (small widget only)")
    
    @Parameter(title: "Display Mode", default: .favourites)
    var displayMode: ServerDisplayMode
}

// MARK: - Widget Views

struct MumbleServerWidgetEntryView: View {
    var entry: ServerWidgetEntry
    @Environment(\.widgetFamily) var family
    
    var body: some View {
        switch family {
        case .systemSmall:
            smallWidgetView
        default:
            dualColumnView
        }
    }
    
    // MARK: - Small Widget（单列，根据配置显示 favourites 或 recent）
    
    private var smallWidgetView: some View {
        let servers = entry.displayMode == .favourites ? entry.favouriteServers : entry.recentServers
        return Group {
            if servers.isEmpty {
                emptyColumnView(title: entry.displayMode == .favourites ? "Favourites" : "Recent")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    columnHeader(
                        title: entry.displayMode == .favourites ? "Favourites" : "Recent",
                        icon: entry.displayMode == .favourites ? "star.fill" : "clock.fill"
                    )
                    .padding(.bottom, 6)
                    
                    ForEach(Array(servers.prefix(3).enumerated()), id: \.element.id) { index, server in
                        if index > 0 {
                            Divider().padding(.vertical, 4)
                        }
                        Link(destination: server.deepLinkURL) {
                            ServerRowView(server: server, compact: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
            }
        }
    }
    
    // MARK: - Medium / Large Widget（双列：左 Favourites，右 Recent）
    
    private var dualColumnView: some View {
        HStack(alignment: .top, spacing: 12) {
            // 左列 - Favourites
            serverColumn(
                title: "Favourites",
                icon: "star.fill",
                servers: entry.favouriteServers,
                maxCount: family == .systemLarge ? 6 : 3
            )

            // 右列 - Recent
            serverColumn(
                title: "Recent",
                icon: "clock.fill",
                servers: entry.recentServers,
                maxCount: family == .systemLarge ? 6 : 3
            )
        }
    }
    
    private func serverColumn(title: String, icon: String, servers: [WidgetServerItem], maxCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            columnHeader(title: title, icon: icon)
                .padding(.bottom, 6)
            
            if servers.isEmpty {
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    Text("No \(title)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                Spacer(minLength: 0)
            } else {
                ForEach(Array(servers.prefix(maxCount).enumerated()), id: \.element.id) { index, server in
                    if index > 0 {
                        Divider().padding(.vertical, 4)
                    }
                    Link(destination: server.deepLinkURL) {
                        ServerRowView(server: server, compact: family == .systemMedium)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }
    
    // MARK: - 通用组件
    
    private func columnHeader(title: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.blue)
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
    
    private func emptyColumnView(title: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "server.rack")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No \(title)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ServerRowView: View {
    let server: WidgetServerItem
    let compact: Bool
    
    var body: some View {
        HStack(spacing: compact ? 6 : 8) {
            // 服务器图标
            Image(systemName: server.hasCertificate ? "checkmark.shield.fill" : "server.rack")
                .font(.system(size: compact ? 16 : 20))
                .foregroundStyle(server.hasCertificate ? .green : .blue)
                .frame(width: compact ? 22 : 26)
            
            VStack(alignment: .leading, spacing: 1) {
                Text(server.displayName)
                    .font(.system(size: compact ? 13 : 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                
                if !compact {
                    Text(server.username)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer(minLength: 0)
            
            Image(systemName: "bolt.fill")
                .font(.system(size: compact ? 10 : 12))
                .foregroundStyle(.blue)
        }
        .padding(.vertical, compact ? 5 : 7)
        .contentShape(Rectangle())
    }
}

// MARK: - Widget 定义

struct MumbleServerWidget: Widget {
    let kind: String = "MumbleServerWidget"
    
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ServerWidgetConfigIntent.self, provider: ServerWidgetProvider()) { entry in
            MumbleServerWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Mumble Servers")
        .description("Quickly connect to your favourite Mumble servers.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Preview

#Preview(as: .systemMedium) {
    MumbleServerWidget()
} timeline: {
    ServerWidgetEntry(
        date: Date(),
        favouriteServers: [
            WidgetServerItem(id: "1", displayName: "Gaming Server", hostname: "game.mumble.com", port: 64738, username: "Player1", hasCertificate: true, lastConnected: Date()),
            WidgetServerItem(id: "2", displayName: "Work Chat", hostname: "work.mumble.com", port: 64738, username: "John", hasCertificate: true, lastConnected: Date().addingTimeInterval(-3600)),
        ],
        recentServers: [
            WidgetServerItem(id: "3", displayName: "Community", hostname: "community.mumble.org", port: 64738, username: "Guest", hasCertificate: false, lastConnected: Date()),
        ],
        displayMode: .favourites
    )
}

