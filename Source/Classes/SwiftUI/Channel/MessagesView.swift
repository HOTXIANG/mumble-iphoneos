// 文件: MessagesView.swift

import SwiftUI
import PhotosUI
import QuickLook
#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif
import UniformTypeIdentifiers

// MARK: - 1. QuickLook 预览包装器 (标准 SwiftUI 实现)
#if os(iOS)
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
#endif

// MARK: - 2. 预览状态模型
struct PreviewItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct PendingSendImage: Identifiable {
    let id = UUID()
    let image: PlatformImage
}

// MARK: - 3. 主容器 (Stable Container)
struct MessagesView: View {
    let serverManager: ServerModelManager
    let isSplitLayout: Bool
    
    // 状态管理中心
    @State private var previewItem: PreviewItem?
    @State private var selectedImageForSend: PendingSendImage?
    
    var body: some View {
        ZStack {
            // 1. 动态内容层
            MessagesList(
                serverManager: serverManager,
                isSplitLayout: isSplitLayout,
                onPreviewRequest: { image in handleImageTap(image: image) },
                onImageSelected: { image in selectedImageForSend = PendingSendImage(image: image) }
            )
            
            // 2. 静态锚点层 (所有弹窗都挂在这里)
            Color.clear
                .allowsHitTesting(false)
                // 挂载查看大图 (QuickLook) — iOS only
                #if os(iOS)
                .fullScreenCover(item: $previewItem) { item in
                    QuickLookPreview(url: item.url)
                        .ignoresSafeArea()
                }
                #endif
                // 挂载发送确认框 (Sheet)
                .sheet(item: $selectedImageForSend) { item in
                    ImageConfirmationView(
                        image: item.image,
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
    
    private func handleImageTap(image: PlatformImage) {
        #if os(macOS)
        AppState.shared.previewImage = image
        #else
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
        #endif
    }
}

#if os(macOS)
/// macOS 图片预览 overlay：全窗口覆盖，支持触控板/鼠标缩放，双击还原，Esc 关闭
struct MacImagePreviewOverlay: View {
    let image: PlatformImage
    let onDismiss: () -> Void
    
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 半透明背景，点击空白区域关闭
                Color.black.opacity(0.88)
                    .ignoresSafeArea()
                    .onTapGesture { onDismiss() }
                
                // 可缩放、可拖拽的图片
                Image(platformImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .frame(maxWidth: geo.size.width * 0.92, maxHeight: geo.size.height * 0.92)
                    // 触控板双指缩放
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in
                                scale = max(0.5, lastScale * value.magnification)
                            }
                            .onEnded { _ in
                                lastScale = scale
                                if scale < 1.0 {
                                    withAnimation(.spring(response: 0.3)) {
                                        scale = 1.0
                                        lastScale = 1.0
                                        offset = .zero
                                        lastOffset = .zero
                                    }
                                }
                            }
                    )
                    // 拖拽平移（放大后移动图片）
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                offset = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                            }
                            .onEnded { _ in
                                lastOffset = offset
                            }
                    )
                    // 双击：放大 2.5x ↔ 还原 1x
                    .onTapGesture(count: 2) {
                        withAnimation(.spring(response: 0.35)) {
                            if scale > 1.05 {
                                scale = 1.0; lastScale = 1.0
                                offset = .zero; lastOffset = .zero
                            } else {
                                scale = 2.5; lastScale = 2.5
                            }
                        }
                    }
                
                // 右上角关闭按钮
                VStack {
                    HStack {
                        Spacer()
                        Button(action: onDismiss) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 28))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                        .padding(16)
                    }
                    Spacer()
                }
            }
        }
        .onExitCommand { onDismiss() } // Esc 键关闭
    }
}
#endif

// MARK: - 4. 消息列表 (Dynamic Content)
// 这个视图负责监听数据变化和 UI 刷新
struct MessagesList: View {
    @ObservedObject var serverManager: ServerModelManager
    let isSplitLayout: Bool
    @Environment(\.colorScheme) private var colorScheme
    
    // 回调函数
    let onPreviewRequest: (PlatformImage) -> Void
    let onImageSelected: (PlatformImage) -> Void
    
    @State private var newMessage = ""
    @FocusState private var isTextFieldFocused: Bool
    @State private var isDragTargeted = false
    
    private let bottomID = "bottomOfMessages"

    private struct SenderIdentity {
        let key: String
        let displayName: String
    }

    private struct SenderMessageRun: Identifiable {
        let id: String
        let type: ChatMessageType
        let displayName: String
        let isSentBySelf: Bool
        let messages: [ChatMessage]
    }

    private enum RenderBlockKind {
        case senderRun(SenderMessageRun)
        case notification(ChatMessage)
    }

    private struct RenderBlock: Identifiable {
        let id: String
        let kind: RenderBlockKind
    }
    
    var body: some View {
        let backgroundColors: [Color] = colorScheme == .dark
            ? [Color(red: 0.20, green: 0.20, blue: 0.25), Color(red: 0.07, green: 0.07, blue: 0.10)]
            : [Color(red: 0.92, green: 0.93, blue: 0.98), Color(red: 0.82, green: 0.85, blue: 0.95)]

        ZStack(alignment: .bottom) {
            // 背景
            LinearGradient(
                gradient: Gradient(colors: backgroundColors),
                startPoint: .top,
                endPoint: .bottom
            ).ignoresSafeArea()
            
            // 消息列表
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: {
                        #if os(macOS)
                        return CGFloat(10)
                        #else
                        return CGFloat(16)
                        #endif
                    }(), pinnedViews: [.sectionHeaders]) {
                        ForEach(renderBlocks) { block in
                            switch block.kind {
                            case .notification(let message):
                                NotificationMessageView(message: message)
                            case .senderRun(let run):
                                Section {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ForEach(Array(run.messages.enumerated()), id: \.element.id) { index, message in
                                            switch run.type {
                                            case .userMessage:
                                                MessageBubbleView(
                                                    message: message,
                                                    onImageTap: onPreviewRequest,
                                                    showSenderName: false,
                                                    showTimestamp: shouldShowTimestamp(in: run.messages, index: index)
                                                )
                                            case .privateMessage:
                                                PrivateMessageBubbleView(
                                                    message: message,
                                                    onImageTap: onPreviewRequest,
                                                    showSenderLabel: false,
                                                    showTimestamp: shouldShowTimestamp(in: run.messages, index: index)
                                                )
                                            case .notification:
                                                NotificationMessageView(message: message)
                                            }
                                        }
                                    }
                                    .padding(.top, -3)
                                } header: {
                                    SenderStickyHeaderView(
                                        title: run.displayName,
                                        isSentBySelf: run.isSentBySelf
                                    )
                                }
                            }
                        }
                        Spacer().frame(height: 10).id(bottomID)
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 16)
                    .padding(.leading, isSplitLayout ? 4 : 16)
                    .padding(.trailing, 16)
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
                .onChange(of: isTextFieldFocused) { _, focused in
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
    private var renderBlocks: [RenderBlock] {
        var blocks: [RenderBlock] = []
        var pendingRunMessages: [ChatMessage] = []
        var pendingRunType: ChatMessageType = .userMessage
        var pendingRunIdentity: SenderIdentity?
        var pendingRunIsSentBySelf = false

        func flushPendingRun() {
            guard let identity = pendingRunIdentity, !pendingRunMessages.isEmpty else { return }
            let runID = "run-\(pendingRunMessages[0].id.uuidString)"
            let run = SenderMessageRun(
                id: runID,
                type: pendingRunType,
                displayName: identity.displayName,
                isSentBySelf: pendingRunIsSentBySelf,
                messages: pendingRunMessages
            )
            blocks.append(RenderBlock(id: runID, kind: .senderRun(run)))
            pendingRunMessages.removeAll(keepingCapacity: true)
            pendingRunIdentity = nil
        }

        for message in serverManager.messages {
            switch message.type {
            case .notification:
                flushPendingRun()
                let blockID = "notification-\(message.id.uuidString)"
                blocks.append(RenderBlock(id: blockID, kind: .notification(message)))
            case .userMessage, .privateMessage:
                let identity = senderIdentity(for: message)
                if let pending = pendingRunIdentity, pending.key == identity.key {
                    pendingRunMessages.append(message)
                } else {
                    flushPendingRun()
                    pendingRunIdentity = identity
                    pendingRunType = message.type
                    pendingRunIsSentBySelf = message.isSentBySelf
                    pendingRunMessages = [message]
                }
            }
        }

        flushPendingRun()
        return blocks
    }

    private func senderIdentity(for message: ChatMessage) -> SenderIdentity {
        switch message.type {
        case .userMessage:
            let displayName = message.senderName
            return SenderIdentity(
                key: "user|\(message.isSentBySelf)|\(displayName)",
                displayName: displayName
            )
        case .privateMessage:
            let peerName = message.privatePeerName ?? message.senderName
            let displayName = message.isSentBySelf ? "PM to \(peerName)" : "PM from \(peerName)"
            return SenderIdentity(
                key: "private|\(message.isSentBySelf)|\(peerName)",
                displayName: displayName
            )
        case .notification:
            return SenderIdentity(
                key: "notification|\(message.id.uuidString)",
                displayName: ""
            )
        }
    }

    private func shouldShowTimestamp(in messages: [ChatMessage], index: Int) -> Bool {
        guard messages.indices.contains(index) else { return false }
        guard index < messages.count - 1 else { return true }
        let current = messages[index].timestamp
        let next = messages[index + 1].timestamp
        return !Calendar.current.isDate(current, equalTo: next, toGranularity: .minute)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.canLoadObject(ofClass: PlatformImage.self) {
                provider.loadObject(ofClass: PlatformImage.self) { image, error in
                    guard let uiImage = image as? PlatformImage else { return }
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
    #if os(macOS)
    private let textSize: CGFloat = 11
    #else
    private let textSize: CGFloat = 13
    #endif
    var body: some View {
        HStack(spacing: 6) {
            Text(message.attributedMessage).fontWeight(.medium)
            Text(message.timestamp, style: .time).font(.caption2).opacity(0.6)
        }
        .font(.system(size: textSize, weight: .medium))
        .foregroundColor(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.systemGray5, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct SenderStickyHeaderView: View {
    let title: String
    let isSentBySelf: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack {
            if isSentBySelf {
                Spacer(minLength: 0)
            }

            if #available(iOS 26.0, macOS 26.0, *) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .modifier(BackdropAdaptiveTextModifier())
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .fixedSize(horizontal: true, vertical: false)
                    .glassEffect(
                        .clear.tint(colorScheme == .light ? Color.black.opacity(0.08) : Color.clear),
                        in: .rect(cornerRadius: 13)
                    )
                    .shadow(
                        color: colorScheme == .light ? .black.opacity(0.12) : .black.opacity(0.10),
                        radius: colorScheme == .light ? 8 : 4,
                        x: 0,
                        y: 2
                    )
            } else {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .modifier(BackdropAdaptiveTextModifier())
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .fixedSize(horizontal: true, vertical: false)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(colorScheme == .light ? Color.black.opacity(0.03) : Color.clear)
                    )
                    .shadow(
                        color: colorScheme == .light ? .black.opacity(0.10) : .black.opacity(0.08),
                        radius: colorScheme == .light ? 6 : 3,
                        x: 0,
                        y: 2
                    )
            }

            if !isSentBySelf {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
    }
}

private struct MessageBubbleView: View {
    let message: ChatMessage
    let onImageTap: (PlatformImage) -> Void
    let showSenderName: Bool
    let showTimestamp: Bool
    
    var body: some View {
        VStack(alignment: message.isSentBySelf ? .trailing : .leading, spacing: 4) {
            if showSenderName && !message.isSentBySelf {
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
                        Button(action: { onImageTap(message.images[index]) }) {
                            Image(platformImage: message.images[index])
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 200)
                                #if os(macOS)
                                .cornerRadius(10)
                                #else
                                .cornerRadius(12)
                                #endif
                        }
                        .buttonStyle(.plain)
                        #if os(macOS)
                        .cornerRadius(10)
                        #else
                        .cornerRadius(12)
                        #endif
                    }
                }
            }
            #if os(macOS)
            .padding(.horizontal, message.images.isEmpty ? 14 : 10)
            .padding(.vertical, 10)
            .background(
                message.isSentBySelf ? Color.accentColor : Color.systemGray3,
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            #else
            .padding(.horizontal, message.images.isEmpty ? 16 : 12)
            .padding(.vertical, 12)
            .background(
                message.isSentBySelf ? Color.accentColor : Color.systemGray3,
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            #endif
            .foregroundColor(message.isSentBySelf ? .white : .primary)
            
            if showTimestamp {
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isSentBySelf ? .trailing : .leading)
    }
}

// MARK: - Private Message Bubble

private struct PrivateMessageBubbleView: View {
    let message: ChatMessage
    let onImageTap: (PlatformImage) -> Void
    let showSenderLabel: Bool
    let showTimestamp: Bool
    
    var body: some View {
        VStack(alignment: message.isSentBySelf ? .trailing : .leading, spacing: 4) {
            // 私聊标签
            if showSenderLabel {
                HStack(spacing: 4) {
                    Image(systemName: "envelope.fill")
                        .font(.system(size: 10))
                    if message.isSentBySelf {
                        Text("PM to \(message.privatePeerName ?? "?")")
                            .font(.system(size: 12, weight: .semibold))
                    } else {
                        Text("PM from \(message.privatePeerName ?? message.senderName)")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .foregroundColor(.purple)
                .padding(.horizontal, 4)
            }
            
            // 消息内容
            VStack(alignment: .leading, spacing: 6) {
                if !message.plainTextMessage.isEmpty {
                    Text(message.attributedMessage)
                        .tint(.pink)
                        .textSelection(.enabled)
                }
                if !message.images.isEmpty {
                    ForEach(0..<message.images.count, id: \.self) { index in
                        Button(action: { onImageTap(message.images[index]) }) {
                            Image(platformImage: message.images[index])
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 200)
                                #if os(macOS)
                                .cornerRadius(10)
                                #else
                                .cornerRadius(12)
                                #endif
                        }
                        .buttonStyle(.plain)
                        #if os(macOS)
                        .cornerRadius(10)
                        #else
                        .cornerRadius(12)
                        #endif
                    }
                }
            }
            #if os(macOS)
            .padding(.horizontal, message.images.isEmpty ? 14 : 10)
            .padding(.vertical, 10)
            .background(
                message.isSentBySelf
                    ? Color.purple.opacity(0.7)
                    : Color.purple.opacity(0.25),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.purple.opacity(0.5), lineWidth: 1)
            )
            #else
            .padding(.horizontal, message.images.isEmpty ? 16 : 12)
            .padding(.vertical, 12)
            .background(
                message.isSentBySelf
                    ? Color.purple.opacity(0.7)
                    : Color.purple.opacity(0.25),
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.purple.opacity(0.5), lineWidth: 1)
            )
            #endif
            
            .foregroundColor(message.isSentBySelf ? .white : .primary)
            
            if showTimestamp {
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isSentBySelf ? .trailing : .leading)
    }
}

struct ImageConfirmationView: View {
    let image: PlatformImage
    let onCancel: () -> Void
    let onSend: (PlatformImage, Bool) async -> Void
    @State private var isSending = false
    @State private var isHighQuality = false
    
    var body: some View {
        VStack(spacing: 20) {
            if isSending {
                VStack(spacing: 20) {
                    ProgressView()
                    Text("Compressing and Sending...")
                        .foregroundColor(.secondary)
                }
                    .padding(.vertical, 60)
                    .padding(.horizontal, 80)
            } else {
                Text("Confirm Image")
                    .font(.headline)
                    .padding(.top, 20)
                
                Image(platformImage: image)
                    .resizable()
                    .scaledToFit()
                    .cornerRadius(12)
                    .padding(.horizontal)
                
                Toggle(isOn: $isHighQuality) {
                    VStack(alignment: .leading) {
                        Text("High Quality Mode")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("Less Compressed")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(SwitchToggleStyle(tint: .blue))
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.secondarySystemBackground)
                .cornerRadius(12)
                .padding(.horizontal)
                
                HStack(spacing: 20) {
                    Button("Cancel", role: .cancel, action: onCancel)
                        .buttonStyle(.bordered).controlSize(.large)
                        .keyboardShortcut(.cancelAction)
                    Button("Send") {
                        Task { isSending = true; await onSend(image, isHighQuality) }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.bottom)
        .interactiveDismissDisabled(isSending)
    }
}

private struct TextInputBar: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool
    let onSendText: () -> Void
    let onSendImage: (PlatformImage) async -> Void
    @State private var selectedPhoto: PhotosPickerItem?
    
    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            modernBody
        } else {
            legacyBody
        }
    }

    private var inputControlShadowColor: Color {
        colorScheme == .light ? .black.opacity(0.18) : .black.opacity(0.28)
    }

    private var inputControlShadowRadius: CGFloat {
        colorScheme == .light ? 6 : 4
    }

    private var inputControlShadowYOffset: CGFloat {
        2
    }
    
    // MARK: - iOS 26+ / macOS 26+ (GlassEffect)
    
    @available(iOS 26.0, macOS 26.0, *)
    private var modernBody: some View {
        GlassEffectContainer(spacing: 10.0) {
            HStack(alignment: .bottom, spacing: 10.0) {
                photoPickerView
                    .glassEffect(.clear.interactive().tint(photoPickerGlassTint), in: .circle)
                    .shadow(color: inputControlShadowColor, radius: inputControlShadowRadius, x: 0, y: inputControlShadowYOffset)
                
                messageTextField
                    .glassEffect(.clear.interactive().tint(messageFieldGlassTint), in: .rect(cornerRadius: 20.0))
                    .shadow(color: inputControlShadowColor, radius: inputControlShadowRadius, x: 0, y: inputControlShadowYOffset)
                
                sendButton
                    .glassEffect(.clear.interactive().tint(sendButtonGlassTint), in: .circle)
                    .shadow(color: inputControlShadowColor, radius: inputControlShadowRadius, x: 0, y: inputControlShadowYOffset)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    private var photoPickerGlassTint: Color {
        colorScheme == .light ? Color.black.opacity(0.14) : Color.clear
    }

    @available(iOS 26.0, macOS 26.0, *)
    private var messageFieldGlassTint: Color {
        colorScheme == .light ? Color.black.opacity(0.10) : Color.clear
    }

    @available(iOS 26.0, macOS 26.0, *)
    private var sendButtonGlassTint: Color {
        if text.isEmpty {
            return colorScheme == .light ? .gray.opacity(0.55) : .gray.opacity(0.7)
        }
        return colorScheme == .light ? .blue.opacity(0.52) : .blue.opacity(0.7)
    }
    
    // MARK: - Fallback (Material)
    
    private var legacyBody: some View {
        HStack(alignment: .bottom, spacing: 10.0) {
            photoPickerView
                .shadow(color: inputControlShadowColor, radius: inputControlShadowRadius, x: 0, y: inputControlShadowYOffset)
            
            messageTextField
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(colorScheme == .light ? Color.black.opacity(0.06) : Color.clear)
                )
                .shadow(color: inputControlShadowColor, radius: inputControlShadowRadius, x: 0, y: inputControlShadowYOffset)
            
            sendButton
                .background(
                    Circle()
                        .fill(text.isEmpty ? Color.gray.opacity(0.5) : Color.blue)
                )
                .shadow(color: inputControlShadowColor, radius: inputControlShadowRadius, x: 0, y: inputControlShadowYOffset)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    // MARK: - Shared Components
    
    private var photoPickerView: some View {
        PhotosPicker(selection: $selectedPhoto, matching: .images) {
            Image(systemName: "photo.on.rectangle.angled")
                #if os(macOS)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.indigo)
                .frame(width: 32, height: 32)
                #else
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.indigo)
                .frame(width: 40, height: 40)
                #endif
        }
        #if os(macOS)
        .frame(width: 32, height: 32)
        #else
        .frame(width: 40, height: 40)
        #endif
        .clipShape(Circle())
        .contentShape(Circle())
        .onChange(of: selectedPhoto) {
            Task {
                if let data = try? await selectedPhoto?.loadTransferable(type: Data.self),
                   let image = PlatformImage(data: data) {
                    await onSendImage(image)
                }
                selectedPhoto = nil
            }
        }
    }
    
    private var messageTextField: some View {
        TextField(
            "",
            text: $text,
            prompt: Text("Type a message..."),
            axis: .vertical
        )
            .modifier(BackdropAdaptiveTextModifier(opacity: text.isEmpty ? 0.58 : 1.0))
            .focused($isFocused)
            #if os(macOS)
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 32)
            .textFieldStyle(.plain)
            #else
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 40)
            #endif
            #if os(macOS)
            .onSubmit { onSendText() }
            .onKeyPress(.return, phases: .down) { keyPress in
                if keyPress.modifiers.contains(.command) {
                    text += "\n"
                    return .handled
                }
                return .ignored
            }
            // macOS: 当剪贴板里只有图片（无字符串）时，NSTextField 会把系统 Paste 菜单置灰。
            // 这里直接拦截 ⌘V，从 NSPasteboard 读图并触发发送图片弹窗。
            .onKeyPress(KeyEquivalent("v"), phases: .down) { keyPress in
                guard keyPress.modifiers.contains(.command) else { return .ignored }
                return handleMacPasteFromPasteboard() ? .handled : .ignored
            }
            .onPasteCommand(of: [.image]) { providers in
                handlePastedImages(providers)
            }
            #endif
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    #if os(macOS)
    private func handleMacPasteFromPasteboard() -> Bool {
        let pb = NSPasteboard.general

        if let image = NSImage(pasteboard: pb) {
            Task { @MainActor in
                isFocused = false
                await onSendImage(image)
            }
            return true
        }

        // Fallback: data representation (png/tiff/etc.)
        if let data = pb.data(forType: .png), let image = NSImage(data: data) {
            Task { @MainActor in
                isFocused = false
                await onSendImage(image)
            }
            return true
        }
        if let data = pb.data(forType: .tiff), let image = NSImage(data: data) {
            Task { @MainActor in
                isFocused = false
                await onSendImage(image)
            }
            return true
        }

        return false
    }
    #endif

    private func handlePastedImages(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.canLoadObject(ofClass: PlatformImage.self) {
                provider.loadObject(ofClass: PlatformImage.self) { object, _ in
                    guard let image = object as? PlatformImage else { return }
                    Task { @MainActor in
                        // 粘贴图片时通常会弹出确认弹窗；先收起键盘/取消焦点
                        isFocused = false
                        await onSendImage(image)
                    }
                }
                return
            }

            // Fallback: some apps provide image data rather than an object
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let image = PlatformImage(data: data) else { return }
                    Task { @MainActor in
                        isFocused = false
                        await onSendImage(image)
                    }
                }
                return
            }
        }
    }
    
    private var sendButton: some View {
        Button(action: onSendText) {
            Image(systemName: "arrow.up")
                #if os(macOS)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                #else
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 40, height: 40)
                #endif
        }
        #if os(macOS)
        .frame(width: 32, height: 32)
        #else
        .frame(width: 40, height: 40)
        #endif
        .clipShape(Circle())
        .contentShape(Circle())
        .buttonStyle(.plain)
        .disabled(text.isEmpty)
    }
}

private struct BackdropAdaptiveTextModifier: ViewModifier {
    var opacity: Double = 1.0

    func body(content: Content) -> some View {
        content
            .foregroundColor(.white.opacity(opacity))
            .blendMode(.difference)
    }
}

extension CGSize {
    static func + (lhs: CGSize, rhs: CGSize) -> CGSize {
        return CGSize(width: lhs.width + rhs.width, height: lhs.height + rhs.height)
    }
}
