//
//  SystemMuteManager.swift
//  Mumble
//
//  Created by 王梓田 on 2/2/26.
//

import Foundation
import AVFAudio

@MainActor
class SystemMuteManager {
    
    // 回调：当系统(耳机)静音状态改变时，通过此闭包通知 ServerModelManager 更新 UI
    var onSystemMuteChanged: ((Bool) -> Void)?
    
    private var observer: NSObjectProtocol?
    
    init() {}
    
    /// 激活系统静音集成
    func activate() {
        #if os(macOS)
        // macOS 不使用 AVAudioApplication 的 input mute 管道。
        // 否则调用 setInputMuted 会出现 "input mute handler not set" 日志。
        return
        #else
        guard #available(iOS 17.0, *) else { return }
        
        cleanup()
        
        print("🎙️ SystemMuteManager: Activating (AVAudioApplication only)...")
        
        // 注册官方通知
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioApplication.inputMuteStateChangeNotification,
            object: nil,
            queue: .main // 虽然指定了主队列，但闭包本身仍需处理 Actor 隔离
        ) { [weak self] notification in
            guard let isMuted = notification.userInfo?[AVAudioApplication.muteStateKey] as? Bool else {
                return
            }

            Task { @MainActor [weak self] in
                self?.handleMuteStateUpdate(isMuted: isMuted)
            }
        }
        
        // 初始状态同步
        let currentSystemState = AVAudioApplication.shared.isInputMuted
        print("🎙️ SystemMuteManager: Activation initial state -> \(currentSystemState)")
        #endif
    }
    
    /// 清理监听
    func cleanup() {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
            print("🎙️ SystemMuteManager: Cleanup (Observer Removed)")
        }
    }
    
    /// App 主动设置系统静音 (当用户点击 App 内按钮时调用)
    func setSystemMute(_ isMuted: Bool) {
        #if os(macOS)
        // macOS 下保持 no-op，Mumble 的自闭麦逻辑仍由 serverModel 控制。
        return
        #else
        guard #available(iOS 17.0, *) else { return }
        
        let session = AVAudioSession.sharedInstance()
        // 只有 Session 激活时才能设置，否则会报错 "cannot control mic"
        if session.category != .playAndRecord {
            return
        }
        
        do {
            try AVAudioApplication.shared.setInputMuted(isMuted)
            print("✅ SystemMuteManager: setInputMuted(\(isMuted)) success")
        } catch {
            print("❌ SystemMuteManager: setInputMuted failed: \(error.localizedDescription)")
        }
        #endif
    }
    
    // MARK: - Private Handler
    
    // ✅ 参数改为 Bool，不再接收 Notification 对象
    private func handleMuteStateUpdate(isMuted: Bool) {
        print("🎧 SystemMuteManager: Received notification. New state muted=\(isMuted)")
        // 通知外部更新 (ServerModelManager)
        onSystemMuteChanged?(isMuted)
    }
}
