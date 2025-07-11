// 文件: MessagesView.swift (最终版)

import SwiftUI

// 消息气泡现在接收一个 ChatMessage 对象
private struct MessageBubbleView: View {
    let message: ChatMessage
    
    var body: some View {
        VStack(
            alignment: message.isSentBySelf ? .trailing : .leading,
            spacing: 4
        ) {
            // 只为非自己发送的消息显示发送者名称
            if !message.isSentBySelf {
                Text(
                    message.senderName
                )
                .font(
                    .system(
                        size: 14,
                        weight: .semibold
                    )
                )
                .padding(
                    .leading,
                    4
                )
            }
            
            // 消息内容和图片
            VStack(
                alignment: .leading,
                spacing: 8
            ) {
                if !message.message.isEmpty {
                    Text(
                        message.message
                    )
                    .foregroundColor(.black)
                }
                // 显示图片
                if !message.images.isEmpty {
                    ForEach(
                        0..<message.images.count,
                        id: \.self
                    ) { index in
                        Image(
                            uiImage: message.images[index]
                        )
                        .resizable()
                        .aspectRatio(
                            contentMode: .fit
                        )
                        .frame(
                            maxWidth: 200
                        )
                        .cornerRadius(
                            8
                        )
                        .onTapGesture {
                            // TODO: 实现点击图片全屏查看
                        }
                    }
                }
            }
            .padding(
                .horizontal,
                12
            )
            .padding(
                .vertical,
                8
            )
            .background(
                message.isSentBySelf ? Color.accentColor : .primary,
                in: RoundedRectangle(
                    cornerRadius: 16,
                    style: .continuous
                )
            )
        }
        .foregroundColor(
            .primary
        )
        .font(
            .system(
                size: 15
            )
        )
        .frame(
            maxWidth: .infinity,
            alignment: message.isSentBySelf ? .trailing : .leading
        )
    }
}


struct MessagesView: View {
    @ObservedObject var serverManager: ServerModelManager
    @State private var isInputActive: Bool = false
    @State private var newMessage = ""
    @FocusState private var isTextFieldFocused: Bool
    private let bottomID = "bottomOfMessages"
    
    var body: some View {
        ZStack(
            alignment: .bottom
        ){
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.20, green: 0.20, blue: 0.40),
                    Color(red: 0.07, green: 0.07, blue: 0.10)
                ]),
                startPoint: .top,
                endPoint: .bottom
            ).ignoresSafeArea()
            
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(
                        alignment: .leading,
                        spacing: 16
                    ) { // 增大气泡间距
                        // --- 核心修改 1：循环遍历真实的消息数组 ---
                        ForEach(
                            serverManager.messages
                        ) { message in
                            MessageBubbleView(
                                message: message
                            )
                        }
                        Color.clear
                            .frame(
                                height: 1
                            )
                            .id(
                                bottomID
                            )
                    }
                    .padding()
                }
                .padding(
                    .bottom,
                    isInputActive ? 85 : 50
                )
                // --- 核心修改 2：当消息数组变化时，自动滚动到底部 ---
                .onChange(
                    of: serverManager.messages
                ) {
                    withAnimation {
                        proxy
                            .scrollTo(
                                bottomID,
                                anchor: .bottom
                            )
                    }
                }
            }
            
            if isInputActive {
                TextInputBar(
                    text: $newMessage,
                    isFocused: $isTextFieldFocused,
                    onSend: sendMessage,
                    onDismiss: {
                        isInputActive = false
                    })
            } else {
                Button(
                    action: {
                        isInputActive = true
                    }) {
                        Image(
                            systemName: "keyboard.fill"
                        )
                        .font(
                            .title2
                        )
                        .foregroundColor(
                            .white
                        )
                        .padding()
                        .background(
                            Color.accentColor,
                            in: Circle()
                        )
                        .shadow(
                            radius: 5
                        )
                    }
                    .padding()
                    .padding(
                        .bottom,
                        40
                    )
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .bottomTrailing
                    )
                    .transition(
                        .scale.combined(
                            with: .opacity
                        )
                    )
            }
        }
        .animation(
            .spring(
                response: 0.4,
                dampingFraction: 0.8
            ),
            value: isInputActive
        )
    }
    
    // --- 核心修改 3：发送消息方法现在调用 serverManager ---
    private func sendMessage() {
        guard !newMessage.isEmpty else {
            return
        }
        serverManager
            .sendTextMessage(
                newMessage
            )
        newMessage = "" // 清空输入框
    }
}

// TextInputBar 保持不变
private struct TextInputBar: View {
    @Binding var text: String; @FocusState.Binding var isFocused: Bool; let onSend: () -> Void; let onDismiss: () -> Void
    var body: some View {
        HStack(
            alignment: .center,
            spacing: 10
        ) {
            Button(
                action: {
                    isFocused = false; onDismiss()
                }) {
                    Image(
                        systemName: "xmark"
                    ).font(
                        .system(
                            size: 17,
                            weight: .semibold
                        )
                    ).foregroundColor(
                        .secondary
                    ).frame(
                        width: 40,
                        height: 40
                    ).background(
                        Color(
                            uiColor: .systemGray4
                        ),
                        in: Circle()
                    )
                }
                .buttonStyle(
                    .plain
                )
            TextField(
                "Type a message...",
                text: $text,
                onCommit: onSend
            )
            .focused(
                $isFocused
            )
            .padding(
                .horizontal,
                16
            )
            .frame(
                height: 40
            )
            .background(
                Color(
                    uiColor: .systemGray6
                ),
                in: Capsule()
            )
            Button(
                action: onSend
            ) {
                Image(
                    systemName: "arrow.up"
                ).font(
                    .system(
                        size: 17,
                        weight: .semibold
                    )
                ).foregroundColor(
                    text.isEmpty ? .white : .white
                ).frame(
                    width: 40,
                    height: 40
                ).background(
                    text.isEmpty ? Color.gray : Color.accentColor,
                    in: Circle()
                )
            }
            .buttonStyle(
                .plain
            )
            .disabled(
                text.isEmpty
            )
        }.padding(
            .horizontal
        ).padding(
            .vertical,
            8
        ).background(
            Color.clear
        ).transition(
            .move(
                edge: .bottom
            ).combined(
                with: .opacity
            )
        ).onAppear {
            isFocused = true
        }
    }
}
