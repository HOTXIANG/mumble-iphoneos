// 文件: MessagesView.swift (最终版)

import SwiftUI
import PhotosUI

// 新的系统通知视图
private struct NotificationMessageView: View {
    let message: ChatMessage
    
    var body: some View {
        Text(message.attributedMessage)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(uiColor: .systemGray5), in: Capsule())
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct FullscreenImageView: View {
    let image: UIImage
    // 使用 @Environment 来获取系统提供的“关闭”功能
    @Environment(\.dismiss) var dismiss
    
    @State private var scale: CGFloat = 1.0
    @GestureState private var gestureScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @GestureState private var gestureOffset: CGSize = .zero

    var body: some View {
            ZStack {
                // 底层：黑色的背景，添加单击退出的手势
                Color.black
                    .opacity(0.8)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.smooth(duration: 0.5)){
                            scale = 1.0
                            offset = .zero
                        }
                        dismiss()
                    }

                // 顶层：图片
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    // --- 核心修改 2：应用最终的缩放和偏移 ---
                    // ZStack 会自动将图片居中，我们只需要应用手势产生的变化即可
                    .scaleEffect(scale * gestureScale)
                    .offset(offset + gestureOffset)
                    .onTapGesture {
                        withAnimation(.smooth(duration: 0.5)){
                            scale = 1.0
                            offset = .zero
                        }
                        dismiss()
                    }
                    // --- 核心修改 3：添加组合手势 ---
                    .gesture(
                        // 拖动手势（平移）
                        DragGesture()
                            .updating($gestureOffset) { value, state, _ in
                                state = value.translation
                            }
                            .onEnded { value in
                                // 当拖动结束时，将手势的偏移量“固化”到最终的偏移量中
                                offset.width += value.translation.width
                                offset.height += value.translation.height
                            }
                            .simultaneously(with:
                                // 缩放手势
                                MagnificationGesture()
                                    .updating($gestureScale) { value, state, _ in
                                        state = value
                                    }
                                    .onEnded { value in
                                        // 当缩放结束时，将手势的缩放比例“固化”到最终的缩放比例中
                                        scale *= value
                                        
                                        // 添加动画，并限制缩放范围
                                        withAnimation(.smooth()) {
                                            if scale < 1.0 {
                                                scale = 1.0
                                                offset = .zero // 缩小时自动弹回居中
                                            } else if scale > 3.0 {
                                                scale = 3.0
                                            }
                                        }
                                    }
                            )
                    )
            }
        }
}

// 消息气泡现在接收一个 ChatMessage 对象
private struct MessageBubbleView: View {
    let message: ChatMessage
    
    let onImageTap: (UIImage) -> Void
    
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
                if !message.plainTextMessage.isEmpty {
                    Text(message.attributedMessage)
                        .tint(.pink)
                        .shadow(color: Color.black, radius: 8)
                        .textSelection(.enabled)
                }
                // 显示图片
                if !message.images.isEmpty {
                    ForEach(
                        0..<message.images.count,
                        id: \.self
                    ) { index in
                        Button(action: {
                            // --- 核心修改 3：当图片被点击时，调用回调 ---
                            onImageTap(message.images[index])
                        }) {
                            Image(uiImage: message.images[index])
                                .resizable().aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 200).cornerRadius(8)
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
            .foregroundColor(message.isSentBySelf ? .white : .black)
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
    
    @State private var fullscreenImage: UIImage?
    
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
                                switch message.type {
                                case .userMessage:
                                    MessageBubbleView(
                                        message: message,
                                        onImageTap: { tappedImage in
                                            fullscreenImage = tappedImage
                                        }
                                    )
                                case .notification:
                                    NotificationMessageView(message: message)
                                }
                            }
                            Spacer().frame(height: 48).id(bottomID)
                        }
                        .padding()
                        .onChange(of: serverManager.messages) {
                            withAnimation {
                                proxy.scrollTo(bottomID, anchor: .bottom)
                            }
                        }
                    }
                    // --- 核心修改 3：添加手势交互式关闭键盘 ---
                    .scrollDismissesKeyboard(.interactively)
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
        .fullScreenCover(item: $fullscreenImage) { image in
            FullscreenImageView(image: image)
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
                        .glassEffect(.clear.interactive())
                        
                    Button("Send") {
                        Task {
                            isSending = true
                            await onSend(image)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .glassEffect(.regular.tint(.blue.opacity(0.7)).interactive())
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
        GlassEffectContainer(spacing: 10.0) {
            HStack(
                alignment: .bottom,
                spacing: 10.0
            ) {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.indigo)
                        .frame(width: 40, height: 40)
                    //.background(.regularMaterial, in: Circle())
                        .glassEffect(.clear.interactive())
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
                //.background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .glassEffect(.clear.interactive(), in: .rect(cornerRadius: 20.0))
                    .frame(minHeight: 40)
                
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
                    )
                    .glassEffect(.regular.tint(text.isEmpty ? .gray.opacity(0.7) : .blue.opacity(0.7)).interactive())
                    /*.background(Circle()
                     .fill(.regularMaterial)
                     .overlay(
                     Circle()
                     .fill(text.isEmpty ? Color.gray.opacity(0.5) : Color.blue.opacity(0.7))
                     )
                     )*/
                }
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
}

extension UIImage: Identifiable {
    public var id: String {
        return UUID().uuidString
    }
}

extension CGSize {
    static func + (lhs: CGSize, rhs: CGSize) -> CGSize {
        return CGSize(width: lhs.width + rhs.width, height: lhs.height + rhs.height)
    }
}
