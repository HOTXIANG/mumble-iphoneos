// 文件: AppState.swift (已更新)

import SwiftUI

@MainActor
class AppState: ObservableObject {
    @Published var isConnected: Bool = false
    
    // --- 核心修改：添加一个属性来临时存储服务器的显示名称 ---
    @Published var serverDisplayName: String? = nil
    
    static let shared = AppState()
    private init() {}
}
