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
    private let samplingQueue = DispatchQueue(label: "cn.hotxiang.mumble.audio-meter", qos: .userInitiated)
    private let stateLock = NSLock()
    static let refreshInterval: TimeInterval = 1.0 / 60.0
    private let updateInterval: TimeInterval = AudioMeterModel.refreshInterval
    private let legacyPublishIntervalNanos: UInt64 = 100_000_000
    private let reconfigurationPauseNanos: UInt64 = 900_000_000
    private let minimumPublishedLevelDelta: Float = 0.015
    private var monitorSessionID: UInt = 0
    private var mainThreadUpdatePending = false
    private var latestLevel: Float = 0.0
    private var lastPublishedLevel: Float = 0.0
    private var lastPublishedUptimeNanos: UInt64 = 0
    private var samplingPausedUntilUptimeNanos: UInt64 = 0
    private var vadKind = UserDefaults.standard.string(forKey: "AudioVADKind") ?? "amplitude"

    deinit {
        stopMonitoring()
    }

    // 后台任务负责节拍与采样；UI 通过快照在显示刷新时读取，避免主线程等待音频队列。
    func startMonitoring(vadKind: String? = nil) {
        stopMonitoring()
        stateLock.lock()
        if let vadKind {
            self.vadKind = vadKind
        }
        monitorSessionID &+= 1
        let sessionID = monitorSessionID
        lastPublishedUptimeNanos = 0
        stateLock.unlock()

        let source = DispatchSource.makeTimerSource(queue: samplingQueue)
        source.schedule(deadline: .now(), repeating: updateInterval, leeway: .milliseconds(1))
        source.setEventHandler { [weak self] in
            self?.sampleAndStoreLevel(sessionID: sessionID)
        }
        timer = source
        source.resume()
    }

    func updateVADKind(_ vadKind: String) {
        stateLock.lock()
        self.vadKind = vadKind
        latestLevel = 0.0
        lastPublishedLevel = 0.0
        samplingPausedUntilUptimeNanos = DispatchTime.now().uptimeNanoseconds + reconfigurationPauseNanos
        stateLock.unlock()
        publishCurrentLevel(0.0)
    }

    func levelSnapshot() -> Float {
        stateLock.lock()
        let level = latestLevel
        stateLock.unlock()
        return level
    }

    // 停止监听（节省资源）
    func stopMonitoring() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        stateLock.lock()
        monitorSessionID &+= 1
        latestLevel = 0.0
        lastPublishedLevel = 0.0
        lastPublishedUptimeNanos = 0
        samplingPausedUntilUptimeNanos = 0
        stateLock.unlock()
        endPendingMainThreadUpdate()
        publishCurrentLevel(0.0)
    }

    private func sampleAndStoreLevel(sessionID: UInt) {
        stateLock.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        guard monitorSessionID == sessionID else {
            stateLock.unlock()
            return
        }
        if now < samplingPausedUntilUptimeNanos {
            latestLevel = 0.0
            stateLock.unlock()
            return
        }
        let currentVADKind = vadKind
        stateLock.unlock()

        let level = Self.sampleLevel(vadKind: currentVADKind)

        stateLock.lock()
        guard monitorSessionID == sessionID else {
            stateLock.unlock()
            return
        }
        latestLevel = level
        let shouldPublishLegacyLevel = now - lastPublishedUptimeNanos >= legacyPublishIntervalNanos
            && abs(level - lastPublishedLevel) >= minimumPublishedLevelDelta
        if shouldPublishLegacyLevel {
            lastPublishedUptimeNanos = now
            lastPublishedLevel = level
        }
        stateLock.unlock()

        guard shouldPublishLegacyLevel, beginPendingMainThreadUpdate() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.endPendingMainThreadUpdate() }
            guard self.isSessionActive(sessionID) else { return }
            self.currentLevel = self.levelSnapshot()
        }
    }

    private func publishCurrentLevel(_ level: Float) {
        if Thread.isMainThread {
            currentLevel = level
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.currentLevel = level
            }
        }
    }

    private static func sampleLevel(vadKind: String) -> Float {
        guard let audio = MKAudio.shared() else { return 0.0 }

        let rawLevel: Float
        if vadKind == "snr" {
            rawLevel = audio.speechProbablity()
        } else {
            let peak = audio.peakCleanMic()
            rawLevel = (peak + 96.0) / 96.0
        }

        return min(max(rawLevel, 0.0), 1.0)
    }

    private func isSessionActive(_ sessionID: UInt) -> Bool {
        stateLock.lock()
        let active = monitorSessionID == sessionID
        stateLock.unlock()
        return active
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
