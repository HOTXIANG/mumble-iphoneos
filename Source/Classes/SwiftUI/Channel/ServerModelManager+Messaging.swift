//
//  ServerModelManager+Messaging.swift
//  Mumble
//

import SwiftUI

private final class MessageSendFailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false

    func markFailed() {
        lock.lock()
        failed = true
        lock.unlock()
    }

    var didFail: Bool {
        lock.lock()
        defer { lock.unlock() }
        return failed
    }
}

extension ServerModelManager {
    func sendTextMessage(_ text: String) {
        guard let serverModel = serverModel, !text.isEmpty else { return }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

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
            senderName: serverModel.connectedUser()?.userName() ?? "Me",
            attributedMessage: attributedString(from: trimmedText),
            images: [],
            timestamp: Date(),
            isSentBySelf: true
        )
        messages.append(selfMessage)
    }

    func sendPrivateMessage(_ text: String, to user: MKUser) {
        guard let serverModel = serverModel, !text.isEmpty else { return }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let htmlMessage = MUTextMessageProcessor.processedHTML(fromPlainTextMessage: trimmedText)
        let message = MKTextMessage(string: htmlMessage)

        serverModel.send(message, to: user)

        // 立即在 UI 上显示自己发送的私聊
        let targetName = user.userName() ?? "Unknown"
        let selfMessage = ChatMessage(
            type: .privateMessage,
            senderName: serverModel.connectedUser()?.userName() ?? "Me",
            attributedMessage: attributedString(from: trimmedText),
            timestamp: Date(),
            isSentBySelf: true,
            privatePeerName: targetName
        )
        messages.append(selfMessage)
    }

    func sendImageMessage(image: PlatformImage, isHighQuality: Bool) async {
        if isHighQuality {
            // 高画质模式：从 1MB 开始，失败后缓慢降级
            await attemptSendImage(image: image, targetSize: 1024 * 1024, decayRate: 0.9)
        } else {
            // 兼容模式：目标 90KB（考虑 Base64 开销）
            await attemptSendImage(image: image, targetSize: 90 * 1024, decayRate: 0.9)
        }
    }

    private func attemptSendImage(image: PlatformImage, targetSize: Int, decayRate: Double) async {
        // 保底 20KB，再小没意义了
        guard targetSize > 20 * 1024 else {
            print("❌ Image too small to compress further. Give up.")
            return
        }

        print("🚀 [High Quality] Attempting size: \(targetSize / 1024) KB")

        guard let data = await smartCompress(image: image, to: targetSize) else { return }

        let base64Str = data.base64EncodedString()
        let htmlBody = "<img src=\"data:image/jpeg;base64,\(base64Str)\" />"
        let msg = MKTextMessage(plainText: htmlBody)

        let failName = Notification.Name("MUMessageSendFailed")
        let task = Task {
            if let channel = self.serverModel?.connectedUser()?.channel() {
                self.serverModel?.send(msg, to: channel)
            }
            try? await Task.sleep(nanoseconds: 800 * 1_000_000)
        }

        let failureBox = MessageSendFailureBox()
        let observer = NotificationCenter.default.addObserver(forName: failName, object: nil, queue: .main) { _ in
            failureBox.markFailed()
        }
        _ = await task.result
        NotificationCenter.default.removeObserver(observer)

        if failureBox.didFail {
            print("⚠️ Send failed. Reducing size by 10%...")
            let newTarget = Int(Double(targetSize) * decayRate)
            await attemptSendImage(image: image, targetSize: newTarget, decayRate: decayRate)
        } else {
            print("✅ Send success!")
            await appendLocalMessage(image: image)
        }
    }

    private func appendLocalMessage(image: PlatformImage) async {
        await MainActor.run {
            let localMessage = ChatMessage(
                id: UUID(),
                type: .userMessage,
                senderName: self.serverModel?.connectedUser()?.userName() ?? "Me",
                attributedMessage: AttributedString(""),
                images: [image],
                timestamp: Date(),
                isSentBySelf: true
            )
            self.messages.append(localMessage)
        }
    }

    // 智能压缩算法：先降分辨率再降质量，优先保画质
    private func smartCompress(image: PlatformImage, to maxBytes: Int) async -> Data? {
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
        for dim in [1536, 1024, 768, 512] as [CGFloat] {
            if dim < resolutionTiers.last! {
                resolutionTiers.append(dim)
            }
        }

        for tier in resolutionTiers {
            let workingImage: PlatformImage
            if tier < maxDim {
                workingImage = resizeImage(image: image, maxDimension: tier)
            } else {
                workingImage = image
            }

            var lo: CGFloat = 0.05
            var hi: CGFloat = 1.0
            var bestData: Data? = nil
            var bestQuality: CGFloat = 0

            for _ in 0..<8 {
                let mid = (lo + hi) / 2
                if let data = workingImage.jpegData(compressionQuality: mid) {
                    if data.count <= maxBytes {
                        bestData = data
                        bestQuality = mid
                        lo = mid
                    } else {
                        hi = mid
                    }
                }
            }

            if let data = bestData {
                if bestQuality >= 0.3 || tier <= 512 {
                    let tierStr = tier < maxDim ? "resized to \(Int(tier))px" : "original"
                    print("📸 Compressed: \(tierStr), quality=\(String(format: "%.2f", bestQuality)), size=\(data.count/1024)KB")
                    return data
                }
                print("📸 Quality \(String(format: "%.2f", bestQuality)) too low at \(Int(tier))px, trying smaller resolution...")
                continue
            }
        }

        print("⚠️ Fallback: minimum resolution + minimum quality")
        let smallest = resizeImage(image: image, maxDimension: 512)
        return smallest.jpegData(compressionQuality: 0.2)
    }

    /// 保持比例缩放图片（指定长边最大像素数），修复白色边线问题
    private func resizeImage(image: PlatformImage, maxDimension: CGFloat) -> PlatformImage {
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
