//
//  AudioMeterModel.swift
//  Mumble
//
//  Created by 王梓田 on 12/8/25.
//

import SwiftUI
import Combine

final class AudioMeterModel: ObservableObject, @unchecked Sendable {
    @Published var currentLevel: Float = 0.0
    private var timer: DispatchSourceTimer?
    private let samplingQueue = DispatchQueue(label: "cn.hotxiang.mumble.audio-meter", qos: .userInteractive)
    private let stateLock = NSLock()
    private let updateInterval: TimeInterval = 0.03
    private var monitorSessionID: UInt = 0
    private var mainThreadUpdatePending = false

    // 后台任务负责节拍，采样与 UI 更新在主线程执行（MKAudio 线程安全要求）
    func startMonitoring() {
        stopMonitoring()
        monitorSessionID &+= 1
        let sessionID = monitorSessionID

        let source = DispatchSource.makeTimerSource(queue: samplingQueue)
        source.schedule(deadline: .now(), repeating: updateInterval, leeway: .milliseconds(10))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.beginPendingMainThreadUpdate() else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                defer { self.endPendingMainThreadUpdate() }
                guard self.monitorSessionID == sessionID else { return }
                self.currentLevel = Self.sampleLevel()
            }
        }
        timer = source
        source.resume()
    }

    // 停止监听（节省资源）
    func stopMonitoring() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        monitorSessionID &+= 1
        endPendingMainThreadUpdate()
        if Thread.isMainThread {
            currentLevel = 0.0
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.currentLevel = 0.0
            }
        }
    }

    private static func sampleLevel() -> Float {
        guard let audio = MKAudio.shared() else { return 0.0 }

        let vadKind = UserDefaults.standard.string(forKey: "AudioVADKind") ?? "amplitude"

        let rawLevel: Float
        if vadKind == "snr" {
            rawLevel = audio.speechProbablity()
        } else {
            let peak = audio.peakCleanMic()
            rawLevel = (peak + 96.0) / 96.0
        }

        return min(max(rawLevel, 0.0), 1.0)
    }

    private func beginPendingMainThreadUpdate() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !mainThreadUpdatePending else { return false }
        mainThreadUpdatePending = true
        return true
    }

    private func endPendingMainThreadUpdate() {
        stateLock.lock()
        mainThreadUpdatePending = false
        stateLock.unlock()
    }
}
