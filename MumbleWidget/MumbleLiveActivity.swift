//
//  MumbleLiveActivity.swift
//  MumbleWidget
//
//  Created by 王梓田 on 1/3/26.
//

#if !targetEnvironment(macCatalyst)
import WidgetKit
import SwiftUI
import ActivityKit

struct MumbleLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MumbleActivityAttributes.self) { context in
            // ==============================
            // 1. 锁屏 / 通知中心 UI (保持不变)
            // ==============================
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "waveform.circle.fill")
                        .foregroundColor(.accentColor)
                    Text(context.attributes.serverName)
                        .font(.caption)
                        .bold()
                        .foregroundColor(.secondary)
                    Spacer()
                    Label("\(context.state.userCount)", systemImage: "person.2.fill")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                
                Divider().background(Color.gray.opacity(0.3))
                
                if context.state.speakers.isEmpty {
                    HStack {
                        Text(context.state.channelName)
                            .font(.headline)
                        Spacer()
                        Text("No one is speaking")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                    }
                    .padding(.vertical, 4)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Speaking now:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        // 锁屏界面空间足够，依然显示名单
                        ForEach(context.state.speakers, id: \.self) { speaker in
                            HStack {
                                Image(systemName: "mic.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                                Text(speaker)
                                    .font(.body)
                                    .fontWeight(.semibold)
                                Spacer()
                                WaveformView(color: .green)
                            }
                        }
                    }
                }
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.85))
            .activitySystemActionForegroundColor(Color.white)

        } dynamicIsland: { context in
            // ==============================
            // 2. 灵动岛 UI (Dynamic Island)
            // ==============================
            DynamicIsland {
                // --- 展开模式 (Expanded) ---
                // 长按展开时，依然显示详细列表，因为这里空间足够且用户主动查看
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.state.channelName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 8)
                }
                
                DynamicIslandExpandedRegion(.trailing) {
                    HStack {
                        StatusIconView(isMuted: context.state.isSelfMuted, isDeafened: context.state.isSelfDeafened)
                        Text(context.attributes.serverName)
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                    .padding(.trailing, 8)
                }
                
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        if context.state.speakers.isEmpty {
                            HStack {
                                Text("No active speakers")
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                                Spacer()
                            }
                        } else {
                            ForEach(Array(context.state.speakers.prefix(3)), id: \.self) { speaker in
                                HStack {
                                    Image(systemName: "mic.fill")
                                        .foregroundColor(.green)
                                    Text(speaker)
                                        .bold()
                                    Spacer()
                                    WaveformView(color: .green)
                                }
                            }
                            if context.state.speakers.count > 3 {
                                Text("+ \(context.state.speakers.count - 3) others")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
                
            } compactLeading: {
                // --- 紧凑模式左侧 (Compact Leading) ---
                // 始终显示自我状态：闭麦/拒听/开麦
                StatusIconView(isMuted: context.state.isSelfMuted, isDeafened: context.state.isSelfDeafened)
                    .padding(.leading, 4)
                
            } compactTrailing: {
                // --- 紧凑模式右侧 (Compact Trailing) ---
                // ✅ 修改点：不再显示用户名，只显示数字
                
                if context.state.speakers.isEmpty {
                    // 无人说话：显示灰色频道总人数
                    Text("\(context.state.userCount)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundColor(.gray)
                } else {
                    // 有人说话 (无论几人)：显示绿色数字
                    HStack(spacing: 2) {
                        Text("\(context.state.speakers.count)")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .monospacedDigit()
                    }
                    .foregroundColor(.green)
                    .contentTransition(.numericText()) // 数字变化的过渡动画
                }
                
            } minimal: {
                // --- 极简模式 (Minimal) ---
                if !context.state.speakers.isEmpty {
                    // 有人说话：显示绿色数字
                    Text("\(context.state.speakers.count)")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.green)
                        .contentTransition(.numericText())
                } else {
                    // 无人说话：显示自我状态图标
                    StatusIconView(isMuted: context.state.isSelfMuted, isDeafened: context.state.isSelfDeafened, size: 10)
                }
            }
        }
    }
}

// 辅助视图保持不变
struct StatusIconView: View {
    let isMuted: Bool
    let isDeafened: Bool
    var size: CGFloat = 14
    
    var body: some View {
        Group {
            if isDeafened {
                Image(systemName: "speaker.slash.fill")
                    .foregroundColor(.red)
            } else if isMuted {
                Image(systemName: "mic.slash.fill")
                    .foregroundColor(.orange)
            } else {
                Image(systemName: "mic.fill")
                    .foregroundColor(.gray)
            }
        }
        .font(.system(size: size))
    }
}

struct WaveformView: View {
    var color: Color
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4) { _ in
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: 3, height: .random(in: 8...16))
            }
        }
    }
}
#endif
