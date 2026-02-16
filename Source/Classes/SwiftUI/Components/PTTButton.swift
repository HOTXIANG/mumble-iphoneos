//
//  PTTButton.swift
//  Mumble
//
//  Created by 王梓田 on 12/8/25.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

struct PTTButton: View {
    // 监听全局设置，决定是否显示
    @AppStorage("AudioTransmitMethod") var transmitMethod: String = "vad"
    @AppStorage("ShowPTTButton") var showPTTButton: Bool = false
    
    // 按钮按下状态，用于 UI 反馈
    @State private var isPressed = false
    
    // 用于记录按钮的累积偏移量
    @State private var offset: CGSize = .zero
    // 用于记录手势过程中的临时偏移量
    @GestureState private var dragOffset: CGSize = .zero
    
    // 触感反馈
    #if os(iOS)
    private let feedback = UIImpactFeedbackGenerator(style: .heavy)
    #endif
    
    var body: some View {
        if transmitMethod == "ptt" && showPTTButton {
            GeometryReader { geometry in
                VStack {
                    Spacer()
                    
                    // 巨大的圆形按钮
                    ZStack {
                        Circle()
                            .fill(isPressed ? Color.red : Color.blue)
                            .frame(width: 80, height: 80)
                            .shadow(color: .black.opacity(0.3), radius: 5, x: 0, y: 3)
                            .scaleEffect(isPressed ? 1.1 : 1.0) // 按下放大动画
                        
                        Image(systemName: isPressed ? "mic.fill" : "mic.slash.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.white)
                    }
                    .position(
                        x: geometry.size.width / 2 + offset.width + dragOffset.width,
                        y: geometry.size.height - 100 + offset.height + dragOffset.height
                    )
                    // 核心交互逻辑：使用 Gesture 来精确控制按下和松开
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .updating($dragOffset) { value, state, _ in
                                // 更新拖拽过程中的临时位移
                                state = value.translation
                            }
                            .onChanged { _ in
                                if !isPressed {
                                    startTransmitting()
                                }
                            }
                            .onEnded { value in
                                stopTransmitting()
                                // 手势结束，保存最终的位置
                                offset.width += value.translation.width
                                offset.height += value.translation.height
                            }
                    )
                }
            }
            .allowsHitTesting(true)
            .onDisappear {
                stopTransmitting()
            }
        }
    }
    
    private func startTransmitting() {
        isPressed = true
        #if os(iOS)
        feedback.impactOccurred()
        #endif
        // 调用底层 MumbleKit 开始传输
        MKAudio.shared()?.setForceTransmit(true)
    }
    
    private func stopTransmitting() {
        isPressed = false
        // 调用底层 MumbleKit 停止传输
        MKAudio.shared()?.setForceTransmit(false)
    }
}

#if os(macOS)
struct PTTKeyboardMonitor: View {
    @AppStorage("AudioTransmitMethod") private var transmitMethod: String = "vad"
    @AppStorage("PTTHotkeyCode") private var pttHotkeyCode: Int = 49
    
    @State private var isPressed = false
    @State private var keyDownMonitor: Any?
    @State private var keyUpMonitor: Any?
    @State private var resignObserver: NSObjectProtocol?
    
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                startMonitoring()
            }
            .onDisappear {
                stopMonitoring()
                stopTransmitting()
            }
            .onChange(of: transmitMethod) { _, newValue in
                if newValue != "ptt" {
                    stopTransmitting()
                }
            }
            .onChange(of: pttHotkeyCode) { _, _ in
                stopTransmitting()
            }
    }
    
    private func startMonitoring() {
        guard keyDownMonitor == nil, keyUpMonitor == nil else { return }
        
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard transmitMethod == "ptt" else { return event }
            guard event.keyCode == UInt16(pttHotkeyCode) else { return event }
            
            if !isPressed {
                isPressed = true
                MKAudio.shared()?.setForceTransmit(true)
            }
            return nil
        }
        
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
            guard transmitMethod == "ptt" else { return event }
            guard event.keyCode == UInt16(pttHotkeyCode) else { return event }
            
            if isPressed {
                isPressed = false
                MKAudio.shared()?.setForceTransmit(false)
            }
            return nil
        }
        
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                stopTransmitting()
            }
        }
    }
    
    private func stopMonitoring() {
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
        if let keyUpMonitor {
            NSEvent.removeMonitor(keyUpMonitor)
            self.keyUpMonitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
    }
    
    private func stopTransmitting() {
        if isPressed {
            isPressed = false
        }
        MKAudio.shared()?.setForceTransmit(false)
    }
}
#endif
