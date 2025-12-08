//
//  PTTButton.swift
//  Mumble
//
//  Created by 王梓田 on 12/8/25.
//

import SwiftUI

struct PTTButton: View {
    // 监听全局设置，决定是否显示
    @AppStorage("AudioTransmitMethod") var transmitMethod: String = "vad"
    
    // 按钮按下状态，用于 UI 反馈
    @State private var isPressed = false
    
    // 用于记录按钮的累积偏移量
    @State private var offset: CGSize = .zero
    // 用于记录手势过程中的临时偏移量
    @GestureState private var dragOffset: CGSize = .zero
    
    // 触感反馈
    private let feedback = UIImpactFeedbackGenerator(style: .heavy)
    
    var body: some View {
        if transmitMethod == "ptt" {
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
        }
    }
    
    private func startTransmitting() {
        isPressed = true
        feedback.impactOccurred()
        // 调用底层 MumbleKit 开始传输
        MKAudio.shared()?.setForceTransmit(true)
    }
    
    private func stopTransmitting() {
        isPressed = false
        // 调用底层 MumbleKit 停止传输
        MKAudio.shared()?.setForceTransmit(false)
    }
}
