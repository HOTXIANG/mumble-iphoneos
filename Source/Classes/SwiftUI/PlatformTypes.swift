//
//  PlatformTypes.swift
//  Mumble
//
//  Cross-platform type aliases for iOS/macOS multiplatform support
//

import Foundation
import SwiftUI

// Resolve this at the app root: a split-view column or sheet can report a
// compact size class even when the surrounding window uses the tablet layout.
private struct UsesTabletLayoutKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var usesTabletLayout: Bool {
        get { self[UsesTabletLayoutKey.self] }
        set { self[UsesTabletLayoutKey.self] = newValue }
    }
}

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

/// Keep the native effect, but reveal it only when content actually passes the top edge.
struct ChannelTopScrollEdgeModifier: ViewModifier {
    var alwaysTransparent = false
    var hasContent = true
    @State private var hasContentUnderTitlebar = false

    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            if alwaysTransparent {
                content.scrollEdgeEffectHidden(true, for: .top)
            } else {
                content
                    #if os(macOS)
                    // Updating the style also clears AppKit's cached hard-bar backdrop.
                    .scrollEdgeEffectStyle(hasContent && hasContentUnderTitlebar ? .hard : .soft, for: .top)
                    #else
                    .scrollEdgeEffectStyle(.hard, for: .top)
                    #endif
                    .scrollEdgeEffectHidden(!hasContent || !hasContentUnderTitlebar, for: .top)
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        geometry.contentSize.height > 0 &&
                            geometry.contentOffset.y + geometry.contentInsets.top > 0.5
                    } action: { _, overlaps in
                        hasContentUnderTitlebar = overlaps
                    }
                    .preference(key: ChannelTitlebarOverlapKey.self,
                                value: hasContent && hasContentUnderTitlebar)
            }
        } else {
            content
        }
    }
}

private struct ChannelTitlebarOverlapKey: PreferenceKey {
    static var defaultValue: Bool { false }
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

#if os(macOS)
/// Derive chrome from the rendered layout, rather than a later global state update.
struct MacWindowToolbarBackgroundModifier: ViewModifier {
    let usesPaneTitlebars: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.toolbarBackgroundVisibility(usesPaneTitlebars ? .hidden : .automatic, for: .windowToolbar)
        } else {
            content
        }
    }
}

/// Reserve the native titlebar height in each hosting controller. Only the channel
/// pane registers a scroll-edge bar; chat uses an inset that cannot create an effect.
struct MacPaneTitlebarModifier: ViewModifier {
    var alwaysTransparent: Bool
    @State private var titlebarHeight: CGFloat = 52
    @State private var hasContentUnderTitlebar = false

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            Group {
                if alwaysTransparent {
                    content
                        .safeAreaInset(edge: .top, spacing: 0) { titlebarSpace }
                        .scrollEdgeEffectHidden(true, for: .top)
                } else {
                    content
                        .safeAreaBar(edge: .top, spacing: 0) { titlebarSpace }
                        // Keep the total inset fixed while removing the native bar's
                        // effect region. The scroll view and its position stay intact.
                        .safeAreaInset(edge: .top, spacing: 0) {
                            Color.clear.frame(height: hasContentUnderTitlebar ? 0 : titlebarHeight)
                        }
                        .onPreferenceChange(ChannelTitlebarOverlapKey.self) { hasContentUnderTitlebar = $0 }
                        .scrollEdgeEffectStyle(hasContentUnderTitlebar ? .hard : .soft, for: .top)
                        .scrollEdgeEffectHidden(!hasContentUnderTitlebar, for: .top)
                }
            }
            .ignoresSafeArea(.container, edges: .top)
        } else {
            content
        }
    }

    private var titlebarSpace: some View {
        // An AppKit view keeps the native bar registered even though its content
        // is transparent. A clear SwiftUI color can be optimized into just spacing.
        MacTitlebarHeightReader { titlebarHeight = $0 }
            .frame(maxWidth: .infinity)
            .frame(height: alwaysTransparent || hasContentUnderTitlebar ? titlebarHeight : 0)
            .allowsHitTesting(false)
    }
}

/// Measure native window chrome without intercepting pointer or toolbar events.
private struct MacTitlebarHeightReader: NSViewRepresentable {
    var onHeightChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> HeightView { HeightView() }

    func updateNSView(_ view: HeightView, context: Context) {
        view.onHeightChange = onHeightChange
        view.measureHeight()
    }

    final class HeightView: NSView {
        var onHeightChange: ((CGFloat) -> Void)?
        private var measuredHeight: CGFloat = 0

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            measureHeight()
        }

        override func layout() {
            super.layout()
            measureHeight()
        }

        func measureHeight() {
            guard let window, let contentView = window.contentView else { return }
            let windowBounds = contentView.convert(contentView.bounds, to: nil)
            let chromeHeight = window.standardWindowButton(.closeButton).map {
                2 * (windowBounds.maxY - $0.convert($0.bounds, to: nil).midY)
            } ?? 0
            let height = max(windowBounds.maxY - window.contentLayoutRect.maxY, chromeHeight)
            guard height > 0, measuredHeight != height else { return }
            measuredHeight = height
            DispatchQueue.main.async { [weak self] in self?.onHeightChange?(height) }
        }
    }
}
#endif

#if os(iOS)
/// Dismiss the server column after SwiftUI has installed the connected three-column layout.
/// A visibility binding alone can be overwritten by the outgoing split's transition.
struct IPadServerSidebarDismissal: UIViewControllerRepresentable {
    var requestID: Int
    var onDismiss: () -> Void

    func makeUIViewController(context: Context) -> DismissalController { DismissalController() }

    func updateUIViewController(_ controller: DismissalController, context: Context) {
        controller.requestID = requestID
        controller.onDismiss = onDismiss
        controller.scheduleDismissal()
    }

    final class DismissalController: UIViewController {
        var requestID = 0
        var onDismiss: (() -> Void)?
        private var appliedRequestID: Int?
        private var dismissalScheduled = false
        private var hasAppeared = false

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            hasAppeared = true
            scheduleDismissal()
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            hasAppeared = false
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            scheduleDismissal()
        }

        func scheduleDismissal() {
            guard hasAppeared, appliedRequestID != requestID, !dismissalScheduled else { return }
            dismissalScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.dismissalScheduled = false
                self.dismissSidebarIfReady()
            }
        }

        private func dismissSidebarIfReady() {
            guard hasAppeared, appliedRequestID != requestID, viewIfLoaded?.window != nil,
                  let split = splitViewController, split.style == .tripleColumn,
                  !split.isCollapsed else { return }

            // Wait for the incoming hierarchy to settle before changing its actual columns.
            if let transition = split.transitionCoordinator {
                dismissalScheduled = true
                let registered = transition.animate(alongsideTransition: nil) { [weak self] _ in
                    self?.dismissalScheduled = false
                    self?.scheduleDismissal()
                }
                if registered { return }
                dismissalScheduled = false
            }

            // Apply once per entry so the user can still reopen the sidebar afterwards.
            appliedRequestID = requestID
            onDismiss?()
            UIView.performWithoutAnimation {
                split.preferredDisplayMode = .oneBesideSecondary
                split.hide(.primary)
            }
        }
    }
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
/// iOS 26/macOS 26: clear Liquid Glass.
/// Newer systems: regular Liquid Glass.
/// Earlier systems: original translucent background fallback.
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
        let normalTint: Color = Color.clear

        if #available(iOS 26.0, macOS 26.0, *) {
            if ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26 {
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
                    .glassEffect(
                        .regular.tint(isHighlighted ? highlightTint : normalTint).interactive(),
                        in: .rect(cornerRadius: cornerRadius)
                    )
                    .shadow(
                        color: colorScheme == .light ? .black.opacity(isHighlighted ? 0.08 : 0.06) : .clear,
                        radius: colorScheme == .light ? 4 : 0,
                        x: 0,
                        y: colorScheme == .light ? 1 : 0
                    )
            }
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
