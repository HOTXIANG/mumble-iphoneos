//
//  ServerModelManager+Messaging.swift
//  Mumble
//

import SwiftUI
#if os(macOS)
import ImageIO
import UniformTypeIdentifiers
#endif

private final class PlatformImageBox: @unchecked Sendable {
    let image: PlatformImage

    init(_ image: PlatformImage) {
        self.image = image
    }
}

#if os(macOS)
private final class CGImageBox: @unchecked Sendable {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}
#endif

extension ServerModelManager {
    func sendTextMessage(_ text: String) {
        guard let serverModel = serverModel, !text.isEmpty else { return }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        MumbleLogger.model.debug("Sending text message (\(trimmedText.count) chars) to current channel")
        guard let userChannel = serverModel.connectedUser()?.channel() else { return }

        // processedHTMLFromPlainTextMessage 会将纯文本转换为带 <p> 标签的 HTML
        let htmlMessage = MUTextMessageProcessor.processedHTML(
            fromPlainTextMessage: trimmedText
        )

        let message = MKTextMessage(string: htmlMessage)

        // 立即在UI上显示自己发送的消息，体验更流畅
        let messageID = UUID()
        let selfMessage = ChatMessage(
            id: messageID,
            type: .userMessage,
            senderName: serverModel.connectedUser()?.userName() ?? NSLocalizedString("Me", comment: ""),
            attributedMessage: attributedString(from: trimmedText),
            images: [],
            timestamp: Date(),
            isSentBySelf: true,
            senderSession: serverModel.connectedUser()?.session()
        )
        messages.append(selfMessage)

        if !hasTextMessagePermissionIfKnown(for: userChannel) {
            markOutgoingMessageFailed(
                id: messageID,
                reason: NSLocalizedString("You do not have permission to send messages in this channel.", comment: "")
            )
            return
        }

        trackPendingOutgoingMessage(id: messageID)
        serverModel.send(message, to: userChannel)
    }

    /// 发送文本消息到当前频道及其所有子频道（频道树）
    func sendTextMessageToTree(_ text: String) {
        guard let serverModel = serverModel, !text.isEmpty else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let userChannel = serverModel.connectedUser()?.channel() else {
            MumbleLogger.model.warning("sendTextMessageToTree: no connected user channel")
            return
        }
        MumbleLogger.model.debug("Sending tree message to channel '\(userChannel.channelName() ?? "")'")

        
        let htmlMessage = MUTextMessageProcessor.processedHTML(fromPlainTextMessage: trimmed)
        let msg = MKTextMessage(string: htmlMessage)

        let messageID = UUID()
        let selfMessage = ChatMessage(
            id: messageID,
            type: .userMessage,
            senderName: serverModel.connectedUser()?.userName() ?? NSLocalizedString("Me", comment: ""),
            attributedMessage: attributedString(from: trimmed),
            images: [],
            timestamp: Date(),
            isSentBySelf: true,
            senderSession: serverModel.connectedUser()?.session()
        )
        messages.append(selfMessage)

        if !hasTextMessagePermissionIfKnown(for: userChannel) {
            markOutgoingMessageFailed(
                id: messageID,
                reason: NSLocalizedString("You do not have permission to send messages in this channel.", comment: "")
            )
            return
        }

        trackPendingOutgoingMessage(id: messageID)
        serverModel.send(msg, toTree: userChannel)
    }

    func sendPrivateMessage(_ text: String, to user: MKUser) {
        guard let serverModel = serverModel, !text.isEmpty else { return }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let htmlMessage = MUTextMessageProcessor.processedHTML(fromPlainTextMessage: trimmedText)
        let message = MKTextMessage(string: htmlMessage)

        serverModel.send(message, to: user)

        // 立即在 UI 上显示自己发送的私聊
        let targetName = user.userName() ?? NSLocalizedString("Unknown", comment: "")
        let selfMessage = ChatMessage(
            type: .privateMessage,
            senderName: serverModel.connectedUser()?.userName() ?? NSLocalizedString("Me", comment: ""),
            attributedMessage: attributedString(from: trimmedText),
            timestamp: Date(),
            isSentBySelf: true,
            senderSession: serverModel.connectedUser()?.session(),
            privatePeerName: targetName
        )
        DispatchQueue.main.async {
            self.messages.append(selfMessage)
        }
    }

    func handleTextMessagePermissionDenied(reason: String? = nil) {
        let cutoff = Date().addingTimeInterval(-15)
        pendingOutgoingMessages.removeAll { $0.createdAt < cutoff }
        guard let pending = pendingOutgoingMessages.last else {
            postMessagePermissionDeniedToast(reason: reason)
            return
        }
        markOutgoingMessageFailed(
            id: pending.id,
            reason: reason ?? NSLocalizedString("You do not have permission to send messages in this channel.", comment: "")
        )
    }

    private func hasTextMessagePermissionIfKnown(for channel: MKChannel) -> Bool {
        guard let permissions = channelPermissions[channel.channelId()] else {
            return true
        }
        return (permissions & MKPermissionTextMessage.rawValue) != 0
    }

    private func trackPendingOutgoingMessage(id: UUID) {
        pendingOutgoingMessages.append((id: id, createdAt: Date()))
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) { [weak self] in
            Task { @MainActor [weak self] in
                self?.pendingOutgoingMessages.removeAll { $0.id == id }
            }
        }
    }

    private func markOutgoingMessageFailed(id: UUID, reason: String) {
        pendingOutgoingMessages.removeAll { $0.id == id }
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            postMessagePermissionDeniedToast(reason: reason)
            return
        }

        let current = messages[index]
        messages[index] = ChatMessage(
            id: current.id,
            type: current.type,
            senderName: current.senderName,
            attributedMessage: current.attributedMessage,
            images: current.images,
            imageData: current.imageData,
            timestamp: current.timestamp,
            isSentBySelf: current.isSentBySelf,
            senderSession: current.senderSession,
            privatePeerName: current.privatePeerName,
            deliveryState: .failed
        )
        postMessagePermissionDeniedToast(reason: reason)
    }

    private func postMessagePermissionDeniedToast(reason: String?) {
        let message = reason?.isEmpty == false
            ? reason!
            : NSLocalizedString("You do not have permission to send messages in this channel.", comment: "")
        NotificationCenter.default.post(
            name: .muAppShowMessage,
            object: nil,
            userInfo: [
                "message": message,
                "type": "error",
                "jumpToMessages": true
            ]
        )
    }

    func sendImageMessage(image: PlatformImage) async {
        await sendImageMessageInternal(image: image, targetUser: nil)
    }

    func sendPrivateImageMessage(image: PlatformImage, to user: MKUser) async {
        await sendImageMessageInternal(image: image, targetUser: user)
    }

    private func sendImageMessageInternal(image: PlatformImage, targetUser: MKUser?) async {
        guard let serverModel else {
            reportImageSendFailure(NSLocalizedString("Not connected to a server.", comment: "Image send failure"))
            return
        }

        let channel: MKChannel?
        if targetUser == nil {
            channel = serverModel.connectedUser()?.channel()
            guard channel != nil else {
                reportImageSendFailure(NSLocalizedString("No channel is available for this image.", comment: "Image send failure"))
                return
            }
        } else {
            channel = nil
        }

        let htmlLimit = effectiveImageHTMLLimit()
        guard let data = await compressImageForHTMLLimitOffMain(image: image, htmlLimit: htmlLimit) else {
            reportImageSendFailure(NSLocalizedString("The image could not be prepared within the server size limit.", comment: "Image send failure"))
            return
        }

        let base64Str = data.base64EncodedString(options: [])
        let htmlBody = "<img src=\"data:image/jpeg;base64,\(base64Str)\" />"
        guard htmlBody.utf8.count <= htmlLimit else {
            reportImageSendFailure(NSLocalizedString("The prepared image exceeds the server size limit.", comment: "Image send failure"))
            return
        }
        let msg = MKTextMessage(plainText: htmlBody)

        if let targetUser {
            serverModel.send(msg, to: targetUser)
        } else if let channel {
            serverModel.send(msg, to: channel)
        }

        await appendLocalMessage(image: image, imageData: data, targetUser: targetUser)
    }

    private func reportImageSendFailure(_ message: String) {
        MumbleLogger.general.error("Image send failed: \(message)")
        NotificationCenter.default.post(
            name: .muAppShowMessage,
            object: nil,
            userInfo: [
                "message": message,
                "type": "error",
                "jumpToMessages": true
            ]
        )
    }

    private func appendLocalMessage(image: PlatformImage, imageData: Data, targetUser: MKUser?) async {
        await MainActor.run {
            let selfName = self.serverModel?.connectedUser()?.userName() ?? NSLocalizedString("Me", comment: "")
            let localMessage: ChatMessage
            if let targetUser {
                let targetName = targetUser.userName() ?? NSLocalizedString("Unknown", comment: "")
                localMessage = ChatMessage(
                    id: UUID(),
                    type: .privateMessage,
                    senderName: selfName,
                    attributedMessage: AttributedString(""),
                    images: [image],
                    imageData: [imageData],
                    timestamp: Date(),
                    isSentBySelf: true,
                    senderSession: self.serverModel?.connectedUser()?.session(),
                    privatePeerName: targetName
                )
            } else {
                localMessage = ChatMessage(
                    id: UUID(),
                    type: .userMessage,
                    senderName: selfName,
                    attributedMessage: AttributedString(""),
                    images: [image],
                    imageData: [imageData],
                    timestamp: Date(),
                    isSentBySelf: true,
                    senderSession: self.serverModel?.connectedUser()?.session()
                )
            }
            self.messages.append(localMessage)
        }
    }

    private func effectiveImageHTMLLimit() -> Int {
        // Same baseline as desktop Mumble's default uiImageLength.
        let fallback = 128 * 1024
        guard let serverLimit = serverImageMessageLengthBytes, serverLimit > 0 else {
            return fallback
        }
        return serverLimit
    }

    private func compressImageForHTMLLimitOffMain(image: PlatformImage, htmlLimit: Int) async -> Data? {
        #if os(macOS)
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }
        let imageBox = CGImageBox(cgImage)
        return await Task.detached(priority: .userInitiated) {
            Self.compressCGImageForHTMLLimit(image: imageBox.image, htmlLimit: htmlLimit)
        }.value
        #else
        let imageBox = PlatformImageBox(image)
        return await Task.detached(priority: .userInitiated) {
            Self.compressImageForHTMLLimit(image: imageBox.image, htmlLimit: htmlLimit)
        }.value
        #endif
    }

    nonisolated private static func compressImageForHTMLLimit(image: PlatformImage, htmlLimit: Int) -> Data? {
        let wrapperLen = "<img src=\"data:image/jpeg;base64,\" />".utf8.count
        let payloadBudget = htmlLimit - wrapperLen
        guard payloadBudget >= 4 else { return nil }
        // Base64 emits four characters for every three input bytes. Keeping the
        // binary budget on a complete three-byte group guarantees the final HTML
        // does not cross the server-advertised limit because of padding.
        let binaryBudget = (payloadBudget / 4) * 3

        return smartCompress(image: image, to: binaryBudget)
    }

    #if os(macOS)
    nonisolated private static func compressCGImageForHTMLLimit(image: CGImage, htmlLimit: Int) -> Data? {
        let wrapperLen = "<img src=\"data:image/jpeg;base64,\" />".utf8.count
        let payloadBudget = htmlLimit - wrapperLen
        guard payloadBudget >= 4 else { return nil }
        let binaryBudget = (payloadBudget / 4) * 3
        return smartCompress(cgImage: image, to: binaryBudget)
    }

    /// Core Graphics/ImageIO 全程在后台压缩，避免 NSImage.lockFocus/tiffRepresentation
    /// 反复触发 AppKit 绘制，并根据首轮大小直接估算下一档分辨率。
    nonisolated private static func smartCompress(cgImage: CGImage, to maxBytes: Int) -> Data? {
        let originalMaxDimension = CGFloat(max(cgImage.width, cgImage.height))
        guard var workingImage = opaqueCGImage(
            from: cgImage,
            maxDimension: min(originalMaxDimension, 2048)
        ) else {
            return nil
        }

        guard let initialData = jpegData(from: workingImage, quality: 0.86) else {
            return nil
        }
        if initialData.count <= maxBytes {
            return initialData
        }

        var currentMaxDimension = CGFloat(max(workingImage.width, workingImage.height))
        let estimatedRatio = sqrt(CGFloat(maxBytes) / CGFloat(initialData.count))
        let estimatedDimension = max(
            640,
            min(currentMaxDimension * 0.88, currentMaxDimension * estimatedRatio * 1.22)
        )
        if estimatedDimension < currentMaxDimension - 1,
           let estimatedImage = opaqueCGImage(from: workingImage, maxDimension: estimatedDimension) {
            workingImage = estimatedImage
            currentMaxDimension = CGFloat(max(workingImage.width, workingImage.height))
        }

        var fallbackData: Data?
        for _ in 0..<4 {
            var lowQuality: CGFloat = 0.18
            var highQuality: CGFloat = 0.9
            var bestData: Data?
            var bestQuality: CGFloat = 0

            for _ in 0..<5 {
                let quality = (lowQuality + highQuality) * 0.5
                guard let candidate = jpegData(from: workingImage, quality: quality) else { continue }
                if candidate.count <= maxBytes {
                    bestData = candidate
                    bestQuality = quality
                    lowQuality = quality
                } else {
                    highQuality = quality
                }
            }

            if let bestData {
                fallbackData = bestData
                if bestQuality >= 0.42 || currentMaxDimension <= 700 {
                    return bestData
                }
            }

            let nextDimension = max(512, floor(currentMaxDimension * 0.76))
            guard nextDimension < currentMaxDimension - 1,
                  let nextImage = opaqueCGImage(from: workingImage, maxDimension: nextDimension) else {
                break
            }
            workingImage = nextImage
            currentMaxDimension = CGFloat(max(workingImage.width, workingImage.height))
        }

        if let fallbackData {
            return fallbackData
        }

        // Highly detailed/noisy images can still exceed a small server limit at
        // 512 px. Continue reducing resolution and only return validated data.
        for dimension in [384, 320, 256, 192, 128, 96] as [CGFloat] {
            guard dimension < currentMaxDimension,
                  let reducedImage = opaqueCGImage(from: workingImage, maxDimension: dimension) else {
                continue
            }
            workingImage = reducedImage
            currentMaxDimension = CGFloat(max(workingImage.width, workingImage.height))
            for quality in [0.18, 0.12, 0.08] as [CGFloat] {
                if let candidate = jpegData(from: workingImage, quality: quality),
                   candidate.count <= maxBytes {
                    return candidate
                }
            }
        }
        return nil
    }

    nonisolated private static func opaqueCGImage(from image: CGImage, maxDimension: CGFloat) -> CGImage? {
        let sourceWidth = CGFloat(image.width)
        let sourceHeight = CGFloat(image.height)
        let sourceMaxDimension = max(sourceWidth, sourceHeight)
        let ratio = min(maxDimension / max(sourceMaxDimension, 1), 1)
        let width = max(1, Int(floor(sourceWidth * ratio)))
        let height = max(1, Int(floor(sourceHeight * ratio)))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else {
            return nil
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    nonisolated private static func jpegData(from image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let properties = [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
    #endif

    // 沿用现有流程：先降分辨率，再用二分搜索 JPEG 质量。
    nonisolated private static func smartCompress(image: PlatformImage, to maxBytes: Int) -> Data? {
        if let data = image.jpegData(compressionQuality: 1.0), data.count <= maxBytes {
            return data
        }

        #if os(iOS)
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        #else
        let pixelWidth = image.size.width
        let pixelHeight = image.size.height
        #endif
        let maxDim = max(pixelWidth, pixelHeight)

        var resolutionTiers: [CGFloat] = []
        if maxDim > 2048 {
            resolutionTiers.append(2048)
        } else {
            resolutionTiers.append(maxDim)
        }
        for dim in [
            1920, 1792, 1664, 1536, 1408, 1280,
            1152, 1024, 896, 832, 768, 704, 640, 576, 512
        ] as [CGFloat] {
            if dim < resolutionTiers.last! {
                resolutionTiers.append(dim)
            }
        }

        for tier in resolutionTiers {
            let workingImage = tier < maxDim ? resizeImage(image: image, maxDimension: tier) : image

            var lo: CGFloat = 0.05
            var hi: CGFloat = 1.0
            var bestData: Data?
            var bestQuality: CGFloat = 0

            // Fewer quality probes per tier so we downscale earlier.
            for _ in 0..<4 {
                let mid = (lo + hi) / 2
                guard let data = workingImage.jpegData(compressionQuality: mid) else { continue }
                if data.count <= maxBytes {
                    bestData = data
                    bestQuality = mid
                    lo = mid
                } else {
                    hi = mid
                }
            }

            if let data = bestData {
                if bestQuality >= 0.5 || tier <= 640 {
                    return data
                }
                continue
            }
        }

        let smallest = resizeImage(image: image, maxDimension: 512)
        return smallest.jpegData(compressionQuality: 0.2)
    }

    /// 保持比例缩放图片（指定长边最大像素数），修复白色边线问题
    nonisolated private static func resizeImage(image: PlatformImage, maxDimension: CGFloat) -> PlatformImage {
        #if os(iOS)
        let pixelW = image.size.width * image.scale
        let pixelH = image.size.height * image.scale
        #else
        let pixelW = image.size.width
        let pixelH = image.size.height
        #endif

        let currentMax = max(pixelW, pixelH)
        guard currentMax > maxDimension else { return image }

        let ratio = maxDimension / currentMax
        let newW = floor(pixelW * ratio)
        let newH = floor(pixelH * ratio)
        let newSize = CGSize(width: newW, height: newH)

        #if os(iOS)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: newSize))
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        #else
        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSColor.white.setFill()
        NSRect(origin: .zero, size: newSize).fill()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .sourceOver, fraction: 1.0)
        newImage.unlockFocus()
        return newImage
        #endif
    }
}
