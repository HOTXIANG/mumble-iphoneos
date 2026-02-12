//
//  PlatformHaptics.swift
//  Mumble
//
//  Cross-platform haptic feedback wrappers. No-ops on macOS.
//

import Foundation

#if os(iOS)
import UIKit

typealias PlatformImpactFeedback = UIImpactFeedbackGenerator
typealias PlatformNotificationFeedback = UINotificationFeedbackGenerator
typealias PlatformSelectionFeedback = UISelectionFeedbackGenerator

#else

/// No-op haptic generator for macOS
class PlatformImpactFeedback {
    enum Style { case light, medium, heavy, rigid, soft }
    init(style: Style = .medium) {}
    func impactOccurred() {}
    func prepare() {}
}

class PlatformNotificationFeedback {
    enum FeedbackType { case success, warning, error }
    init() {}
    func notificationOccurred(_ type: FeedbackType) {}
    func prepare() {}
}

class PlatformSelectionFeedback {
    init() {}
    func selectionChanged() {}
    func prepare() {}
}
#endif
