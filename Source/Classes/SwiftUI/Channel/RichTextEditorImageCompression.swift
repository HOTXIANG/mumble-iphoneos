//
//  RichTextEditorImageCompression.swift
//  Mumble
//
//  Extracted image compression helpers for rich text editor.
//

import Foundation
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

extension WYSIWYGEditorView.Coordinator {
    func compressedImageDataURL(from rawDataURL: String, maxBytes: Int) -> String? {
        guard let sourceData = Self.dataFromDataURLString(rawDataURL),
              let image = PlatformImage(data: sourceData),
              let jpegData = Self.smartCompress(image: image, to: maxBytes) else {
            return nil
        }
        return "data:image/jpeg;base64,\(jpegData.base64EncodedString())"
    }

    nonisolated static func compressEmbeddedImagesInHTML(_ html: String, maxBytesPerImage: Int) -> String {
        let pattern = "data:image\\/[a-zA-Z0-9.+-]+;base64,[^\"'<>\\s]+"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return html
        }

        let ns = html as NSString
        let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return html }

        var result = html
        var didReplace = false

        for match in matches.reversed() {
            let currentNSString = result as NSString
            guard match.range.location != NSNotFound,
                  match.range.location + match.range.length <= currentNSString.length else { continue }

            let dataURL = currentNSString.substring(with: match.range)
            guard let sourceData = Self.dataFromDataURLString(dataURL),
                  let image = PlatformImage(data: sourceData),
                  let compressed = Self.smartCompress(image: image, to: maxBytesPerImage) else {
                continue
            }
            // 只有确实变小才替换，减少无意义重写
            guard compressed.count < sourceData.count else { continue }

            let replacement = "data:image/jpeg;base64,\(compressed.base64EncodedString())"
            result = currentNSString.replacingCharacters(in: match.range, with: replacement)
            didReplace = true
        }

        return didReplace ? result : html
    }

    nonisolated static func dataFromDataURLString(_ dataURLString: String) -> Data? {
        guard dataURLString.hasPrefix("data:"),
              let commaRange = dataURLString.range(of: ",") else {
            return nil
        }
        var base64String = String(dataURLString[commaRange.upperBound...])
        base64String = base64String.components(separatedBy: .whitespacesAndNewlines).joined()
        base64String = base64String.removingPercentEncoding ?? base64String
        return Data(base64Encoded: base64String, options: .ignoreUnknownCharacters)
    }

    // 与发送图片同策略：先降分辨率，避免过早把 JPEG 质量压得太低。
    nonisolated static func smartCompress(image: PlatformImage, to maxBytes: Int) -> Data? {
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
        if maxDim > 1536 { resolutionTiers.append(1536) }
        if maxDim > 1024 { resolutionTiers.append(1024) }
        if maxDim > 768  { resolutionTiers.append(768) }
        if maxDim > 512  { resolutionTiers.append(512) }

        for tier in resolutionTiers {
            let workingImage: PlatformImage = tier < maxDim ? Self.resizeImage(image: image, maxDimension: tier) : image

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
                    return data
                }
                continue
            }
        }

        let smallest = Self.resizeImage(image: image, maxDimension: 512)
        return smallest.jpegData(compressionQuality: 0.2)
    }

    nonisolated static func resizeImage(image: PlatformImage, maxDimension: CGFloat) -> PlatformImage {
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
        format.opaque = true
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: newSize))
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        #else
        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: newSize)).fill()
        image.draw(in: NSRect(origin: .zero, size: newSize))
        newImage.unlockFocus()
        return newImage
        #endif
    }
}
