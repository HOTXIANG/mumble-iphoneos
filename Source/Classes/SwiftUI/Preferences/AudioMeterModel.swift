//
//  AudioMeterModel.swift
//  Mumble
//
//  Created by 王梓田 on 12/8/25.
//

import SwiftUI
import Combine

@MainActor
class AudioMeterModel: ObservableObject {
    @Published var currentLevel: Float = 0.0
    private var timer: Timer?

    // 开始监听麦克风音量
    func startMonitoring() {
        stopMonitoring()
        // 50ms 刷新一次，足够流畅
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updateLevel()
        }
    }

    // 停止监听（节省资源）
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        currentLevel = 0.0
    }

    private func updateLevel() {
        // 调用底层 MumbleKit 的 MKAudio 单例
        guard let audio = MKAudio.shared() else { return }
        
        let vadKind = UserDefaults.standard.string(forKey: "AudioVADKind") ?? "amplitude"
        let preprocessor = UserDefaults.standard.bool(forKey: "AudioPreprocessor")
        
        // 逻辑复刻自旧版 MUAudioBarView.m
        // 如果未开启预处理，强制使用振幅模式
        let effectiveKind = preprocessor ? vadKind : "amplitude"
        
        if effectiveKind == "snr" {
            // 信噪比模式 (Signal-to-Noise Ratio)
            currentLevel = audio.speechProbablity()
        } else {
            // 振幅模式 (Amplitude)
            // peakCleanMic 返回的是分贝值 (dB)，通常在 -96.0 到 0.0 之间
            let peak = audio.peakCleanMic()
            // 归一化到 0.0 - 1.0 范围
            currentLevel = (peak + 96.0) / 96.0
        }
        
        // 确保数值在 0-1 之间
        if currentLevel < 0 { currentLevel = 0 }
        if currentLevel > 1 { currentLevel = 1 }
    }
}
