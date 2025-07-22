// 文件: MessagesView.swift (最终版)

import SwiftUI
import PhotosUI

// 新的系统通知视图
private struct NotificationMessageView: View {
    let message: ChatMessage
    
    var body: some View {
        Text(message.message)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(uiColor: .systemGray5), in: Capsule())
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

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
                    .foregroundColor(message.isSentBySelf ? .white : .black)
                    .textSelection(.enabled)
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
                !message.images.isEmpty ? 8 : 10
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
    @State private var newMessage = ""
    @FocusState private var isTextFieldFocused: Bool
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var selectedImageForPreview: UIImage?
    @State private var isSendingImage = false
    
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
            
            ZStack(alignment: .bottom) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(serverManager.messages) { message in
                                MessageBubbleView(message: message)
                            }
                            Color.clear.frame(height: 1).id(bottomID)
                        }
                        .padding()
                    }
                    // --- 核心修改 3：添加手势交互式关闭键盘 ---
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: serverManager.messages) {
                        withAnimation {
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        }
                    }
                }
                
                TextInputBar(
                    text: $newMessage,
                    isFocused: $isTextFieldFocused,
                    onSendText: sendTextMessage,
                    onSendImage: { image in
                        // 当选择了图片后，弹出确认框
                        isTextFieldFocused = false
                        selectedImageForPreview = image
                    }
                )
            }
        }
        // 当键盘出现或消失时，应用动画
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isTextFieldFocused)
        // 图片确认 Sheet 保持不变
        .sheet(item: $selectedImageForPreview) { image in
            ImageConfirmationView(
                image: image,
                onCancel: {
                    selectedImageForPreview = nil
                },
                onSend: { imageToSend in
                    // 直接调用异步的 sendImageMessage
                    await sendImageMessage(image: imageToSend)
                    // 发送完成后，关闭 sheet
                    selectedImageForPreview = nil
                }
            )
            .presentationDetents([.medium , .large])
        }
    }
    
    // --- 核心修改 3：发送消息方法现在调用 serverManager ---
    private func sendTextMessage() {
            guard !newMessage.isEmpty else { return }
            serverManager.sendTextMessage(newMessage)
            newMessage = ""
        }
        
    private func sendImageMessage(image: UIImage) async {
        await serverManager.sendImageMessage(image: image)
        }
}

private struct ImageConfirmationView: View {
    let image: UIImage
    let onCancel: () -> Void
    let onSend: (UIImage) async -> Void
    @State private var isSending = false

    var body: some View {
        // 不再使用 NavigationView，让视图更紧凑
        VStack(spacing: 16) {
            if isSending {
                // 加载状态
                ProgressView("Compressing and Sending...")
                    .padding(.vertical, 80) // 给加载视图一个合适的高度
            } else {
                // 预览状态
                Text("Confirm Image")
                    .font(.headline)
                    .padding(.top, 20)
                    
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .cornerRadius(12) // 给图片预览也加上圆角
                    .padding(.horizontal)

                HStack(spacing: 20) {
                    Button("Cancel", role: .cancel, action: onCancel)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        
                    Button("Send") {
                        Task {
                            isSending = true
                            await onSend(image)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
        .padding(.bottom)
        // 在发送过程中，禁止用户通过向下滑动来关闭弹窗
        .interactiveDismissDisabled(isSending)
    }
}

private struct TextInputBar: View {
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool
    let onSendText: () -> Void
    let onSendImage: (UIImage) async -> Void
    
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var editorHeight: CGFloat = 40
    
    var body: some View {
        HStack(
            alignment: .center,
            spacing: 10
        ) {
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 40, height: 40)
            }
            .onChange(of: selectedPhoto) {
                Task {
                    if let data = try? await selectedPhoto?.loadTransferable(
                        type: Data.self
                    ),
                       let image = UIImage(data: data) {
                        await onSendImage(image)
                    }
                    // 选择后重置，以便可以再次选择同一张图片
                    selectedPhoto = nil
                }
            }
            TextField("Type a message...", text: $text, axis: .vertical)
                .focused($isFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .frame(minHeight: 40)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color(uiColor: .systemGray4), lineWidth: 1)
                )
            
            Button(
                action: onSendText
            ) {
                Image(
                    systemName: "arrow.up"
                ).font(
                    .system(
                        size: 17,
                        weight: .semibold
                    )
                ).foregroundColor(
                    .white
                ).frame(
                    width: 40,
                    height: 40
                ).background(Circle()
                    .fill(.regularMaterial)
                    .overlay(
                        Circle()
                            .fill(text.isEmpty ? Color.gray.opacity(0.5) : Color.blue.opacity(0.7))
                    )
                             )
            }
            .buttonStyle(
                .plain
            )
            .overlay(
                Circle().stroke(Color(uiColor: .systemGray4), lineWidth: 1)
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
        )
    }
}

extension UIImage: Identifiable {
    public var id: String {
        return UUID().uuidString
    }
}
