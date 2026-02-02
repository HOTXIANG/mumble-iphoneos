// 文件: MessagesView.swift

import SwiftUI
import PhotosUI
import QuickLook
import UIKit
import UniformTypeIdentifiers

// MARK: - 1. QuickLook 预览包装器 (标准 SwiftUI 实现)
struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    
    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    class Coordinator: NSObject, QLPreviewControllerDataSource {
        let parent: QuickLookPreview
        
        init(parent: QuickLookPreview) {
            self.parent = parent
        }
        
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            return 1
        }
        
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            return parent.url as QLPreviewItem
        }
    }
}

// MARK: - 2. 预览状态模型
struct PreviewItem: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - 3. 主容器 (Stable Container)
struct MessagesView: View {
    let serverManager: ServerModelManager
    
    // 状态管理中心
    @State private var previewItem: PreviewItem?
    @State private var selectedImageForSend: UIImage? // ✅ 状态提升到这里
    
    var body: some View {
        ZStack {
            // 1. 动态内容层
            MessagesList(
                serverManager: serverManager,
                onPreviewRequest: { image in handleImageTap(image: image) },
                onImageSelected: { image in selectedImageForSend = image } // ✅ 接收子视图传来的图片
            )
            
            // 2. 静态锚点层 (所有弹窗都挂在这里)
            Color.clear
                .allowsHitTesting(false)
                // 挂载查看大图 (QuickLook)
                .fullScreenCover(item: $previewItem) { item in
                    QuickLookPreview(url: item.url)
                        .ignoresSafeArea()
                }
                // ✅ 挂载发送确认框 (Sheet) - 现在它也稳定了！
                .sheet(item: $selectedImageForSend) { image in
                    ImageConfirmationView(
                        image: image,
                        onCancel: { selectedImageForSend = nil },
                        onSend: { imageToSend, isHighQuality in
                            await serverManager.sendImageMessage(image: imageToSend, isHighQuality: isHighQuality)
                            selectedImageForSend = nil
                        }
                    )
                    .presentationDetents([.medium , .large])
                }
        }
    }
    
    private func handleImageTap(image: UIImage) {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "mumble_preview_\(UUID().uuidString).jpg"
        let fileURL = tempDir.appendingPathComponent(fileName)
        
        Task.detached(priority: .userInitiated) {
            if let data = image.jpegData(compressionQuality: 1.0) {
                try? data.write(to: fileURL)
                await MainActor.run {
                    self.previewItem = PreviewItem(url: fileURL)
                }
            }
        }
    }
}

// MARK: - 4. 消息列表 (Dynamic Content)
// 这个视图负责监听数据变化和 UI 刷新
struct MessagesList: View {
    @ObservedObject var serverManager: ServerModelManager
    
    // 回调函数
    let onPreviewRequest: (UIImage) -> Void
    let onImageSelected: (UIImage) -> Void // ✅ 新增：通知父视图有图片要发送
    
    @State private var newMessage = ""
    @FocusState private var isTextFieldFocused: Bool
    @State private var isDragTargeted = false
    
    private let bottomID = "bottomOfMessages"
    
    var body: some View {
        ZStack(alignment: .bottom) {
            // 背景
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.20, green: 0.20, blue: 0.25),
                    Color(red: 0.07, green: 0.07, blue: 0.10)
                ]),
                startPoint: .top,
                endPoint: .bottom
            ).ignoresSafeArea()
            
            // 消息列表
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(serverManager.messages) { message in
                            switch message.type {
                            case .userMessage:
                                MessageBubbleView(
                                    message: message,
                                    onImageTap: onPreviewRequest
                                )
                            case .notification:
                                NotificationMessageView(message: message)
                            }
                        }
                        Spacer().frame(height: 10).id(bottomID)
                    }
                    .padding()
                }
                .safeAreaInset(edge: .bottom) {
                    TextInputBar(
                        text: $newMessage,
                        isFocused: $isTextFieldFocused,
                        onSendText: sendTextMessage,
                        onSendImage: { image in
                            isTextFieldFocused = false
                            // ✅ 这里的图片也通过回调传给父视图
                            onImageSelected(image)
                        }
                    )
                    .background(.clear)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: serverManager.messages) { scrollToBottom(proxy: proxy) }
                .onChange(of: isTextFieldFocused) { focused in
                    if focused {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                            scrollToBottom(proxy: proxy)
                        }
                    }
                }
                .onAppear { scrollToBottom(proxy: proxy, animated: false) }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isTextFieldFocused)
        
        // 拖拽逻辑
        .onDrop(of: [.image], isTargeted: $isDragTargeted) { providers in
            handleDrop(providers: providers)
        }
    }
    
    // MARK: - Logic Helpers
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.canLoadObject(ofClass: UIImage.self) {
                provider.loadObject(ofClass: UIImage.self) { image, error in
                    guard let uiImage = image as? UIImage else { return }
                    Task { @MainActor in
                        // ✅ 不再自己处理，而是向上汇报
                        onImageSelected(uiImage)
                    }
                }
                return true
            }
        }
        return false
    }
    
    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
        if serverManager.messages.isEmpty { return }
        if animated {
            withAnimation(.spring(response: 0.3, dampingFraction: 1.0)) {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }
    
    private func sendTextMessage() {
        guard !newMessage.isEmpty else { return }
        serverManager.sendTextMessage(newMessage)
        newMessage = ""
    }
}

// MARK: - 辅助视图 (Bubble, Notification, Input, etc.)

private struct NotificationMessageView: View {
    let message: ChatMessage
    var body: some View {
        HStack(spacing: 6) {
            Text(message.attributedMessage).fontWeight(.medium)
            Text(message.timestamp, style: .time).font(.caption2).opacity(0.6)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundColor(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(uiColor: .systemGray5), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct MessageBubbleView: View {
    let message: ChatMessage
    let onImageTap: (UIImage) -> Void
    
    var body: some View {
        VStack(alignment: message.isSentBySelf ? .trailing : .leading, spacing: 4) {
            if !message.isSentBySelf {
                Text(message.senderName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 6) {
                if !message.plainTextMessage.isEmpty {
                    Text(message.attributedMessage).tint(.pink).textSelection(.enabled)
                }
                if !message.images.isEmpty {
                    ForEach(0..<message.images.count, id: \.self) { index in
                        Button(action: { onImageTap(message.images[index]) }) {
                            Image(uiImage: message.images[index])
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 200)
                                .cornerRadius(8)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(
                message.isSentBySelf ? Color.accentColor : Color(uiColor: .systemGray4),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .foregroundColor(message.isSentBySelf ? .white : .primary)
            
            Text(message.timestamp, style: .time)
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, alignment: message.isSentBySelf ? .trailing : .leading)
    }
}

private struct ImageConfirmationView: View {
    let image: UIImage
    let onCancel: () -> Void
    let onSend: (UIImage, Bool) async -> Void
    @State private var isSending = false
    @State private var isHighQuality = false
    
    var body: some View {
        VStack(spacing: 20) {
            if isSending {
                ProgressView("Compressing and Sending...")
                    .padding(.vertical, 80)
            } else {
                Text("Confirm Image")
                    .font(.headline)
                    .padding(.top, 20)
                
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .cornerRadius(12)
                    .padding(.horizontal)
                
                Toggle(isOn: $isHighQuality) {
                    VStack(alignment: .leading) {
                        Text("High Quality Mode")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("Less Compressed (May fail on PC)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(SwitchToggleStyle(tint: .blue))
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color(uiColor: .secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal)
                
                HStack(spacing: 20) {
                    Button("Cancel", role: .cancel, action: onCancel)
                        .buttonStyle(.bordered).controlSize(.large)
                    Button("Send") {
                        Task { isSending = true; await onSend(image, isHighQuality) }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
        }
        .padding(.bottom)
        .interactiveDismissDisabled(isSending)
    }
}

private struct TextInputBar: View {
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool
    let onSendText: () -> Void
    let onSendImage: (UIImage) async -> Void
    @State private var selectedPhoto: PhotosPickerItem?
    
    var body: some View {
        GlassEffectContainer(spacing: 10.0) {
            HStack(alignment: .bottom, spacing: 10.0) {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.indigo)
                        .frame(width: 40, height: 40)
                        .glassEffect(.clear.interactive())
                }
                .onChange(of: selectedPhoto) {
                    Task {
                        if let data = try? await selectedPhoto?.loadTransferable(type: Data.self),
                           let image = UIImage(data: data) {
                            await onSendImage(image)
                        }
                        selectedPhoto = nil
                    }
                }
                
                TextField("Type a message...", text: $text, axis: .vertical)
                    .focused($isFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .glassEffect(.clear.interactive(), in: .rect(cornerRadius: 20.0))
                    .frame(minHeight: 40)
                
                Button(action: onSendText) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .glassEffect(.regular.tint(text.isEmpty ? .gray.opacity(0.7) : .blue.opacity(0.7)).interactive())
                }
                .disabled(text.isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.clear)
        }
    }
}

extension UIImage: Identifiable {
    public var id: String { return UUID().uuidString }
}

extension CGSize {
    static func + (lhs: CGSize, rhs: CGSize) -> CGSize {
        return CGSize(width: lhs.width + rhs.width, height: lhs.height + rhs.height)
    }
}
