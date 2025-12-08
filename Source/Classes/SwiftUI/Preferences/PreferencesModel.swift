//
//  PreferencesModel.swift
//  Mumble
//
//  Created by 王梓田 on 12/8/25.
//

import SwiftUI
import Combine

// 定义通知名称，用于通知 AppDelegate 重载音频设置
extension Notification.Name {
    static let MumblePreferencesChanged = Notification.Name("MumblePreferencesChanged")
}

@MainActor
class PreferencesModel: ObservableObject {
    static let shared = PreferencesModel()
    
    private var pendingRequestWorkItem: DispatchWorkItem?
    
    func notifySettingsChanged() {
        // 1. 如果有还在排队等待执行的重启任务，先取消它
        // 这就是消除“多次重启”导致竞争的关键
        pendingRequestWorkItem?.cancel()
            
        // 2. 创建一个新的任务
        let requestWorkItem = DispatchWorkItem { [weak self] in
            print("⚙️ Applying audio settings (Engine Restart)...")
            NotificationCenter.default.post(name: .MumblePreferencesChanged, object: nil)
        }
            
        // 3. 保存这个任务的引用
        pendingRequestWorkItem = requestWorkItem
            
        // 4. 延迟执行 (建议 0.3秒 - 0.5秒)
        // 0.3秒对于人类感知来说是“即时”的，但对于 CPU 来说足够完成上一次音频销毁工作
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: requestWorkItem)
    }
}
