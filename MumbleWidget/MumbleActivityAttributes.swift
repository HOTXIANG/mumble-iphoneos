//
//  MumbleActivityAttributes.swift
//  Mumble
//
//  Created by 王梓田 on 1/3/26.
//

#if os(iOS)
import ActivityKit
import SwiftUI

struct MumbleActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // 动态数据
        var speakers: [String]      // 所有正在说话的人的名字列表
        var userCount: Int          // 频道总人数
        var channelName: String     // 频道名
        
        // 自我状态
        var isSelfMuted: Bool       // 是否闭麦
        var isSelfDeafened: Bool    // 是否拒听 (Deafen)
    }

    // 静态数据
    var serverName: String
}
#endif
