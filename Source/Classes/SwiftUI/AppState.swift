// 文件: AppState.swift (已更新)

import SwiftUI

@MainActor
class AppState: ObservableObject {
    // --- 核心修改 1：将 Tab 的定义移到这里 ---
        enum Tab {
            case channels
            case messages
        }
    
    @Published var isConnected: Bool = false
    
    // --- 核心修改：添加一个属性来临时存储服务器的显示名称 ---
    @Published var serverDisplayName: String? = nil
    
    // --- 核心修改 1：添加一个新的 @Published 属性来存储未读消息数 ---
    @Published var unreadMessageCount: Int = 0
        
    // --- 核心修改 2：添加一个属性来跟踪当前显示的 Tab ---
    @Published var currentTab: Tab = .channels // 默认是频道列表
    
    static let shared = AppState()
    private init() {}
}
