// 文件: ChannelRowViews.swift (已清理)

import SwiftUI

private struct AvatarView: View {
    let talkingState: TalkingState
    var body: some View {
        Image(systemName: "person.fill")
            .font(.system(size: 24))
            .foregroundColor(talkingState == .talking ? .green : Color(uiColor: .systemGray))
            .frame(width: 36, height: 36)
            .shadow(radius: talkingState == .talking ? 4 : 0)
    }
}

struct ChannelRowView: View {
    @ObservedObject var item: ChannelNavigationItem
    // 移除了 onTap
    
    var body: some View {
        // 不再需要 Button
        HStack(spacing: 12) {
            Spacer().frame(width: CGFloat(item.indentLevel * 20))
            Image(systemName: "number").foregroundColor(.secondary).font(.system(size: 14, weight: .semibold)).frame(width: 24, height: 24)
            Text(item.title).font(.system(size: 17, weight: .medium)).foregroundColor(.primary).shadow(radius: 1)
            Spacer()
            if item.userCount > 0 {
                Text("\(item.userCount)").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary).padding(.horizontal, 8).frame(minWidth: 24, minHeight: 24).background(Color.black.opacity(0.2), in: Capsule())
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .glassEffect(.clear.interactive().tint(item.isConnectedUserChannel ? Color.blue.opacity(0.5) : Color.blue.opacity(0.0)) ,in: .rect(cornerRadius: 12))
    }
}


struct UserRowView: View {
    @ObservedObject var item: ChannelNavigationItem
    // 移除了 onTap
    
    var body: some View {
        // 不再需要 Button
        HStack(spacing: 12) {
            Spacer().frame(width: CGFloat(item.indentLevel * 20))
            AvatarView(talkingState: item.talkingState)
            Text(item.title).font(.system(size: 17, weight: .medium)).foregroundColor(item.isConnectedUser ? .cyan : .primary).shadow(radius: 1)
            Spacer()
            HStack(spacing: 10) {
                if let state = item.state {
                    if state.isSelfDeafened { Image(systemName: "speaker.slash.fill").foregroundColor(.red) }
                    else if state.isMutedOrDeafened { Image(systemName: "mic.slash.fill").foregroundColor(.orange) }
                    if state.isPrioritySpeaker { Image(systemName: "star.fill").foregroundColor(.yellow) }
                    if state.isAuthenticated { Image(systemName: "lock.shield.fill").foregroundColor(.green) }
                }
            }
            .font(.system(size: 16))
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .glassEffect(.clear.interactive().tint(item.isConnectedUser ? Color.indigo.opacity(0.5) : Color.indigo.opacity(0.0)) ,in: .rect(cornerRadius: 12))
    }
}
