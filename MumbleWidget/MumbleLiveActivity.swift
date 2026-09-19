//
//  MumbleLiveActivity.swift
//  MumbleWidget
//

#if os(iOS) && !targetEnvironment(macCatalyst)
import WidgetKit
import SwiftUI
import ActivityKit

struct MumbleLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MumbleActivityAttributes.self) { context in
            LiveActivityLockScreenView(
                serverName: context.attributes.serverName,
                state: context.state,
                isStale: context.isStale
            )
            .activityBackgroundTint(LiveActivityStyle.background)
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading, priority: 1) {
                    LiveActivityServerLabel(serverName: context.attributes.serverName)
                        .padding(.leading, 4)
                        .dynamicTypeSize(...DynamicTypeSize.xLarge)
                }
                DynamicIslandExpandedRegion(.trailing, priority: 2) {
                    LiveActivityAudioBadge(state: context.state, isStale: context.isStale)
                        .padding(.trailing, 4)
                        .dynamicTypeSize(...DynamicTypeSize.xLarge)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    LiveActivityDetails(state: context.state, isStale: context.isStale)
                        .padding(.horizontal, 4)
                        .padding(.top, 6)
                        .padding(.bottom, 4)
                        .dynamicTypeSize(...DynamicTypeSize.xLarge)
                }
            } compactLeading: {
                LiveActivityAudioIcon(state: context.state, isStale: context.isStale)
                    .font(.system(size: 14, weight: .semibold))
            } compactTrailing: {
                LiveActivityCompactIndicator(state: context.state, isStale: context.isStale)
            } minimal: {
                LiveActivityMinimalIndicator(state: context.state, isStale: context.isStale)
            }
            .keylineTint(LiveActivityStyle.speaking)
        }
    }
}

// MARK: - Shared presentation

private enum LiveActivityStyle {
    static let background = Color(red: 0.065, green: 0.05, blue: 0.10)
    // Lift the icon's violet (#6155F5) for legibility on the island's black surface.
    static let speaking = Color(red: 0.69, green: 0.62, blue: 1.0)
    static let secondary = Color.white.opacity(0.65)
}

private struct LiveActivityAudioStatus {
    let state: MumbleActivityAttributes.ContentState
    let isStale: Bool

    var symbol: String {
        if isStale { return "clock.arrow.circlepath" }
        if state.isSelfDeafened { return "speaker.slash.fill" }
        if state.isSelfMuted { return "mic.slash.fill" }
        return "mic.fill"
    }

    var title: LocalizedStringKey {
        if isStale { return "Waiting for updates" }
        if state.isSelfDeafened { return "Deafened" }
        if state.isSelfMuted { return "Muted" }
        return "Microphone on"
    }

    var color: Color {
        if isStale { return .orange }
        if state.isSelfDeafened { return Color(red: 1, green: 0.48, blue: 0.46) }
        if state.isSelfMuted { return Color(red: 1, green: 0.76, blue: 0.38) }
        return LiveActivityStyle.speaking
    }
}

private struct LiveActivityAudioIcon: View {
    let state: MumbleActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        let status = LiveActivityAudioStatus(state: state, isStale: isStale)
        Image(systemName: status.symbol)
            .foregroundStyle(status.color)
            .accessibilityLabel(Text(status.title, tableName: "LiveActivity"))
    }
}

private struct LiveActivityAudioBadge: View {
    let state: MumbleActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        let status = LiveActivityAudioStatus(state: state, isStale: isStale)
        Label {
            Text(status.title, tableName: "LiveActivity")
        } icon: {
            Image(systemName: status.symbol)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(status.color)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(status.color.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

private struct LiveActivityServerLabel: View {
    let serverName: String

    var body: some View {
        Label {
            Text(verbatim: serverName)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: "waveform.circle.fill")
                .foregroundStyle(LiveActivityStyle.speaking)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(LiveActivityStyle.secondary)
        .accessibilityElement(children: .combine)
    }
}

private struct LiveActivityLockScreenView: View {
    let serverName: String
    let state: MumbleActivityAttributes.ContentState
    var isStale = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                LiveActivityServerLabel(serverName: serverName)
                Spacer(minLength: 4)
                LiveActivityAudioBadge(state: state, isStale: isStale)
                    .layoutPriority(1)
            }
            LiveActivityDetails(state: state, isStale: isStale)
        }
        .padding(16)
        .foregroundStyle(.white)
        // Live Activity banners have a limited height; VoiceOver retains full names.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }
}

private struct LiveActivityDetails: View {
    let state: MumbleActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Group {
                    if state.channelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Channel", tableName: "LiveActivity")
                    } else {
                        Text(verbatim: state.channelName)
                    }
                }
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

                if !isStale {
                    Label {
                        Text(max(0, state.userCount), format: .number)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    } icon: {
                        Image(systemName: "person.2.fill")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(LiveActivityStyle.secondary)
                    .fixedSize()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(
                        "\(max(0, state.userCount)) in channel", tableName: "LiveActivity"
                    ))
                }
            }
            LiveActivitySpeakerSummary(state: state, isStale: isStale)
        }
    }
}

private struct LiveActivitySpeakerSummary: View {
    let state: MumbleActivityAttributes.ContentState
    let isStale: Bool
    @Environment(\.locale) private var locale

    private var isSpeaking: Bool {
        !isStale && !state.isSelfDeafened && !state.speakers.isEmpty
    }
    private var tint: Color {
        if isStale { return .orange }
        return isSpeaking ? LiveActivityStyle.speaking : LiveActivityStyle.secondary
    }
    private var title: LocalizedStringKey {
        if isStale { return "Waiting for updates" }
        if isSpeaking { return "Speaking now" }
        return state.isSelfDeafened ? "Audio paused" : "Listening"
    }
    private var idleMessage: LocalizedStringKey {
        if isStale { return "Open Mumble to refresh" }
        return state.isSelfDeafened ? "Microphone and sound are off" : "No one is speaking"
    }

    var body: some View {
        Group {
            if isSpeaking && state.speakers.count > 1 {
                ViewThatFits(in: .horizontal) {
                    summaryRow(visibleSpeakerCount: 2, truncateNames: false)
                    summaryRow(visibleSpeakerCount: 1, truncateNames: true)
                }
            } else {
                summaryRow(visibleSpeakerCount: 1, truncateNames: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(tint.opacity(isSpeaking ? 0.09 : 0.06), in: RoundedRectangle(cornerRadius: 13))
        .accessibilityElement(children: .combine)
    }

    private func summaryRow(visibleSpeakerCount: Int, truncateNames: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                if isSpeaking {
                    LiveActivityWaveform()
                } else {
                    Image(systemName: isStale ? "clock.arrow.circlepath" :
                        (state.isSelfDeafened ? "speaker.slash.fill" : "headphones"))
                        .font(.system(size: 18, weight: .medium))
                }
            }
            .foregroundStyle(tint)
            .frame(width: 26)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title, tableName: "LiveActivity")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(tint)
                if isSpeaking {
                    // Fall back to one name before the second name disappears into truncation.
                    Text(verbatim: state.speakers.prefix(visibleSpeakerCount).formatted(.list(type: .and, width: .narrow).locale(locale)))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: !truncateNames, vertical: false)
                } else {
                    Text(idleMessage, tableName: "LiveActivity")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

            if isSpeaking && state.speakers.count > visibleSpeakerCount {
                Text("+\(state.speakers.count - visibleSpeakerCount)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(tint.opacity(0.12), in: Capsule())
                    .fixedSize()
                    .accessibilityLabel(Text(
                        "\(state.speakers.count - visibleSpeakerCount) more speakers", tableName: "LiveActivity"
                    ))
            }
        }
    }
}

private struct LiveActivityMinimalIndicator: View {
    let state: MumbleActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        Group {
            // Keep mute/deafen visible even while other people are speaking.
            if !isStale && !state.isSelfMuted && !state.isSelfDeafened && !state.speakers.isEmpty {
                LiveActivityWaveform()
                    .foregroundStyle(LiveActivityStyle.speaking)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("\(state.speakers.count) speaking", tableName: "LiveActivity"))
            } else {
                LiveActivityAudioIcon(state: state, isStale: isStale)
                    .font(.system(size: 14, weight: .semibold))
            }
        }
        // Match the attached and detached islands, including when audio state changes.
        .frame(width: 24, height: 24)
    }
}

private struct LiveActivityCompactIndicator: View {
    let state: MumbleActivityAttributes.ContentState
    let isStale: Bool

    private var isSpeaking: Bool { !state.isSelfDeafened && !state.speakers.isEmpty }
    private var count: Int { isSpeaking ? state.speakers.count : max(0, state.userCount) }

    var body: some View {
        Group {
            if isStale {
                Image(systemName: "ellipsis")
                    .foregroundStyle(LiveActivityStyle.secondary)
                    .accessibilityLabel(Text("Waiting for updates", tableName: "LiveActivity"))
            } else {
                HStack(spacing: 3) {
                    if isSpeaking {
                        LiveActivityWaveform(compact: true)
                    }
                    Text(count > 99 ? "99+" : count.formatted())
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .foregroundStyle(isSpeaking ? LiveActivityStyle.speaking : LiveActivityStyle.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(isSpeaking
                    ? Text("\(count) speaking", tableName: "LiveActivity")
                    : Text("\(count) in channel", tableName: "LiveActivity"))
            }
        }
        .frame(minWidth: 20)
    }
}

private struct LiveActivityWaveform: View {
    var compact = false

    var body: some View {
        // A stable speaking indicator, not a randomly changing audio level.
        HStack(spacing: 2) {
            ForEach(Array([0.4, 0.75, 1.0, 0.6, 0.35].enumerated()), id: \.offset) { _, height in
                Capsule()
                    .frame(width: compact ? 2 : 3, height: (compact ? 13 : 22) * height)
            }
        }
        .frame(height: compact ? 14 : 24)
    }
}

// MARK: - Deterministic system previews

#if DEBUG
private extension MumbleActivityAttributes {
    static var preview: Self { Self(serverName: "Mumble · Night Owls") }
}

private extension MumbleActivityAttributes.ContentState {
    static var listening: Self {
        Self(speakers: [], userCount: 8, channelName: "The Lounge", isSelfMuted: false, isSelfDeafened: false)
    }
    static var speaking: Self {
        Self(speakers: ["Alex", "Morgan", "Sam", "Taylor"], userCount: 12,
             channelName: "The Lounge", isSelfMuted: false, isSelfDeafened: false)
    }
    static var muted: Self {
        Self(speakers: ["小林", "正在分享旅行见闻的朋友", "Alex"], userCount: 128,
             channelName: "周末闲聊 · 一起分享最近的生活和音乐", isSelfMuted: true, isSelfDeafened: false)
    }
    static var deafened: Self {
        Self(speakers: [], userCount: 8, channelName: "The Lounge", isSelfMuted: true, isSelfDeafened: true)
    }
    static var deafenedWhileSpeaking: Self {
        Self(speakers: ["Alex", "Morgan"], userCount: 8,
             channelName: "The Lounge", isSelfMuted: true, isSelfDeafened: true)
    }
}

#Preview("Lock Screen", as: .content, using: MumbleActivityAttributes.preview) {
    MumbleLiveActivity()
} contentStates: {
    MumbleActivityAttributes.ContentState.listening
    MumbleActivityAttributes.ContentState.speaking
    MumbleActivityAttributes.ContentState.muted
    MumbleActivityAttributes.ContentState.deafened
    MumbleActivityAttributes.ContentState.deafenedWhileSpeaking
}

#Preview("Expanded", as: .dynamicIsland(.expanded), using: MumbleActivityAttributes.preview) {
    MumbleLiveActivity()
} contentStates: {
    MumbleActivityAttributes.ContentState.speaking
    MumbleActivityAttributes.ContentState.muted
    MumbleActivityAttributes.ContentState.deafened
    MumbleActivityAttributes.ContentState.deafenedWhileSpeaking
}

#Preview("Compact", as: .dynamicIsland(.compact), using: MumbleActivityAttributes.preview) {
    MumbleLiveActivity()
} contentStates: {
    MumbleActivityAttributes.ContentState.listening
    MumbleActivityAttributes.ContentState.speaking
    MumbleActivityAttributes.ContentState.muted
    MumbleActivityAttributes.ContentState.deafenedWhileSpeaking
}

#Preview("Minimal", as: .dynamicIsland(.minimal), using: MumbleActivityAttributes.preview) {
    MumbleLiveActivity()
} contentStates: {
    MumbleActivityAttributes.ContentState.speaking
    MumbleActivityAttributes.ContentState.muted
    MumbleActivityAttributes.ContentState.deafened
    MumbleActivityAttributes.ContentState.deafenedWhileSpeaking
}

#Preview("Stale · Long names") {
    LiveActivityLockScreenView(
        serverName: "Mumble · A very long community server name",
        state: .muted,
        isStale: true
    )
    .background(LiveActivityStyle.background, in: RoundedRectangle(cornerRadius: 22))
    .frame(width: 320)
    .environment(\.locale, Locale(identifier: "zh-Hans"))
}
#endif
#endif
