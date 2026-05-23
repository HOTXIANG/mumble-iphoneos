//
//  PreferencesModel.swift
//  Mumble
//
//  Created by 王梓田 on 12/8/25.
//

import SwiftUI
import Combine

extension Notification.Name {
    static let mumbleShowVADTutorialAgain = Notification.Name("MumbleShowVADTutorialAgain")
}

@MainActor
class PreferencesModel: ObservableObject {
    static let shared = PreferencesModel()
    
    private var pendingRequestWorkItem: DispatchWorkItem?
    
    func notifySettingsChanged() {
        // 1. 如果有还在排队等待执行的设置应用任务，先取消它
        // 这就是消除“多次设置应用”导致竞争的关键
        pendingRequestWorkItem?.cancel()
            
        // 2. 创建一个新的任务
        let requestWorkItem = DispatchWorkItem {
            MumbleLogger.audio.info("Applying audio settings")
            NotificationCenter.default.post(name: .muPreferencesChanged, object: nil)
        }
            
        // 3. 保存这个任务的引用
        pendingRequestWorkItem = requestWorkItem
            
        // 4. 延迟执行 (建议 0.3秒 - 0.5秒)
        // 0.3秒对于人类感知来说是“即时”的，但足够合并连续的 UI 设置变化
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: requestWorkItem)
    }
}
