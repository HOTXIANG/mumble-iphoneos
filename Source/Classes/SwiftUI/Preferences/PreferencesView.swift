//
//  PreferencesView.swift
//  Mumble
//
//  Created by 王梓田 on 12/8/25.
//

import SwiftUI
import UserNotifications

struct NotificationSettingsView: View {
    @AppStorage("NotificationNotifyUserMessages") var notifyUserMessages: Bool = true
    @AppStorage("NotificationNotifySystemMessages") var notifySystemMessages: Bool = true
    
    var body: some View {
        Form {
            Section(header: Text("Push Notifications"), footer: Text("Notifications will be sent when the app is in the background.")) {
                Toggle("User Messages", isOn: $notifyUserMessages)
                Toggle("System Messages", isOn: $notifySystemMessages)
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle("Notifications")
        .onAppear {
            // 进入页面时检查/请求权限
            #if os(iOS)
            let options: UNAuthorizationOptions = [.alert, .badge, .sound]
            #else
            let options: UNAuthorizationOptions = [.alert, .sound]
            #endif
            UNUserNotificationCenter.current().requestAuthorization(options: options) { granted, error in
                if let error = error {
                    print("Notification permission error: \(error)")
                }
            }
        }
    }
}

// 1. 传输模式设置视图
struct AudioTransmissionSettingsView: View {
    @AppStorage("AudioTransmitMethod") var transmitMethod: String = "vad"
    @AppStorage("AudioVADKind") var vadKind: String = "amplitude"
    @AppStorage("AudioVADBelow") var vadBelow: Double = 0.3
    @AppStorage("AudioVADAbove") var vadAbove: Double = 0.6
    
    @AppStorage("AudioPreprocessor") var enablePreprocessor: Bool = true
    
    @StateObject private var audioMeter = AudioMeterModel()
    
    var body: some View {
        Form {
            Section(header: Text("Transmission Method")) {
                HStack {
                    Spacer()
                    Picker("", selection: $transmitMethod) {
                        Text("Voice Activated").tag("vad")
                        Text("Push-to-Talk").tag("ptt")
                        Text("Continuous").tag("continuous")
                    }
                    #if os(macOS)
                    .pickerStyle(.menu)
                    #else
                    .pickerStyle(.inline)
                    #endif
                    .labelsHidden()
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
            
            if transmitMethod == "vad" {
                Section(header: Text("Voice Activation Settings")) {
                    // ✅ 修改 1: 使用分段控制器，不再是列表选择
                    Picker("Detection Type", selection: $vadKind) {
                        Text("Amplitude").tag("amplitude")
                        Text("Signal to Noise").tag("snr")
                    }
                    .pickerStyle(.segmented) // 变成左右切换的滑块样式
                    .onChange(of: vadKind) { newValue in
                        // 如果选择了 SNR 且预处理没开，自动开启
                        if newValue == "snr" && !enablePreprocessor {
                            enablePreprocessor = true
                        }
                        
                        // ✅ 修改 2: 延迟通知
                        // 让 UI 先完成切换动画，0.5秒后再去重启音频引擎
                        // 这样用户就不会觉得“卡住”了
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            PreferencesModel.shared.notifySettingsChanged()
                        }
                    }
                    
                    if vadKind == "snr" && !enablePreprocessor {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.yellow)
                            Text("SNR requires Preprocessing")
                                .font(.caption)
                            Spacer()
                            Button("Enable") {
                                enablePreprocessor = true
                                PreferencesModel.shared.notifySettingsChanged()
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                        }
                    }
                    
                    VStack(spacing: 8) {
                        HStack {
                            Text("Input Level")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                                            
                        AudioBarView(
                            level: audioMeter.currentLevel,
                            lower: Float(vadBelow),
                            upper: Float(vadAbove)
                        )
                    }
                    .padding(.vertical, 4)
                    
                    VStack(alignment: .leading) {
                        Text("Silence Below: \(Int(vadBelow * 100))%")
                            .font(.caption).foregroundColor(.secondary)
                        Slider(value: $vadBelow, in: 0...1) { editing in
                            if !editing { PreferencesModel.shared.notifySettingsChanged() }
                        }
                    }
                    
                    VStack(alignment: .leading) {
                        Text("Speech Above: \(Int(vadAbove * 100))%")
                            .font(.caption).foregroundColor(.secondary)
                        Slider(value: $vadAbove, in: 0...1) { editing in
                            if !editing { PreferencesModel.shared.notifySettingsChanged() }
                        }
                    }
                    
                    Text("Adjust sliders so that the bar stays in green when speaking and red when silent.")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
            
            if transmitMethod == "ptt" {
                Section {
                    Text("In Push-to-Talk mode, a button will appear on the screen. Hold it to speak.")
                        .font(.caption).foregroundColor(.gray)
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle("Transmission")
        .onChange(of: transmitMethod) { PreferencesModel.shared.notifySettingsChanged() }
        .onChange(of: vadKind) { PreferencesModel.shared.notifySettingsChanged() }
        .onAppear {
            audioMeter.startMonitoring()
        }
        .onDisappear {
            audioMeter.stopMonitoring()
        }
    }
}

// 2. 音频质量设置视图
struct AudioQualitySettingsView: View {
    @AppStorage("AudioQualityKind") var qualityKind: String = "Balanced"
    
    var body: some View {
        Form {
            Section(header: Text("Quality Preset")) {
                HStack {
                    Spacer()
                    Picker("", selection: $qualityKind) {
                        Text("Low (60kbit/s)").tag("low")
                        Text("Balanced (100kbit/s)").tag("balanced")
                        Text("High (192kbit/s)").tag("high")
                    }
                    #if os(macOS)
                    .pickerStyle(.menu)
                    #else
                    .pickerStyle(.inline)
                    #endif
                    .labelsHidden()
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle("Audio Quality")
        .onChange(of: qualityKind) { PreferencesModel.shared.notifySettingsChanged() }
    }
}

// 3. 高级音频设置视图
struct AdvancedAudioSettingsView: View {
    @AppStorage("AudioPreprocessor") var enablePreprocessor: Bool = true
    @AppStorage("AudioEchoCancel") var enableEchoCancel: Bool = true
    @AppStorage("AudioMicBoost") var micBoost: Double = 1.0
    @AppStorage("AudioSidetone") var enableSidetone: Bool = false
    @AppStorage("AudioSidetoneVolume") var sidetoneVolume: Double = 0.2
    @AppStorage("AudioSpeakerPhoneMode") var speakerPhoneMode: Bool = true
    @AppStorage("NetworkForceTCP") var forceTCP: Bool = false
    
    var body: some View {
        Form {
            Section(header: Text("Processing")) {
                Toggle("Preprocessing", isOn: $enablePreprocessor)
                if enablePreprocessor {
                    Toggle("Echo Cancellation", isOn: $enableEchoCancel)
                } else {
                    VStack(alignment: .leading) {
                        Text("Mic Boost: \(String(format: "%.1f", micBoost))x")
                        Slider(value: $micBoost, in: 0...2.0, step: 0.1) { editing in
                            if !editing { PreferencesModel.shared.notifySettingsChanged() }
                        }
                    }
                }
            }
            
            Section(header: Text("Output")) {
                Toggle("Speakerphone Mode", isOn: $speakerPhoneMode)
                Toggle("Sidetone (Hear yourself)", isOn: $enableSidetone)
                if enableSidetone {
                    VStack(alignment: .leading) {
                        Text("Sidetone Volume")
                        Slider(value: $sidetoneVolume, in: 0...1) { editing in
                            if !editing { PreferencesModel.shared.notifySettingsChanged() }
                        }
                    }
                }
            }
            
            Section(header: Text("Network")) {
                Toggle("Force TCP Mode", isOn: $forceTCP)
                Text("Requires reconnection to take effect.")
                    .font(.caption).foregroundColor(.gray)
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle("Advanced")
        .onChange(of: enablePreprocessor) { PreferencesModel.shared.notifySettingsChanged() }
        .onChange(of: enableEchoCancel) { PreferencesModel.shared.notifySettingsChanged() }
        .onChange(of: enableSidetone) { PreferencesModel.shared.notifySettingsChanged() }
        .onChange(of: speakerPhoneMode) { PreferencesModel.shared.notifySettingsChanged() }
    }
}

// 4. 主设置入口视图
struct PreferencesView: View {
    @EnvironmentObject var serverManager: ServerModelManager
    @AppStorage("AudioOutputVolume") var outputVolume: Double = 1.0
    @AppStorage(MumbleHandoffSyncLocalAudioSettingsKey) var handoffSyncLocalAudioSettings: Bool = true
    @Environment(\.dismiss) var dismiss
    
    // 这里我们还需要暂时保留对旧 Objective-C 证书管理器的引用
    // 因为重写证书逻辑比较复杂，我们先用 Wrapper 兼容

    @ViewBuilder
    private var preferencesContent: some View {
        // --- 音频部分 ---
        Section(header: Text("Audio")) {
            VStack(alignment: .leading) {
                Label("Master Volume", systemImage: "speaker.wave.3")
                    .padding(.vertical, 4)
                HStack {
                    Image(systemName: "speaker")
                    Divider()
                    Slider(value: $outputVolume, in: 0...1) { editing in
                        if !editing { PreferencesModel.shared.notifySettingsChanged() }
                    }
                    .frame(maxWidth: .infinity)
                    Divider()
                    Image(systemName: "speaker.wave.3")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            NavigationLink(destination: AudioTransmissionSettingsView()) {
                Label("Transmission", systemImage: "mic")
            }
            
            NavigationLink(destination: AudioQualitySettingsView()) {
                Label("Audio Quality", systemImage: "waveform")
            }
            
            NavigationLink(destination: AdvancedAudioSettingsView()) {
                Label("Advanced & Network", systemImage: "slider.horizontal.3")
            }
        }
        
        // --- 通知部分 ---
        Section(header: Text("Notifications")) {
            NavigationLink(destination: NotificationSettingsView()) {
                Label("Push Notifications", systemImage: "bell.badge")
            }
        }

        // --- 接力部分 ---
        Section(header: Text("Handoff"), footer: Text("When enabled, handoff will sync your local per-user volume/mute preferences to the target device.")) {
            Toggle("Sync Local User Volume on Handoff", isOn: $handoffSyncLocalAudioSettings)
        }
        
        // --- 身份与证书 ---
        NavigationLink(destination: CertificatePreferencesView()) {
            Label("Certificates", systemImage: "checkmark.shield")
        }
        
        // --- 关于 ---
        Section {
            NavigationLink(destination: AboutView()) {
                Label("About Mumble", systemImage: "info.circle")
            }
        } footer: {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            #if os(macOS)
            Text("Mumble macOS v\(version)")
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top)
            #else
            Text("Mumble iOS v\(version)")
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top)
            #endif
        }
    }
    
    var body: some View {
        Group {
            #if os(macOS)
            Form {
                preferencesContent
            }
            .formStyle(.grouped)
            #else
            List {
                preferencesContent
            }
            #endif
        }
        .navigationTitle("Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Done") {
                    dismiss()
                }
            }
        }
        .onAppear {
            serverManager.startAudioTest()
        }
    }
}

struct AudioBarView: View {
    var level: Float      // 当前音量 (0.0 - 1.0)
    var lower: Float      // 下限 (Silence Below)
    var upper: Float      // 上限 (Speech Above)
    
    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            
            // 安全限制，防止 crash
            let safeLower = max(0, min(1, CGFloat(lower)))
            let safeUpper = max(safeLower, min(1, CGFloat(upper)))
            
            ZStack(alignment: .leading) {
                // ==============================
                // 1. 底层：暗色背景 (显示阈值区间)
                // ==============================
                HStack(spacing: 0) {
                    // 红色静默区
                    Rectangle()
                        .fill(Color.red.opacity(0.2))
                        .frame(width: safeLower * w)
                    
                    // 黄色过渡区
                    Rectangle()
                        .fill(Color.yellow.opacity(0.2))
                        .frame(width: (safeUpper - safeLower) * w)
                    
                    // 绿色语音区
                    Rectangle()
                        .fill(Color.green.opacity(0.2))
                        // 剩余宽度自动填充
                }
                
                // ==============================
                // 2. 顶层：亮色前景 (被 mask 裁剪)
                // ==============================
                HStack(spacing: 0) {
                    // 同样的三色结构，但是是不透明的亮色
                    Rectangle()
                        .fill(Color.red)
                        .frame(width: safeLower * w)
                    
                    Rectangle()
                        .fill(Color.yellow)
                        .frame(width: (safeUpper - safeLower) * w)
                    
                    Rectangle()
                        .fill(Color.green)
                }
                // 关键点：使用 mask 来决定显示多少长度
                // 这样无论音量怎么变，它都是连续的一根条，不会断开
                .mask(
                    HStack {
                        Rectangle()
                            .frame(width: min(1.0, max(0, CGFloat(level))) * w)
                        Spacer(minLength: 0)
                    }
                    .animation(.linear(duration: 0.05), value: level) // 只对遮罩长度做动画
                )
                
                // ==============================
                // 3. 阈值分割线 (指示器)
                // ==============================
                ZStack(alignment: .leading) {
                    // 下限线 (Silence Below)
                    Rectangle()
                        .fill(Color.primary.opacity(0.5))
                        .frame(width: 2, height: h)
                        .offset(x: safeLower * w)
                    
                    // 上限线 (Speech Above)
                    Rectangle()
                        .fill(Color.primary.opacity(0.5))
                        .frame(width: 2, height: h)
                        .offset(x: safeUpper * w)
                }
            }
        }
        .frame(height: 24)
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        // 强制裁剪，防止线绘制出界
        .clipped()
    }
}
