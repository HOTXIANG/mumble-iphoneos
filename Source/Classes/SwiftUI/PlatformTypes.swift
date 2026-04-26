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
    static var systemGray2: Color { Color(nsColor: .systemGray).opacity(0.65) }
    static var systemGray3: Color { Color(nsColor: .systemGray).opacity(0.5) }
    static var systemGray4: Color { Color(nsColor: .systemGray).opacity(0.35) }
    static var systemGray5: Color { Color(nsColor: .systemGray).opacity(0.2) }
    static var secondarySystemBackground: Color { Color(nsColor: .controlBackgroundColor) }
}
#endif

#if canImport(UIKit)
// Cross-platform system colors (iOS)
extension Color {
    static var systemGray2: Color { Color(uiColor: .systemGray).opacity(0.65) }
    static var systemGray3: Color { Color(uiColor: .systemGray).opacity(0.5) }
    static var systemGray4: Color { Color(uiColor: .systemGray).opacity(0.35) }
    static var systemGray5: Color { Color(uiColor: .systemGray).opacity(0.2) }
    static var secondarySystemBackground: Color { Color(uiColor: .secondarySystemBackground) }
}
#endif

// MARK: - GlassEffect Availability Wrapper

/// ViewModifier that applies glassEffect when available (iOS 26.0+ / macOS 26.0+),
/// falls back to a simple background on older versions.
struct GlassEffectModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
                .shadow(
                    color: colorScheme == .light ? .black.opacity(0.10) : .clear,
                    radius: colorScheme == .light ? 8 : 0,
                    x: 0,
                    y: colorScheme == .light ? 3 : 0
                )
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .shadow(
                    color: colorScheme == .light ? .black.opacity(0.08) : .clear,
                    radius: colorScheme == .light ? 6 : 0,
                    x: 0,
                    y: colorScheme == .light ? 2 : 0
                )
        }
    }
}

/// Red-tinted glass capsule for cancel/destructive buttons.
/// iOS 26+/macOS 26+: `.glassEffect(.regular.tint(.red))` in Capsule
/// Fallback: solid red translucent capsule background
struct RedGlassCapsuleModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content
                .glassEffect(.regular.tint(.red.opacity(0.5)).interactive(), in: Capsule())
                .shadow(
                    color: colorScheme == .light ? .black.opacity(0.10) : .clear,
                    radius: colorScheme == .light ? 7 : 0,
                    x: 0,
                    y: colorScheme == .light ? 2 : 0
                )
        } else {
            content
                .background(.red.opacity(0.6), in: Capsule())
                .shadow(
                    color: colorScheme == .light ? .black.opacity(0.08) : .clear,
                    radius: colorScheme == .light ? 5 : 0,
                    x: 0,
                    y: colorScheme == .light ? 2 : 0
                )
        }
    }
}

/// Tinted glass row highlight for channel/user rows.
/// iOS 26+: `.glassEffect(.clear.interactive().tint(...))` rounded rect
/// Fallback: translucent background color
struct TintedGlassRowModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var isHighlighted: Bool
    var highlightColor: Color
    #if os(iOS)
    var cornerRadius: CGFloat = 13
    #else
    var cornerRadius: CGFloat = 12
    #endif

    @ViewBuilder
    func body(content: Content) -> some View {
        standardBody(content: content)
    }

    @ViewBuilder
    private func standardBody(content: Content) -> some View {
        let highlightTint: Color = colorScheme == .light
            ? highlightColor.opacity(0.28)
            : highlightColor.opacity(0.5)
        let normalTint: Color = colorScheme == .light
            ? Color.black.opacity(0.10)
            : Color.clear

        if #available(iOS 26.0, macOS 26.0, *) {
            content
                .glassEffect(
                    .clear.interactive().tint(isHighlighted ? highlightTint : normalTint),
                    in: .rect(cornerRadius: cornerRadius)
                )
                .shadow(
                    color: colorScheme == .light ? .black.opacity(isHighlighted ? 0.08 : 0.06) : .clear,
                    radius: colorScheme == .light ? 4 : 0,
                    x: 0,
                    y: colorScheme == .light ? 1 : 0
                )
        } else {
            content
                .background(
                    isHighlighted
                        ? (colorScheme == .light ? highlightColor.opacity(0.16) : highlightColor.opacity(0.15))
                        : (colorScheme == .light ? Color.black.opacity(0.05) : Color.clear),
                    in: RoundedRectangle(cornerRadius: cornerRadius)
                )
                .shadow(
                    color: colorScheme == .light ? .black.opacity(isHighlighted ? 0.07 : 0.05) : .clear,
                    radius: colorScheme == .light ? 3 : 0,
                    x: 0,
                    y: colorScheme == .light ? 1 : 0
                )
        }
    }

}

/// Clear glass effect with rounded rect shape.
/// iOS 26+: `.glassEffect(.clear.interactive())` with custom corner radius
/// Fallback: ultraThinMaterial background
struct ClearGlassModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat = 12
    var lightTintColor: Color = .black
    var lightTintOpacity: Double = 0.12
    var lightFallbackOverlayOpacity: Double = 0.05
    var lightShadowOpacity: Double = 0.10
    var lightShadowRadius: CGFloat = 7
    var lightShadowYOffset: CGFloat = 2

    func body(content: Content) -> some View {
        let subtleDimTint: Color = colorScheme == .light
            ? lightTintColor.opacity(lightTintOpacity)
            : Color.clear

        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(
                .clear.interactive().tint(subtleDimTint),
                in: .rect(cornerRadius: cornerRadius)
            )
            .shadow(
                color: colorScheme == .light ? .black.opacity(lightShadowOpacity) : .clear,
                radius: colorScheme == .light ? lightShadowRadius : 0,
                x: 0,
                y: colorScheme == .light ? lightShadowYOffset : 0
            )
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(colorScheme == .light ? Color.black.opacity(lightFallbackOverlayOpacity) : Color.clear)
                )
                .shadow(
                    color: colorScheme == .light ? .black.opacity(lightShadowOpacity * 0.8) : .clear,
                    radius: colorScheme == .light ? max(lightShadowRadius - 2, 0) : 0,
                    x: 0,
                    y: colorScheme == .light ? lightShadowYOffset : 0
                )
        }
    }
}
