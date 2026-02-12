//
//  PlatformTypes.swift
//  Mumble
//
//  Cross-platform type aliases for iOS/macOS multiplatform support
//

import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage

extension Image {
    init(platformImage: PlatformImage) {
        self.init(uiImage: platformImage)
    }
}

#elseif canImport(AppKit)
import AppKit
public typealias PlatformImage = NSImage

extension Image {
    init(platformImage: PlatformImage) {
        self.init(nsImage: platformImage)
    }
}

extension NSImage {
    /// Compatibility shim for UIImage.jpegData(compressionQuality:)
    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let tiffData = self.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }
}

// Cross-platform system colors (macOS)
extension Color {
    static var systemGray4: Color { Color(nsColor: .systemGray).opacity(0.5) }
    static var systemGray5: Color { Color(nsColor: .systemGray).opacity(0.35) }
    static var secondarySystemBackground: Color { Color(nsColor: .controlBackgroundColor) }
}
#endif

#if canImport(UIKit)
// Cross-platform system colors (iOS)
extension Color {
    static var systemGray4: Color { Color(uiColor: .systemGray4) }
    static var systemGray5: Color { Color(uiColor: .systemGray5) }
    static var secondarySystemBackground: Color { Color(uiColor: .secondarySystemBackground) }
}
#endif

// MARK: - GlassEffect Availability Wrapper

/// ViewModifier that applies glassEffect when available (iOS 26.0+ / macOS 26.0+),
/// falls back to a simple background on older versions.
struct GlassEffectModifier: ViewModifier {
    var cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

/// Red-tinted glass capsule for cancel/destructive buttons.
/// iOS 26+/macOS 26+: `.glassEffect(.regular.tint(.red))` in Capsule
/// Fallback: solid red translucent capsule background
struct RedGlassCapsuleModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular.tint(.red.opacity(0.5)).interactive(), in: Capsule())
        } else {
            content.background(.red.opacity(0.6), in: Capsule())
        }
    }
}

/// Tinted glass row highlight for channel/user rows.
/// iOS 26+: `.glassEffect(.clear.interactive().tint(...))` rounded rect
/// Fallback: translucent background color
struct TintedGlassRowModifier: ViewModifier {
    var isHighlighted: Bool
    var highlightColor: Color
    var cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(
                .clear.interactive().tint(isHighlighted ? highlightColor.opacity(0.5) : highlightColor.opacity(0.0)),
                in: .rect(cornerRadius: cornerRadius)
            )
        } else {
            content.background(
                isHighlighted ? highlightColor.opacity(0.15) : Color.clear,
                in: RoundedRectangle(cornerRadius: cornerRadius)
            )
        }
    }
}

/// Clear glass effect with rounded rect shape.
/// iOS 26+: `.glassEffect(.clear.interactive())` with custom corner radius
/// Fallback: ultraThinMaterial background
struct ClearGlassModifier: ViewModifier {
    var cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.clear.interactive(), in: .rect(cornerRadius: cornerRadius))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}
