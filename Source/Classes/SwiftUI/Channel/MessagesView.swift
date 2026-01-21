// 文件: MessagesView.swift

import SwiftUI
import PhotosUI
import QuickLook
import UIKit

// MARK: - 1. 容器控制器 (UIKit 层)
// 负责管理 QLPreviewController、点击关闭手势以及解决黑屏问题
class PreviewContainerController: UIViewController, UIGestureRecognizerDelegate {
    var fileURL: URL?
    var onDismiss: (() -> Void)?
    
    private let qlController = QLPreviewController()
    
    // 自定义 Coordinator 来处理数据源
    class Coordinator: NSObject, QLPreviewControllerDataSource {
        let parent: PreviewContainerController
        init(_ parent: PreviewContainerController) { self.parent = parent }
        
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            return (parent.fileURL ?? URL(fileURLWithPath: "")) as QLPreviewItem
        }
    }
    
    private var coordinator: Coordinator?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        
        // 1. 配置 QuickLook
        coordinator = Coordinator(self)
        qlController.dataSource = coordinator
        
        addChild(qlController)
        view.addSubview(qlController.view)
        qlController.view.frame = view.bounds
        qlController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        qlController.didMove(toParent: self)
    }
}

// MARK: - 2. 全屏淡入淡出弹出器 (UIViewControllerRepresentable)
// 这是一个不可见的 View，专门负责用 UIKit 的方式 present 我们的预览控制器
struct FullScreenPreviewPresenter: UIViewControllerRepresentable {
    @Binding var item: MessagesView.IdentifiableURL?
    
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    class Coordinator: NSObject {
        var parent: FullScreenPreviewPresenter
        var currentURL: URL? // 记录当前正在显示的 URL
        
        init(parent: FullScreenPreviewPresenter) {
            self.parent = parent
        }
    }
    
    func makeUIViewController(context: Context) -> UIViewController {
        return UIViewController() // 这是一个空的锚点控制器
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        context.coordinator.parent = self
        
        let newURL = item?.url
        let oldURL = context.coordinator.currentURL
        
        // 🛑 核心修复：去重检查
        // 如果新 URL 和旧 URL 一样，说明数据没变，这次更新只是因为键盘弹起/布局变化引起的。
        // 直接返回，不要执行任何弹出/关闭逻辑。
        if newURL == oldURL {
            return
        }
        
        // 更新记录
        context.coordinator.currentURL = newURL
        
        // 1. 弹出逻辑
        if let item = item {
            // 异步执行，避免视图更新冲突
            DispatchQueue.main.async {
                // 双重检查：确保 item 还在，且没有正在显示的弹窗
                guard self.item != nil, uiViewController.presentedViewController == nil else { return }
                
                // 窗口检测：防止在后台或切换频道时弹出
                if uiViewController.view.window == nil { return }
                
                let previewVC = PreviewContainerController()
                previewVC.fileURL = item.url
                previewVC.modalPresentationStyle = .overFullScreen
                previewVC.modalTransitionStyle = .crossDissolve
                
                previewVC.onDismiss = {
                    // 关闭时清空状态
                    self.item = nil
                    // 重要：手动同步 Coordinator 状态，防止下次误判
                    context.coordinator.currentURL = nil
                }
                
                uiViewController.present(previewVC, animated: true)
            }
        }
        // 2. 关闭逻辑
        else {
            // 只有当当前确实有弹窗时，才执行关闭
            if uiViewController.presentedViewController != nil {
                DispatchQueue.main.async {
                    uiViewController.dismiss(animated: true)
                }
            }
        }
    }
}

// MARK: - 3. 辅助视图 (通知 & 气泡)

private struct NotificationMessageView: View {
    let message: ChatMessage
    
    var body: some View {
        HStack(spacing: 6) {
            Text(message.attributedMessage)
                .fontWeight(.medium)
            Text(message.timestamp, style: .time)
                .font(.caption2)
                .opacity(0.6)
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
        VStack(
            alignment: message.isSentBySelf ? .trailing : .leading,
            spacing: 4
        ) {
            if !message.isSentBySelf {
                Text(message.senderName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.leading, 4)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                if !message.plainTextMessage.isEmpty {
                    Text(message.attributedMessage)
                        .tint(.pink)
                        .textSelection(.enabled)
                }
                if !message.images.isEmpty {
                    ForEach(0..<message.images.count, id: \.self) { index in
                        Button(action: {
                            onImageTap(message.images[index])
                        }) {
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

// MARK: - 4. 主视图 MessagesView

struct MessagesView: View {
    @ObservedObject var serverManager: ServerModelManager
    @State private var newMessage = ""
    @FocusState private var isTextFieldFocused: Bool
    
    // 图片发送选择状态
    @State private var selectedImageForSend: UIImage?
    
    // 图片预览状态
    struct IdentifiableURL: Identifiable {
        let id = UUID()
        let url: URL
    }
    @State private var previewItem: IdentifiableURL?
    
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
                                    onImageTap: { img in
                                        handleImageTap(image: img)
                                    }
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
                            selectedImageForSend = image
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
            
            // ✅ 挂载全屏淡入淡出弹出器
            // 这是一个不可见的 0x0 视图，它负责监听状态并执行 UIKit 弹出
            FullScreenPreviewPresenter(item: $previewItem)
                .frame(width: 0, height: 0)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isTextFieldFocused)
        
        // 发送图片弹窗 (保持 Sheet 不变，因为它是上下文相关的)
        .sheet(item: $selectedImageForSend) { image in
            ImageConfirmationView(
                image: image,
                onCancel: { selectedImageForSend = nil },
                onSend: { imageToSend,isHighQuality  in
                    await serverManager.sendImageMessage(image: imageToSend, isHighQuality: isHighQuality)
                    selectedImageForSend = nil
                }
            )
            .presentationDetents([.medium , .large])
        }
    }
    
    // MARK: - Logic Helpers
    
    private func handleImageTap(image: UIImage) {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "mumble_preview_\(UUID().uuidString).jpg"
        let fileURL = tempDir.appendingPathComponent(fileName)
        
        Task.detached(priority: .userInitiated) {
            if let data = image.jpegData(compressionQuality: 1.0) {
                try? data.write(to: fileURL)
                
                await MainActor.run {
                    self.previewItem = IdentifiableURL(url: fileURL)
                }
            }
        }
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
    
    private func sendImageMessage(image: UIImage, isHighQuality: Bool) async {
        await serverManager.sendImageMessage(image: image, isHighQuality: isHighQuality)
    }
}

// MARK: - Helper Views

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
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .glassEffect(.clear.interactive())
                    
                    Button("Send") {
                        Task {
                            isSending = true
                            await onSend(image, isHighQuality)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .glassEffect(.regular.tint(.blue.opacity(0.7)).interactive())
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
