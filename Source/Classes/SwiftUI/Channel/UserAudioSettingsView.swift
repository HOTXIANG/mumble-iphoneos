//
//  UserAudioSettingsView.swift
//  Mumble
//
//  Created by 王梓田 on 1/14/26.
//

import SwiftUI

struct UserAudioSettingsView: View {
    @ObservedObject var manager: ServerModelManager
    let userSession: UInt
    let userName: String
    
    @State private var volume: Float = 1.0
    @State private var isMuted: Bool = false
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Audio Settings for \(userName)")) {
                    // 1. 自定义音量滑块
                    VStack(alignment: .leading) {
                        HStack {
                            Image(systemName: volumeIcon)
                                .foregroundColor(.accentColor)
                            Text("Local Volume: \(Int(volume * 100))%")
                                .font(.headline)
                        }
                        
                        Slider(value: $volume, in: 0.0...3.0, step: 0.1) {
                            Text("Volume")
                        } minimumValueLabel: {
                            Text("0%")
                                .font(.caption)
                        } maximumValueLabel: {
                            Text("300%")
                                .font(.caption)
                        }
                        .onChange(of: volume) { newValue in
                            // 调用我们自己写的逻辑
                            manager.setLocalUserVolume(session: userSession, volume: newValue)
                        }
                    }
                    .padding(.vertical, 8)
                    
                    // 2. 屏蔽开关
                    Toggle(isOn: $isMuted) {
                        HStack {
                            Image(systemName: "speaker.slash.fill")
                                .foregroundColor(.red)
                            Text("Local Mute (Ignore)")
                                .foregroundColor(.red)
                        }
                    }
                    .onChange(of: isMuted) { _ in
                        manager.toggleLocalUserMute(session: userSession)
                    }
                }
                
                Section {
                    Button("Reset to Default") {
                        volume = 1.0
                        isMuted = false
                        manager.setLocalUserVolume(session: userSession, volume: 1.0)
                        if let user = manager.getUserBySession(userSession), user.isLocalMuted() {
                             manager.toggleLocalUserMute(session: userSession)
                        }
                    }
                }
            }
            .navigationTitle(userName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            loadCurrentState()
        }
    }
    
    private var volumeIcon: String {
        if isMuted || volume == 0 { return "speaker.slash" }
        if volume < 0.5 { return "speaker.wave.1" }
        if volume < 1.0 { return "speaker.wave.2" }
        return "speaker.wave.3"
    }
    
    private func loadCurrentState() {
        self.volume = manager.userVolumes[userSession] ?? 1.0
        
        if let user = manager.getUserBySession(userSession) {
            // 从 MKUser 读取真实的屏蔽状态
            self.isMuted = user.isLocalMuted()
        }
    }
}
