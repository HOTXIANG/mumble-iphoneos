//
//  MumbleLiveActivity.swift
//  MumbleWidget
//
//  Created by 王梓田 on 1/3/26.
//

import WidgetKit
import SwiftUI
import ActivityKit

struct MumbleLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MumbleActivityAttributes.self) { context in
            // ==============================
            // 1. 锁屏 / 通知中心 UI (Live Activity)
            // ==============================
            VStack(alignment: .leading, spacing: 10) {
                // 顶部：服务器名和状态
                HStack {
                    Image(systemName: "waveform.circle.fill")
                        .foregroundColor(.accentColor)
                    Text(context.attributes.serverName)
                        .font(.caption)
                        .bold()
                        .foregroundColor(.secondary)
                    Spacer()
                    // 显示频道人数
                    Label("\(context.state.userCount)", systemImage: "person.2.fill")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                
                Divider().background(Color.gray.opacity(0.3))
                
                // 中间：显示说话者列表
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
                    // 显示所有正在说话的人
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Speaking now:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        ForEach(context.state.speakers, id: \.self) { speaker in
                            HStack {
                                Image(systemName: "mic.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                                Text(speaker)
                                    .font(.body)
                                    .fontWeight(.semibold)
                                Spacer()
                                // 简单的波形动画条
                                WaveformView(color: .green)
                            }
                        }
                    }
                }
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.85)) // 深色背景
            .activitySystemActionForegroundColor(Color.white)

        } dynamicIsland: { context in
            // ==============================
            // 2. 灵动岛 UI (Dynamic Island)
            // ==============================
            DynamicIsland {
                // --- 展开模式 (Expanded) ---
                DynamicIslandExpandedRegion(.leading) {
                    // 左上：当前频道名
                    Text(context.state.channelName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 8)
                }
                
                DynamicIslandExpandedRegion(.trailing) {
                    // 右上：自我状态
                    HStack {
                        StatusIconView(isMuted: context.state.isSelfMuted, isDeafened: context.state.isSelfDeafened)
                        Text(context.attributes.serverName)
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                    .padding(.trailing, 8)
                }
                
                DynamicIslandExpandedRegion(.bottom) {
                    // 底部：说话者列表
                    VStack(alignment: .leading, spacing: 8) {
                        if context.state.speakers.isEmpty {
                            HStack {
                                Text("No active speakers")
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                                Spacer()
                            }
                        } else {
                            // 限制最多显示 3-4 行，避免灵动岛过大
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
                // --- 紧凑模式左侧：自我状态 ---
                // 闭麦 -> 划线麦克风
                // 开麦 -> 实心麦克风
                // 拒听 -> 划线扬声器 (优先级最高)
                StatusIconView(isMuted: context.state.isSelfMuted, isDeafened: context.state.isSelfDeafened)
                    .padding(.leading, 4)
                
            } compactTrailing: {
                // --- 紧凑模式右侧：频道信息或说话人 ---
                if context.state.speakers.isEmpty {
                    // 无人说话：显示总人数
                    Text("\(context.state.userCount)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundColor(.gray)
                } else if context.state.speakers.count == 1 {
                    // 单人说话：显示名字 (绿色)
                    Text(context.state.speakers[0])
                        .font(.caption2)
                        .bold()
                        .foregroundColor(.green)
                        .frame(maxWidth: 50) // 限制宽度防止挤占
                        .lineLimit(1)
                } else {
                    // 多人说话：显示说话人数 (绿色)
                    HStack(spacing: 2) {
                        Text("\(context.state.speakers.count)")
                            .font(.caption2)
                            .bold()
                        Image(systemName: "mic.fill")
                            .font(.system(size: 8))
                    }
                    .foregroundColor(.green)
                }
            } minimal: {
                // --- 极简模式 ---
                if !context.state.speakers.isEmpty {
                    // 有人说话显示绿色波形或人数
                    Text("\(context.state.speakers.count)")
                        .foregroundColor(.green)
                        .bold()
                } else {
                    // 无人说话显示自我状态
                    StatusIconView(isMuted: context.state.isSelfMuted, isDeafened: context.state.isSelfDeafened, size: 10)
                }
            }
        }
    }
}

// 辅助视图：状态图标逻辑
struct StatusIconView: View {
    let isMuted: Bool
    let isDeafened: Bool
    var size: CGFloat = 14
    
    var body: some View {
        Group {
            if isDeafened {
                // 拒听状态：显示划线扬声器
                Image(systemName: "speaker.slash.fill")
                    .foregroundColor(.red)
            } else if isMuted {
                // 闭麦状态：显示划线麦克风
                Image(systemName: "mic.slash.fill")
                    .foregroundColor(.orange)
            } else {
                // 正常开麦：显示麦克风
                Image(systemName: "mic.fill")
                    .foregroundColor(.gray) // 或者 .white
            }
        }
        .font(.system(size: size))
    }
}

// 辅助视图：简单的波形动画
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
