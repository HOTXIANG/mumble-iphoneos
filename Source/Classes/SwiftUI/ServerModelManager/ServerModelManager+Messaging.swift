//
//  ServerModelManager+Messaging.swift
//  Mumble
//

import SwiftUI

private final class PlatformImageBox: @unchecked Sendable {
    let image: PlatformImage

    init(_ image: PlatformImage) {
        self.image = image
    }
}

extension ServerModelManager {
    func sendTextMessage(_ text: String) {
        guard let serverModel = serverModel, !text.isEmpty else { return }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        MumbleLogger.model.debug("Sending text message (\(trimmedText.count) chars) to current channel")

        // processedHTMLFromPlainTextMessage 会将纯文本转换为带 <p> 标签的 HTML
        let htmlMessage = MUTextMessageProcessor.processedHTML(
            fromPlainTextMessage: trimmedText
        )

        let message = MKTextMessage(string: htmlMessage)

        if let userChannel = serverModel.connectedUser()?.channel() {
            serverModel.send(message, to: userChannel)
        }

        // 立即在UI上显示自己发送的消息，体验更流畅
        let selfMessage = ChatMessage(
            id: UUID(),
            type: .userMessage,
            senderName: serverModel.connectedUser()?.userName() ?? NSLocalizedString("Me", comment: ""),
            attributedMessage: attributedString(from: trimmedText),
            images: [],
            timestamp: Date(),
            isSentBySelf: true,
            senderSession: serverModel.connectedUser()?.session()
        )
        DispatchQueue.main.async {
            self.messages.append(selfMessage)
        }
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
        
        serverModel.send(msg, toTree: userChannel)
        
        let selfMessage = ChatMessage(
            id: UUID(),
            type: .userMessage,
            senderName: serverModel.connectedUser()?.userName() ?? NSLocalizedString("Me", comment: ""),
            attributedMessage: attributedString(from: trimmed),
            images: [],
            timestamp: Date(),
            isSentBySelf: true,
            senderSession: serverModel.connectedUser()?.session()
        )
        DispatchQueue.main.async {
            self.messages.append(selfMessage)
        }
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

    func sendImageMessage(image: PlatformImage) async {
        await sendImageMessageInternal(image: image, targetUser: nil)
    }

    func sendPrivateImageMessage(image: PlatformImage, to user: MKUser) async {
        await sendImageMessageInternal(image: image, targetUser: user)
    }

    private func sendImageMessageInternal(image: PlatformImage, targetUser: MKUser?) async {
        let htmlLimit = effectiveImageHTMLLimit()
        guard let data = await compressImageForHTMLLimitOffMain(image: image, htmlLimit: htmlLimit) else {
            return
        }

        let base64Str = data.base64EncodedString(options: [])
        let htmlBody = "<img src=\"data:image/jpeg;base64,\(base64Str)\" />"
        let msg = MKTextMessage(plainText: htmlBody)

        if let targetUser {
            self.serverModel?.send(msg, to: targetUser)
        } else if let channel = self.serverModel?.connectedUser()?.channel() {
            self.serverModel?.send(msg, to: channel)
        }

        await appendLocalMessage(image: image, targetUser: targetUser)
    }

    private func appendLocalMessage(image: PlatformImage, targetUser: MKUser?) async {
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
        return max(16 * 1024, serverImageMessageLengthBytes ?? fallback)
    }

    private func compressImageForHTMLLimitOffMain(image: PlatformImage, htmlLimit: Int) async -> Data? {
        let imageBox = PlatformImageBox(image)
        return await Task.detached(priority: .userInitiated) {
            Self.compressImageForHTMLLimit(image: imageBox.image, htmlLimit: htmlLimit)
        }.value
    }

    nonisolated private static func compressImageForHTMLLimit(image: PlatformImage, htmlLimit: Int) -> Data? {
        let wrapperLen = "<img src=\"data:image/jpeg;base64,\" />".utf8.count
        let payloadBudget = max(4 * 1024, htmlLimit - wrapperLen)
        let binaryBudget = max(3 * 1024, (payloadBudget * 3) / 4)

        return smartCompress(image: image, to: binaryBudget)
    }

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
