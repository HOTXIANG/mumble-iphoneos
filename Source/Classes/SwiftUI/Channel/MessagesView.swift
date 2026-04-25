// 文件: MessagesView.swift

import SwiftUI
import PhotosUI
import QuartzCore
#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif
import UniformTypeIdentifiers

// MARK: - 1. 预览状态模型
struct MessageImageTapPayload {
    let sourceID: String
    let image: PlatformImage
}

struct MessageImagePreviewItem: Identifiable {
    let id: String
    let image: PlatformImage
    let sourceFrame: CGRect?
}

private struct PendingSendImage: Identifiable {
    let id = UUID()
    let image: PlatformImage
}

private struct MessageThumbnailFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

// MARK: - 2. iOS 全屏图片预览
#if os(iOS)
private struct MessageTopAnchorFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

struct IOSMessageImageFullscreenPreview: View {
    let item: MessageImagePreviewItem
    let onEntryAnimationCompleted: () -> Void
    let onDismissWillStart: () -> Void
    let onDismiss: () -> Void
    
    @State private var backgroundFade: Double = 0.0
    @State private var transitionScale: CGFloat = 1.0
    @State private var transitionOffset: CGSize = .zero
    @State private var baseScale: CGFloat = 1.0
    @State private var gestureScale: CGFloat = 1.0
    @State private var baseOffset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero
    @State private var dismissDragY: CGFloat = 0.0
    @State private var isAnimatingDismiss = false
    @State private var isPinching = false
    @State private var pinchStartScale: CGFloat = 1.0
    @State private var pinchAnchorVector: CGVector = .zero
    @State private var pinchAnchorScreenPoint: CGPoint = .zero
    @State private var pinchSmoothedCenter: CGPoint?
    @State private var panSmoothedOffset: CGSize?
    @State private var dragUnlockAfterPinchAt: TimeInterval = 0
    @State private var lastImageTapTimestamp: TimeInterval = 0
    @State private var pendingSingleTapDismiss: DispatchWorkItem?
    @State private var didNotifyEntryAnimationCompleted = false
    
    private let doubleTapDecisionWindow: TimeInterval = 0.18
    
    private var scale: CGFloat {
        min(max(baseScale * gestureScale, 0.55), 5.0)
    }
    
    private var isZoomed: Bool {
        scale > 1.01
    }
    
    private var transitionCompositeScale: CGFloat {
        transitionScale * scale
    }
    
    private var effectiveOffset: CGSize {
        if isZoomed || isPinching || scale < 0.999 {
            return CGSize(
                width: transitionOffset.width + baseOffset.width + dragOffset.width,
                height: transitionOffset.height + baseOffset.height + dragOffset.height
            )
        }
        return CGSize(width: transitionOffset.width, height: transitionOffset.height + dismissDragY)
    }
    
    private var backgroundOpacity: Double {
        if isZoomed { return 0.96 * backgroundFade }
        let progress = min(max(dismissDragY / 260.0, 0.0), 1.0)
        return (0.96 - (progress * 0.46)) * backgroundFade
    }
    
    private var isDismissDragInProgress: Bool {
        dismissDragY > 1.0
    }
    
    var body: some View {
        GeometryReader { geo in
            let containerSize = geo.size
            let containerFrame = geo.frame(in: .global)
            let targetRect = fittedRect(in: containerSize)
            
            ZStack {
                Color.black.opacity(backgroundOpacity)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if !isZoomed {
                            dismissAnimated(targetRect: targetRect)
                        }
                    }
                
                Image(platformImage: item.image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: targetRect.width, height: targetRect.height)
                    .position(x: targetRect.midX, y: targetRect.midY)
                    .scaleEffect(transitionCompositeScale)
                    .offset(effectiveOffset)
                    .simultaneousGesture(panAndDismissGesture(targetRect: targetRect, containerSize: containerSize))
                    .highPriorityGesture(
                        SpatialTapGesture(count: 1, coordinateSpace: .global)
                            .onEnded { value in
                                let localPoint = CGPoint(
                                    x: value.location.x - containerFrame.minX,
                                    y: value.location.y - containerFrame.minY
                                )
                                handleImageTapGesture(
                                    at: localPoint,
                                    targetRect: targetRect,
                                    containerSize: containerSize
                                )
                            }
                    )
                
                IOSPinchGestureBridge(
                    onBegan: { globalCenter in
                        let localCenter = CGPoint(
                            x: globalCenter.x - containerFrame.minX,
                            y: globalCenter.y - containerFrame.minY
                        )
                        beginPinch(at: localCenter, targetRect: targetRect)
                    },
                    onChanged: { magnification, globalCenter in
                        let localCenter = CGPoint(
                            x: globalCenter.x - containerFrame.minX,
                            y: globalCenter.y - containerFrame.minY
                        )
                        updatePinch(
                            magnification: magnification,
                            center: localCenter,
                            targetRect: targetRect,
                            containerSize: containerSize
                        )
                    },
                    onEnded: {
                        endPinch(targetRect: targetRect, containerSize: containerSize)
                    }
                )
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            }
            .onAppear {
                applyEntryAnimation(targetRect: targetRect)
            }
        }
        .ignoresSafeArea()
    }
    
    private func fittedRect(in containerSize: CGSize) -> CGRect {
        let availableWidth = max(containerSize.width, 1)
        let availableHeight = max(containerSize.height, 1)
        let imageSize = item.image.size
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(
                x: 0,
                y: (containerSize.height - availableHeight) * 0.5,
                width: availableWidth,
                height: availableHeight
            )
        }
        
        let widthScale = availableWidth / imageSize.width
        let heightScale = availableHeight / imageSize.height
        let fitScale = min(widthScale, heightScale)
        let width = imageSize.width * fitScale
        let height = imageSize.height * fitScale
        let x = (containerSize.width - width) * 0.5
        let y = (containerSize.height - height) * 0.5
        return CGRect(x: x, y: y, width: width, height: height)
    }
    
    private func initialTransition(for targetRect: CGRect) -> (scale: CGFloat, offset: CGSize) {
        guard let source = item.sourceFrame, source.width > 0, source.height > 0 else {
            return (0.95, .zero)
        }
        let sourceCenter = CGPoint(x: source.midX, y: source.midY)
        let targetCenter = CGPoint(x: targetRect.midX, y: targetRect.midY)
        let offset = CGSize(width: sourceCenter.x - targetCenter.x, height: sourceCenter.y - targetCenter.y)
        let scale = min(max(source.width / targetRect.width, 0.1), 1.0)
        return (scale, offset)
    }
    
    private func applyEntryAnimation(targetRect: CGRect) {
        let initial = initialTransition(for: targetRect)
        backgroundFade = 0
        transitionScale = initial.scale
        transitionOffset = initial.offset
        dismissDragY = 0
        baseScale = 1.0
        gestureScale = 1.0
        baseOffset = .zero
        dragOffset = .zero
        isPinching = false
        pinchSmoothedCenter = nil
        panSmoothedOffset = nil
        dragUnlockAfterPinchAt = 0
        didNotifyEntryAnimationCompleted = false
        
        withAnimation(.easeInOut(duration: 0.20)) {
            backgroundFade = 1.0
        }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
            transitionScale = 1.0
            transitionOffset = .zero
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            guard !isAnimatingDismiss, !didNotifyEntryAnimationCompleted else { return }
            didNotifyEntryAnimationCompleted = true
            onEntryAnimationCompleted()
        }
    }
    
    private func handleImageTapGesture(at location: CGPoint, targetRect: CGRect, containerSize: CGSize) {
        let now = Date().timeIntervalSinceReferenceDate
        let isSecondTap = (now - lastImageTapTimestamp) <= doubleTapDecisionWindow
        
        if isSecondTap {
            pendingSingleTapDismiss?.cancel()
            pendingSingleTapDismiss = nil
            lastImageTapTimestamp = 0
            toggleZoom(at: location, targetRect: targetRect, containerSize: containerSize)
            return
        }
        
        lastImageTapTimestamp = now
        pendingSingleTapDismiss?.cancel()
        pendingSingleTapDismiss = nil
        
        guard !isZoomed else { return }
        
        let workItem = DispatchWorkItem {
            if !isZoomed {
                dismissAnimated(targetRect: targetRect)
            }
        }
        pendingSingleTapDismiss = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapDecisionWindow, execute: workItem)
    }
    
    private func clampedBaseOffset(
        _ proposed: CGSize,
        targetRect: CGRect,
        containerSize: CGSize,
        scale: CGFloat
    ) -> CGSize {
        guard scale > 1.01 else { return .zero }
        let scaledWidth = targetRect.width * transitionScale * scale
        let scaledHeight = targetRect.height * transitionScale * scale
        let maxX = max((scaledWidth - containerSize.width) * 0.5, 0)
        let maxY = max((scaledHeight - containerSize.height) * 0.5, 0)
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }
    
    private func resistedBaseOffset(
        _ proposed: CGSize,
        targetRect: CGRect,
        containerSize: CGSize,
        scale: CGFloat
    ) -> CGSize {
        let scaledWidth = targetRect.width * transitionScale * scale
        let scaledHeight = targetRect.height * transitionScale * scale
        let maxX = max((scaledWidth - containerSize.width) * 0.5, 0)
        let maxY = max((scaledHeight - containerSize.height) * 0.5, 0)
        
        func rubberBand(_ value: CGFloat, limit: CGFloat) -> CGFloat {
            let absValue = abs(value)
            let sign: CGFloat = value >= 0 ? 1 : -1
            guard absValue > limit else { return value }
            let overflow = absValue - limit
            let resistedOverflow = overflow * 0.28
            return sign * (limit + resistedOverflow)
        }
        
        return CGSize(
            width: rubberBand(proposed.width, limit: maxX),
            height: rubberBand(proposed.height, limit: maxY)
        )
    }
    
    private func resistedScaleForPinch(_ proposed: CGFloat) -> CGFloat {
        if proposed < 1.0 {
            let undershoot = 1.0 - proposed
            return max(0.55, 1.0 - undershoot * 0.42)
        }
        return min(proposed, 5.0)
    }
    
    private func estimatedReleaseVelocity(from value: DragGesture.Value) -> CGSize {
        // DragGesture does not expose direct velocity here; estimate from predicted end.
        let predictionHorizon: CGFloat = 0.12
        return CGSize(
            width: (value.predictedEndTranslation.width - value.translation.width) / predictionHorizon,
            height: (value.predictedEndTranslation.height - value.translation.height) / predictionHorizon
        )
    }
    
    private func smoothedPinchCenter(from rawCenter: CGPoint) -> CGPoint {
        guard let previous = pinchSmoothedCenter else { return rawCenter }
        let dx = rawCenter.x - previous.x
        let dy = rawCenter.y - previous.y
        let distance = hypot(dx, dy)
        // Small movements use heavier smoothing to suppress jitter.
        let alpha: CGFloat = distance < 5 ? 0.22 : 0.45
        return CGPoint(
            x: previous.x + dx * alpha,
            y: previous.y + dy * alpha
        )
    }
    
    private func smoothedPanOffset(from rawOffset: CGSize) -> CGSize {
        guard let previous = panSmoothedOffset else { return rawOffset }
        let dx = rawOffset.width - previous.width
        let dy = rawOffset.height - previous.height
        let distance = hypot(dx, dy)
        // Keep small finger jitter smooth, while large swipes remain responsive.
        let alpha: CGFloat = distance < 6 ? 0.24 : 0.48
        return CGSize(
            width: previous.width + dx * alpha,
            height: previous.height + dy * alpha
        )
    }
    
    private func restoreToDefaultPreviewState(animated: Bool) {
        let updates = {
            baseScale = 1.0
            gestureScale = 1.0
            baseOffset = .zero
            dragOffset = .zero
            dismissDragY = 0
            isPinching = false
            pinchSmoothedCenter = nil
            panSmoothedOffset = nil
            dragUnlockAfterPinchAt = 0
        }
        if animated {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) {
                updates()
            }
        } else {
            updates()
        }
    }
    
    private func beginPinch(at center: CGPoint, targetRect: CGRect) {
        if isDismissDragInProgress {
            // If a second finger appears during drag-to-dismiss, immediately snap back.
            restoreToDefaultPreviewState(animated: true)
            return
        }
        guard !isDismissDragInProgress, !isAnimatingDismiss else { return }
        if !isPinching {
            isPinching = true
            pinchStartScale = baseScale
            baseOffset.width += dragOffset.width
            baseOffset.height += dragOffset.height
            dragOffset = .zero
            panSmoothedOffset = nil
        }
        pinchSmoothedCenter = center
        let currentCenter = CGPoint(
            x: targetRect.midX + transitionOffset.width + baseOffset.width,
            y: targetRect.midY + transitionOffset.height + baseOffset.height
        )
        let currentRenderedScale = max(transitionScale * baseScale, 0.0001)
        pinchAnchorVector = CGVector(
            dx: (center.x - currentCenter.x) / currentRenderedScale,
            dy: (center.y - currentCenter.y) / currentRenderedScale
        )
        pinchAnchorScreenPoint = center
    }
    
    private func updatePinch(
        magnification: CGFloat,
        center: CGPoint,
        targetRect: CGRect,
        containerSize: CGSize
    ) {
        if isDismissDragInProgress {
            restoreToDefaultPreviewState(animated: true)
            return
        }
        guard !isDismissDragInProgress, !isAnimatingDismiss else { return }
        if !isPinching {
            beginPinch(at: center, targetRect: targetRect)
        }
        let filteredCenter = smoothedPinchCenter(from: center)
        pinchSmoothedCenter = filteredCenter
        pinchAnchorScreenPoint = filteredCenter
        
        let proposedScale = pinchStartScale * magnification
        let newScale = resistedScaleForPinch(proposedScale)
        baseScale = newScale
        
        let targetCenter = CGPoint(
            x: targetRect.midX + transitionOffset.width,
            y: targetRect.midY + transitionOffset.height
        )
        let newCenter = CGPoint(
            x: filteredCenter.x - pinchAnchorVector.dx * (transitionScale * newScale),
            y: filteredCenter.y - pinchAnchorVector.dy * (transitionScale * newScale)
        )
        let proposedOffset = CGSize(
            width: newCenter.x - targetCenter.x,
            height: newCenter.y - targetCenter.y
        )
        
        baseOffset = resistedBaseOffset(
            proposedOffset,
            targetRect: targetRect,
            containerSize: containerSize,
            scale: newScale
        )
    }
    
    private func endPinch(targetRect: CGRect, containerSize: CGSize) {
        guard isPinching else { return }
        isPinching = false
        pinchSmoothedCenter = nil
        panSmoothedOffset = nil
        dragUnlockAfterPinchAt = Date().timeIntervalSinceReferenceDate + 0.12
        gestureScale = 1.0
        if baseScale <= 1.01 {
            withAnimation(.spring(response: 0.30, dampingFraction: 0.78)) {
                baseScale = 1.0
                baseOffset = .zero
                dragOffset = .zero
            }
        } else {
            let clamped = clampedBaseOffset(
                baseOffset,
                targetRect: targetRect,
                containerSize: containerSize,
                scale: baseScale
            )
            let needsBounceBack =
                abs(clamped.width - baseOffset.width) > 0.5 ||
                abs(clamped.height - baseOffset.height) > 0.5
            if needsBounceBack {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.78)) {
                    baseOffset = clamped
                }
            } else {
                baseOffset = clamped
            }
        }
    }
    
    private func panAndDismissGesture(targetRect: CGRect, containerSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in
                let now = Date().timeIntervalSinceReferenceDate
                if now < dragUnlockAfterPinchAt {
                    dragOffset = .zero
                    panSmoothedOffset = nil
                    return
                }
                if isPinching {
                    return
                }
                if isZoomed {
                    let proposed = CGSize(
                        width: baseOffset.width + value.translation.width,
                        height: baseOffset.height + value.translation.height
                    )
                    let resisted = resistedBaseOffset(
                        proposed,
                        targetRect: targetRect,
                        containerSize: containerSize,
                        scale: baseScale
                    )
                    let smoothed = smoothedPanOffset(from: resisted)
                    panSmoothedOffset = smoothed
                    dragOffset = CGSize(
                        width: smoothed.width - baseOffset.width,
                        height: smoothed.height - baseOffset.height
                    )
                } else {
                    if isPinching {
                        isPinching = false
                        pinchSmoothedCenter = nil
                    }
                    dismissDragY = max(0, value.translation.height)
                }
            }
            .onEnded { value in
                let now = Date().timeIntervalSinceReferenceDate
                if now < dragUnlockAfterPinchAt {
                    dragOffset = .zero
                    panSmoothedOffset = nil
                    return
                }
                if isPinching {
                    return
                }
                if isZoomed {
                    let currentOffset = CGSize(
                        width: baseOffset.width + dragOffset.width,
                        height: baseOffset.height + dragOffset.height
                    )
                    baseOffset = currentOffset
                    dragOffset = .zero
                    panSmoothedOffset = nil
                    let momentumDelta = CGSize(
                        width: value.predictedEndTranslation.width - value.translation.width,
                        height: value.predictedEndTranslation.height - value.translation.height
                    )
                    let momentumMagnitude = hypot(momentumDelta.width, momentumDelta.height)
                    let inertiaScale: CGFloat = 0.9
                    let projectedOffset = CGSize(
                        width: currentOffset.width + momentumDelta.width * inertiaScale,
                        height: currentOffset.height + momentumDelta.height * inertiaScale
                    )
                    let finalOffset = clampedBaseOffset(
                        projectedOffset,
                        targetRect: targetRect,
                        containerSize: containerSize,
                        scale: baseScale
                    )
                    let hasVisibleMovement =
                        abs(finalOffset.width - currentOffset.width) > 0.5 ||
                        abs(finalOffset.height - currentOffset.height) > 0.5
                    if hasVisibleMovement {
                        let releaseVelocity = estimatedReleaseVelocity(from: value)
                        let deltaX = finalOffset.width - currentOffset.width
                        let deltaY = finalOffset.height - currentOffset.height
                        let distance = hypot(
                            finalOffset.width - currentOffset.width,
                            finalOffset.height - currentOffset.height
                        )
                        let direction = CGPoint(
                            x: distance > 0.001 ? deltaX / distance : 0,
                            y: distance > 0.001 ? deltaY / distance : 0
                        )
                        let projectedSpeed =
                            releaseVelocity.width * direction.x +
                            releaseVelocity.height * direction.y
                        let normalizedInitialVelocity = min(max(projectedSpeed / max(distance, 1), 0), 14)
                        if momentumMagnitude > 4 {
                            withAnimation(
                                .interpolatingSpring(
                                    mass: 1.0,
                                    stiffness: 170,
                                    damping: 23,
                                    initialVelocity: normalizedInitialVelocity
                                )
                            ) {
                                baseOffset = finalOffset
                            }
                        } else {
                            withAnimation(.easeOut(duration: 0.18)) {
                                baseOffset = finalOffset
                            }
                        }
                    } else {
                        baseOffset = finalOffset
                    }
                } else {
                    panSmoothedOffset = nil
                    let shouldDismiss = value.translation.height > 140 || value.predictedEndTranslation.height > 220
                    if shouldDismiss {
                        dismissAnimated(targetRect: targetRect)
                    } else {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            dismissDragY = 0
                        }
                    }
                }
            }
    }
    
    private func dismissAnimated(targetRect: CGRect) {
        guard !isAnimatingDismiss else { return }
        pendingSingleTapDismiss?.cancel()
        pendingSingleTapDismiss = nil
        lastImageTapTimestamp = 0
        isAnimatingDismiss = true
        panSmoothedOffset = nil
        onDismissWillStart()
        
        withAnimation(.easeInOut(duration: 0.14)) {
            backgroundFade = 0
        }
        
        if !isZoomed {
            let initial = initialTransition(for: targetRect)
            withAnimation(.spring(response: 0.24, dampingFraction: 0.92)) {
                transitionScale = initial.scale
                transitionOffset = initial.offset
                dismissDragY = 0
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            onDismiss()
        }
    }
    
    private func toggleZoom(at location: CGPoint, targetRect: CGRect, containerSize: CGSize) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            if isZoomed {
                baseScale = 1.0
                gestureScale = 1.0
                isPinching = false
                pinchSmoothedCenter = nil
                panSmoothedOffset = nil
                dragUnlockAfterPinchAt = 0
                baseOffset = .zero
                dragOffset = .zero
                dismissDragY = 0
            } else {
                let targetScale: CGFloat = 2.2
                let currentTotalScale = max(transitionScale * baseScale, 0.0001)
                let currentTotalOffset = CGSize(
                    width: transitionOffset.width + baseOffset.width,
                    height: transitionOffset.height + baseOffset.height
                )
                let imageCenter = CGPoint(
                    x: targetRect.midX + currentTotalOffset.width,
                    y: targetRect.midY + currentTotalOffset.height
                )
                let localVector = CGVector(
                    dx: (location.x - imageCenter.x) / currentTotalScale,
                    dy: (location.y - imageCenter.y) / currentTotalScale
                )
                let targetTotalScale = transitionScale * targetScale
                let targetCenter = CGPoint(
                    x: location.x - localVector.dx * targetTotalScale,
                    y: location.y - localVector.dy * targetTotalScale
                )
                let proposedBaseOffset = CGSize(
                    width: targetCenter.x - targetRect.midX - transitionOffset.width,
                    height: targetCenter.y - targetRect.midY - transitionOffset.height
                )
                
                baseScale = targetScale
                gestureScale = 1.0
                isPinching = false
                pinchSmoothedCenter = nil
                panSmoothedOffset = nil
                dragUnlockAfterPinchAt = 0
                baseOffset = clampedBaseOffset(
                    proposedBaseOffset,
                    targetRect: targetRect,
                    containerSize: containerSize,
                    scale: targetScale
                )
                dragOffset = .zero
                dismissDragY = 0
            }
        }
    }
}

private struct IOSPinchGestureBridge: UIViewRepresentable {
    let onBegan: (CGPoint) -> Void
    let onChanged: (CGFloat, CGPoint) -> Void
    let onEnded: () -> Void
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.attachIfNeeded(hostView: uiView)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }
    
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: IOSPinchGestureBridge
        private weak var attachedView: UIView?
        private lazy var pinchRecognizer: UIPinchGestureRecognizer = {
            let recognizer = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            return recognizer
        }()
        
        init(parent: IOSPinchGestureBridge) {
            self.parent = parent
        }
        
        func attachIfNeeded(hostView: UIView) {
            DispatchQueue.main.async { [weak self, weak hostView] in
                guard let self, let hostView, let window = hostView.window else { return }
                guard self.attachedView !== window else { return }
                self.detach()
                window.addGestureRecognizer(self.pinchRecognizer)
                self.attachedView = window
            }
        }
        
        func detach() {
            if let attachedView {
                attachedView.removeGestureRecognizer(pinchRecognizer)
            }
            attachedView = nil
        }
        
        @objc
        private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let targetView = attachedView else { return }
            switch recognizer.state {
            case .began:
                guard recognizer.numberOfTouches >= 2 else { return }
                let center = recognizer.location(in: targetView)
                parent.onBegan(center)
                parent.onChanged(recognizer.scale, center)
            case .changed:
                guard recognizer.numberOfTouches >= 2 else { return }
                let center = recognizer.location(in: targetView)
                parent.onChanged(recognizer.scale, center)
            case .ended, .cancelled, .failed:
                parent.onEnded()
            default:
                break
            }
        }
        
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

private struct IOSChromeFadeController: UIViewControllerRepresentable {
    let immersive: Bool
    
    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }
    
    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        uiViewController.setImmersive(immersive)
    }
    
    final class Controller: UIViewController {
        private var currentImmersive: Bool?
        
        override var prefersStatusBarHidden: Bool {
            currentImmersive ?? false
        }
        
        override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation {
            .fade
        }
        
        private var savedStandardAppearance: UINavigationBarAppearance?
        private var savedScrollEdgeAppearance: UINavigationBarAppearance?
        private var savedCompactAppearance: UINavigationBarAppearance?
        
        private func findNavigationController(from root: UIViewController?) -> UINavigationController? {
            guard let root else { return nil }
            if let nav = root as? UINavigationController { return nav }
            for child in root.children {
                if let nav = findNavigationController(from: child) { return nav }
            }
            if let presented = root.presentedViewController {
                if let nav = findNavigationController(from: presented) { return nav }
            }
            return nil
        }
        
        private func findTabBarController(from root: UIViewController?) -> UITabBarController? {
            guard let root else { return nil }
            if let tab = root as? UITabBarController { return tab }
            for child in root.children {
                if let tab = findTabBarController(from: child) { return tab }
            }
            if let presented = root.presentedViewController {
                if let tab = findTabBarController(from: presented) { return tab }
            }
            return nil
        }
        
        private func resolvedNavigationController() -> UINavigationController? {
            if let nav = navigationController { return nav }
            if let nav = findNavigationController(from: parent) { return nav }
            return findNavigationController(from: view.window?.rootViewController)
        }
        
        private func resolvedTabBarController() -> UITabBarController? {
            if let tab = tabBarController { return tab }
            if let tab = findTabBarController(from: parent) { return tab }
            return findTabBarController(from: view.window?.rootViewController)
        }
        
        func setImmersive(_ immersive: Bool) {
            guard currentImmersive != immersive else { return }
            currentImmersive = immersive
            applyChromeAlpha(immersive: immersive)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.setNeedsStatusBarAppearanceUpdate()
                self.navigationController?.setNeedsStatusBarAppearanceUpdate()
                self.tabBarController?.setNeedsStatusBarAppearanceUpdate()
            }
        }
        
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // Safety: never leave bars hidden/inactive when leaving this view tree.
            restoreChromeImmediately()
        }
        
        private func applyChromeAlpha(immersive: Bool) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let navBar = self.resolvedNavigationController()?.navigationBar
                let tabBar = self.resolvedTabBarController()?.tabBar
                let duration: TimeInterval = 0.20
                
                if immersive {
                    self.applyTransparentNavigationBarAppearance(navBar)
                    navBar?.isUserInteractionEnabled = false
                    tabBar?.isUserInteractionEnabled = false
                    UIView.animate(
                        withDuration: duration,
                        delay: 0,
                        options: [.beginFromCurrentState, .curveEaseInOut]
                    ) {
                        navBar?.alpha = 0
                        tabBar?.alpha = 0
                    }
                } else {
                    self.restoreNavigationBarAppearance(navBar)
                    UIView.animate(
                        withDuration: duration,
                        delay: 0,
                        options: [.beginFromCurrentState, .curveEaseInOut]
                    ) {
                        navBar?.alpha = 1
                        tabBar?.alpha = 1
                    } completion: { _ in
                        navBar?.isUserInteractionEnabled = true
                        tabBar?.isUserInteractionEnabled = true
                    }
                }
            }
        }
        
        private func restoreChromeImmediately() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let navBar = self.resolvedNavigationController()?.navigationBar
                let tabBar = self.resolvedTabBarController()?.tabBar
                navBar?.alpha = 1
                navBar?.isUserInteractionEnabled = true
                tabBar?.alpha = 1
                tabBar?.isUserInteractionEnabled = true
                self.restoreNavigationBarAppearance(navBar)
            }
        }
        
        private func applyTransparentNavigationBarAppearance(_ navBar: UINavigationBar?) {
            guard let navBar else { return }
            if savedStandardAppearance == nil {
                savedStandardAppearance = navBar.standardAppearance.copy()
                savedScrollEdgeAppearance = navBar.scrollEdgeAppearance?.copy()
                savedCompactAppearance = navBar.compactAppearance?.copy()
            }
            let transparent = UINavigationBarAppearance()
            transparent.configureWithTransparentBackground()
            transparent.backgroundColor = .clear
            transparent.shadowColor = .clear
            navBar.standardAppearance = transparent
            navBar.scrollEdgeAppearance = transparent
            navBar.compactAppearance = transparent
        }
        
        private func restoreNavigationBarAppearance(_ navBar: UINavigationBar?) {
            guard let navBar else { return }
            guard let standard = savedStandardAppearance else { return }
            navBar.standardAppearance = standard
            navBar.scrollEdgeAppearance = savedScrollEdgeAppearance ?? standard
            navBar.compactAppearance = savedCompactAppearance
            savedStandardAppearance = nil
            savedScrollEdgeAppearance = nil
            savedCompactAppearance = nil
        }
    }
}
#endif

// MARK: - 3. 主容器 (Stable Container)
struct MessagesView: View {
    let serverManager: ServerModelManager
    let isSplitLayout: Bool
    @ObservedObject private var appState = AppState.shared
    @Environment(\.colorScheme) private var colorScheme
    
    // 状态管理中心
    @State private var isLayoutLockActive = false
    @State private var lockedTopAnchorMinY: CGFloat?
    @State private var latestTopAnchorMinY: CGFloat = 0
    @State private var topLayoutCompensationY: CGFloat = 01
    @State private var messagesLayoutCompensationY: CGFloat = 0
    @State private var selectedImageForSend: PendingSendImage?
    @State private var messageImageFrames: [String: CGRect] = [:]
    
    private var hiddenPreviewSourceID: String? {
        #if os(iOS)
        return appState.hiddenPreviewSourceID
        #else
        return appState.hiddenMacPreviewSourceID
        #endif
    }
    
    var body: some View {
        ZStack {
            // 1. 动态内容层
            MessagesList(
                serverManager: serverManager,
                isSplitLayout: isSplitLayout,
                layoutCompensationY: messagesLayoutCompensationY,
                hiddenPreviewSourceID: hiddenPreviewSourceID,
                onPreviewRequest: { payload in handleImageTap(payload: payload) },
                onThumbnailFramesChanged: { frames in messageImageFrames = frames },
                onTopAnchorFrameChanged: { frame in
                    handleTopAnchorFrameChange(frame)
                },
                onImageSelected: { image in selectedImageForSend = PendingSendImage(image: image) }
            )
            
            // 2. 静态锚点层 (发送确认框挂在这里)
            Color.clear
                .allowsHitTesting(false)
                // 挂载发送确认框 (Sheet)
                .sheet(item: $selectedImageForSend) { item in
                    ImageConfirmationView(
                        image: item.image,
                        onCancel: {
                            InteractionFeedback.cancel()
                            selectedImageForSend = nil
                        },
                        onSend: { imageToSend in
                            await serverManager.sendImageMessage(image: imageToSend)
                            selectedImageForSend = nil
                        }
                    )
                    .presentationDetents([.medium , .large])
                }
            
        }
        #if os(iOS)
        .onChange(of: appState.activeImagePreview?.id) { _, value in
            let isPreviewActive = (value != nil)
            if !isPreviewActive {
                isLayoutLockActive = false
                lockedTopAnchorMinY = nil
                topLayoutCompensationY = 0
                messagesLayoutCompensationY = 0
                appState.hiddenPreviewSourceID = nil
            }
        }
        .onDisappear {
            appState.isImmersiveStatusBarHidden = false
        }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .muAutomationDismissUI)) { notification in
            let target = notification.userInfo?["target"] as? String
            if target == nil || target == "imageSendConfirm" {
                selectedImageForSend = nil
            }
        }
        .onChange(of: selectedImageForSend?.id) { _, value in
            if value != nil {
                AppState.shared.setAutomationPresentedSheet("imageSendConfirm")
            } else {
                AppState.shared.clearAutomationPresentedSheet(ifMatches: "imageSendConfirm")
            }
        }
    }
    
    private func handleImageTap(payload: MessageImageTapPayload) {
        #if os(macOS)
        // 防止快速连续点击导致预览状态错乱
        guard appState.activeMacImagePreview == nil else { return }
        appState.hiddenMacPreviewSourceID = nil
        let preview = MessageImagePreviewItem(
            id: payload.sourceID,
            image: payload.image,
            sourceFrame: messageImageFrames[payload.sourceID]
        )
        appState.activeMacImagePreview = preview
        // Fallback: ensure source thumbnail gets hidden after entry animation window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
            if appState.activeMacImagePreview?.id == preview.id,
               appState.hiddenMacPreviewSourceID == nil {
                appState.hiddenMacPreviewSourceID = preview.id
            }
        }
        #else
        isLayoutLockActive = true
        if latestTopAnchorMinY > 0 {
            lockedTopAnchorMinY = latestTopAnchorMinY
        }
        appState.isImmersiveStatusBarHidden = true
        // Keep source visible during entry animation; hide it after animation completes.
        appState.hiddenPreviewSourceID = nil
        appState.activeImagePreview = MessageImagePreviewItem(
            id: payload.sourceID,
            image: payload.image,
            sourceFrame: messageImageFrames[payload.sourceID]
        )
        #endif
    }
    
    private func handleTopAnchorFrameChange(_ frame: CGRect) {
        guard frame.minY > 0 else { return }
        latestTopAnchorMinY = frame.minY
        
        if isLayoutLockActive, let lockedTop = lockedTopAnchorMinY {
            // Freeze top occupied height during immersive preview.
            topLayoutCompensationY = max(0, lockedTop - frame.minY)
        } else {
            topLayoutCompensationY = 0
        }
        recomputeLayoutCompensation()
    }
    
    private func recomputeLayoutCompensation() {
        messagesLayoutCompensationY = topLayoutCompensationY
    }
}

#if os(macOS)
/// macOS 图片预览 overlay：全窗口覆盖，支持触控板/鼠标缩放，双击还原，Esc 关闭
struct MacImagePreviewOverlay: View {
    let item: MessageImagePreviewItem
    let onEntryAnimationCompleted: () -> Void
    let onDismissWillStart: () -> Void
    let onDismiss: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    
    @State private var backgroundFade: Double = 0.0
    @State private var transitionScale: CGFloat = 1.0
    @State private var transitionOffset: CGSize = .zero
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var dragBaseOffset: CGSize = .zero
    @State private var isAnimatingDismiss = false
    @State private var didNotifyEntryAnimationCompleted = false
    
    private var isZoomed: Bool {
        scale > 1.01
    }
    
    private var transitionCompositeScale: CGFloat {
        transitionScale * scale
    }
    
    private var effectiveOffset: CGSize {
        CGSize(
            width: transitionOffset.width + offset.width,
            height: transitionOffset.height + offset.height
        )
    }
    
    @ViewBuilder
    private var closeButtonLabel: some View {
        let iconTint = colorScheme == .light ? Color.white.opacity(0.86) : Color.white.opacity(0.92)
        let glassTint = colorScheme == .light ? Color.black.opacity(0.10) : Color.white.opacity(0.08)
        
        Image(systemName: "xmark")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(iconTint)
            .frame(width: 38, height: 38)
            .contentShape(Circle())
            .modifier(MacPreviewCloseButtonGlassModifier(glassTint: glassTint))
    }
    
    private func resetToDefault(animated: Bool) {
        let updates = {
            scale = 1.0
            offset = .zero
            dragBaseOffset = .zero
        }
        if animated {
            withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
                updates()
            }
        } else {
            updates()
        }
    }
    
    private func clampedBaseOffset(
        _ proposed: CGSize,
        targetRect: CGRect,
        containerSize: CGSize,
        scale: CGFloat
    ) -> CGSize {
        guard scale > 1.01 else { return .zero }
        let scaledWidth = targetRect.width * transitionScale * scale
        let scaledHeight = targetRect.height * transitionScale * scale
        let maxX = max((scaledWidth - containerSize.width) * 0.5, 0)
        let maxY = max((scaledHeight - containerSize.height) * 0.5, 0)
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }
    
    private func resistedBaseOffset(
        _ proposed: CGSize,
        targetRect: CGRect,
        containerSize: CGSize,
        scale: CGFloat
    ) -> CGSize {
        let scaledWidth = targetRect.width * transitionScale * scale
        let scaledHeight = targetRect.height * transitionScale * scale
        let maxX = max((scaledWidth - containerSize.width) * 0.5, 0)
        let maxY = max((scaledHeight - containerSize.height) * 0.5, 0)
        
        func rubberBand(_ value: CGFloat, limit: CGFloat) -> CGFloat {
            let absValue = abs(value)
            let sign: CGFloat = value >= 0 ? 1 : -1
            guard absValue > limit else { return value }
            let overflow = absValue - limit
            let resistedOverflow = overflow * 0.30
            return sign * (limit + resistedOverflow)
        }
        
        guard scale > 1.01 else { return .zero }
        return CGSize(
            width: rubberBand(proposed.width, limit: maxX),
            height: rubberBand(proposed.height, limit: maxY)
        )
    }
    
    private func zoomOffsetKeepingAnchor(
        anchor: CGPoint,
        imageCenter: CGPoint,
        currentOffset: CGSize,
        oldScale: CGFloat,
        newScale: CGFloat
    ) -> CGSize {
        guard oldScale > 0.0001 else { return currentOffset }
        let currentCenter = CGPoint(
            x: imageCenter.x + currentOffset.width,
            y: imageCenter.y + currentOffset.height
        )
        let vector = CGPoint(
            x: anchor.x - currentCenter.x,
            y: anchor.y - currentCenter.y
        )
        let ratio = newScale / oldScale
        return CGSize(
            width: currentOffset.width - vector.x * (ratio - 1.0),
            height: currentOffset.height - vector.y * (ratio - 1.0)
        )
    }
    
    private func toggleZoom(at location: CGPoint, targetRect: CGRect, containerSize: CGSize) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            if isZoomed {
                resetToDefault(animated: false)
            } else {
                let newScale: CGFloat = 2.5
                let imageCenter = CGPoint(x: targetRect.midX, y: targetRect.midY)
                let proposed = zoomOffsetKeepingAnchor(
                    anchor: location,
                    imageCenter: imageCenter,
                    currentOffset: offset,
                    oldScale: scale,
                    newScale: newScale
                )
                let bounded = clampedBaseOffset(
                    proposed,
                    targetRect: targetRect,
                    containerSize: containerSize,
                    scale: newScale
                )
                scale = newScale
                offset = bounded
                dragBaseOffset = bounded
            }
        }
    }
    
    private func fittedRect(in containerSize: CGSize) -> CGRect {
        let availableWidth = max(containerSize.width * 0.92, 1)
        let availableHeight = max(containerSize.height * 0.92, 1)
        let imageSize = item.image.size
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(
                x: (containerSize.width - availableWidth) * 0.5,
                y: (containerSize.height - availableHeight) * 0.5,
                width: availableWidth,
                height: availableHeight
            )
        }
        
        let widthScale = availableWidth / imageSize.width
        let heightScale = availableHeight / imageSize.height
        let fitScale = min(widthScale, heightScale)
        let width = imageSize.width * fitScale
        let height = imageSize.height * fitScale
        let x = (containerSize.width - width) * 0.5
        let y = (containerSize.height - height) * 0.5
        return CGRect(x: x, y: y, width: width, height: height)
    }
    
    private func initialTransition(for targetRect: CGRect, in containerFrame: CGRect) -> (scale: CGFloat, offset: CGSize) {
        guard let source = item.sourceFrame, source.width > 0, source.height > 0 else {
            return (0.95, .zero)
        }
        let sourceCenterGlobal = CGPoint(x: source.midX, y: source.midY)
        let sourceCenter = CGPoint(
            x: sourceCenterGlobal.x - containerFrame.minX,
            y: sourceCenterGlobal.y - containerFrame.minY
        )
        let targetCenter = CGPoint(x: targetRect.midX, y: targetRect.midY)
        let offset = CGSize(width: sourceCenter.x - targetCenter.x, height: sourceCenter.y - targetCenter.y)
        let scale = min(max(source.width / targetRect.width, 0.1), 1.0)
        return (scale, offset)
    }
    
    private func applyEntryAnimation(targetRect: CGRect, containerFrame: CGRect) {
        let initial = initialTransition(for: targetRect, in: containerFrame)
        backgroundFade = 0
        transitionScale = initial.scale
        transitionOffset = initial.offset
        resetToDefault(animated: false)
        didNotifyEntryAnimationCompleted = false
        
        withAnimation(.easeInOut(duration: 0.20)) {
            backgroundFade = 1.0
        }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
            transitionScale = 1.0
            transitionOffset = .zero
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            guard !isAnimatingDismiss, !didNotifyEntryAnimationCompleted else { return }
            didNotifyEntryAnimationCompleted = true
            onEntryAnimationCompleted()
        }
    }
    
    private func dismissAnimated(targetRect: CGRect, containerFrame: CGRect) {
        guard !isAnimatingDismiss else { return }
        isAnimatingDismiss = true
        onDismissWillStart()
        
        withAnimation(.easeInOut(duration: 0.20)) {
            backgroundFade = 0
        }
        
        if !isZoomed {
            let initial = initialTransition(for: targetRect, in: containerFrame)
            withAnimation(.spring(response: 0.30, dampingFraction: 0.90)) {
                transitionScale = initial.scale
                transitionOffset = initial.offset
                resetToDefault(animated: false)
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            onDismiss()
        }
    }
    
    var body: some View {
        GeometryReader { geo in
            let containerFrame = geo.frame(in: .global)
            let targetRect = fittedRect(in: geo.size)
            let containerSize = geo.size
            
            ZStack {
                // 半透明背景，点击空白区域关闭
                Color.black.opacity(0.88 * backgroundFade)
                    .ignoresSafeArea()
                    .onTapGesture { dismissAnimated(targetRect: targetRect, containerFrame: containerFrame) }
                
                // 可缩放、可拖拽的图片
                Image(platformImage: item.image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: targetRect.width, height: targetRect.height)
                    .position(x: targetRect.midX, y: targetRect.midY)
                    .scaleEffect(transitionCompositeScale)
                    .offset(effectiveOffset)
                    // 鼠标按住拖拽平移（放大后移动图片）
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                guard isZoomed else { return }
                                let proposed = CGSize(
                                    width: dragBaseOffset.width + value.translation.width,
                                    height: dragBaseOffset.height + value.translation.height
                                )
                                offset = resistedBaseOffset(
                                    proposed,
                                    targetRect: targetRect,
                                    containerSize: containerSize,
                                    scale: scale
                                )
                            }
                            .onEnded { _ in
                                let bounded = clampedBaseOffset(
                                    offset,
                                    targetRect: targetRect,
                                    containerSize: containerSize,
                                    scale: scale
                                )
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                    offset = bounded
                                }
                                dragBaseOffset = bounded
                            }
                    )
                    // 双击：放大 2.5x ↔ 还原 1x（鼠标/触控板轻点）
                    .highPriorityGesture(
                        SpatialTapGesture(count: 2, coordinateSpace: .local)
                            .onEnded { value in
                                toggleZoom(at: value.location, targetRect: targetRect, containerSize: containerSize)
                            }
                    )
                    .background(
                        MacTrackpadGestureBridge(
                            onMagnifyDelta: { delta, location in
                                // NSMagnificationGestureRecognizer provides incremental delta.
                                let imageCenter = CGPoint(x: targetRect.midX, y: targetRect.midY)
                                let factor = max(0.2, 1.0 + delta)
                                let proposedScale = min(max(scale * factor, 0.5), 5.0)
                                let proposedOffset = zoomOffsetKeepingAnchor(
                                    anchor: location,
                                    imageCenter: imageCenter,
                                    currentOffset: offset,
                                    oldScale: scale,
                                    newScale: proposedScale
                                )
                                let bounded = resistedBaseOffset(
                                    proposedOffset,
                                    targetRect: targetRect,
                                    containerSize: containerSize,
                                    scale: proposedScale
                                )
                                scale = proposedScale
                                offset = bounded
                                dragBaseOffset = bounded
                            },
                            onMagnifyEnded: {
                                if scale < 1.0 {
                                    resetToDefault(animated: true)
                                } else {
                                    let bounded = clampedBaseOffset(
                                        offset,
                                        targetRect: targetRect,
                                        containerSize: containerSize,
                                        scale: scale
                                    )
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                        offset = bounded
                                    }
                                    dragBaseOffset = bounded
                                }
                            },
                            onPanDelta: { delta in
                                guard isZoomed else { return }
                                let proposed = CGSize(
                                    width: offset.width + delta.width,
                                    height: offset.height + delta.height
                                )
                                let bounded = resistedBaseOffset(
                                    proposed,
                                    targetRect: targetRect,
                                    containerSize: containerSize,
                                    scale: scale
                                )
                                offset = bounded
                                dragBaseOffset = bounded
                            }
                        )
                        .frame(width: 0, height: 0)
                    )
                
                // 右上角关闭按钮
                VStack {
                    HStack {
                        Spacer()
                        Button(action: { dismissAnimated(targetRect: targetRect, containerFrame: containerFrame) }) {
                            closeButtonLabel
                        }
                        .buttonStyle(.plain)
                        .padding(16)
                    }
                    Spacer()
                }
            }
            .onAppear {
                applyEntryAnimation(targetRect: targetRect, containerFrame: containerFrame)
            }
            .onExitCommand { dismissAnimated(targetRect: targetRect, containerFrame: containerFrame) } // Esc 键关闭
        }
    }
}

private struct MacPreviewCloseButtonGlassModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let glassTint: Color
    
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content
                .background(Circle().fill(colorScheme == .dark ? Color.black.opacity(0.15) : Color.white.opacity(0.15)))
                .glassEffect(.clear.interactive().tint(glassTint), in: .circle)
                .shadow(
                    color: colorScheme == .light ? .black.opacity(0.10) : .black.opacity(0.18),
                    radius: colorScheme == .light ? 8 : 6,
                    x: 0,
                    y: 2
                )
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .overlay(
                    Circle()
                        .fill(colorScheme == .light ? Color.black.opacity(0.05) : Color.white.opacity(0.05))
                )
                .shadow(
                    color: colorScheme == .light ? .black.opacity(0.08) : .black.opacity(0.16),
                    radius: colorScheme == .light ? 6 : 5,
                    x: 0,
                    y: 2
                )
        }
    }
}

private struct MacTrackpadGestureBridge: NSViewRepresentable {
    let onMagnifyDelta: (CGFloat, CGPoint) -> Void
    let onMagnifyEnded: () -> Void
    let onPanDelta: (CGSize) -> Void
    
    @MainActor
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = false
        return view
    }
    
    @MainActor
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.attachIfNeeded(hostView: nsView)
    }
    
    @MainActor
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }
    
    @MainActor
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    @MainActor
    final class Coordinator: NSObject {
        var parent: MacTrackpadGestureBridge
        private weak var attachedContentView: NSView?
        private var scrollMonitor: Any?
        private var magnifyRecognizer: NSMagnificationGestureRecognizer?
        
        init(parent: MacTrackpadGestureBridge) {
            self.parent = parent
        }
        
        func attachIfNeeded(hostView: NSView) {
            guard let window = hostView.window, let contentView = window.contentView else { return }
            guard attachedContentView !== contentView else { return }
            detach()
            let recognizer = NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnify(_:)))
            recognizer.delaysPrimaryMouseButtonEvents = false
            contentView.addGestureRecognizer(recognizer)
            magnifyRecognizer = recognizer
            attachedContentView = contentView
            installScrollMonitor()
        }
        
        func detach() {
            if let attachedContentView, let recognizer = magnifyRecognizer {
                attachedContentView.removeGestureRecognizer(recognizer)
            }
            attachedContentView = nil
            magnifyRecognizer = nil
            if let monitor = scrollMonitor {
                NSEvent.removeMonitor(monitor)
            }
            scrollMonitor = nil
        }
        
        private func installScrollMonitor() {
            guard scrollMonitor == nil else { return }
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                guard self.attachedContentView?.window?.isKeyWindow == true else { return event }
                guard event.hasPreciseScrollingDeltas else { return event }
                let dx = event.scrollingDeltaX
                let dy = event.scrollingDeltaY
                guard abs(dx) > 0.01 || abs(dy) > 0.01 else { return event }
                self.parent.onPanDelta(CGSize(width: dx, height: dy))
                return nil
            }
        }
        
        @objc
        private func handleMagnify(_ recognizer: NSMagnificationGestureRecognizer) {
            let delta = recognizer.magnification
            if abs(delta) > 0.0001 {
                let contentView = attachedContentView ?? recognizer.view
                let rawLocation = recognizer.location(in: contentView)
                parent.onMagnifyDelta(delta, rawLocation)
                recognizer.magnification = 0
            }
            switch recognizer.state {
            case .ended, .cancelled, .failed:
                parent.onMagnifyEnded()
            default:
                break
            }
        }
    }
}
#endif

// MARK: - 4. 消息列表 (Dynamic Content)
// 这个视图负责监听数据变化和 UI 刷新
struct MessagesList: View {
    @ObservedObject var serverManager: ServerModelManager
    let isSplitLayout: Bool
    let layoutCompensationY: CGFloat
    let hiddenPreviewSourceID: String?
    @Environment(\.colorScheme) private var colorScheme
    
    // 回调函数
    let onPreviewRequest: (MessageImageTapPayload) -> Void
    let onThumbnailFramesChanged: ([String: CGRect]) -> Void
    let onTopAnchorFrameChanged: (CGRect) -> Void
    let onImageSelected: (PlatformImage) -> Void
    
    @State private var newMessage = ""
    @FocusState private var isTextFieldFocused: Bool
    @State private var isDragTargeted = false
    @State private var cachedRenderBlocks: [RenderBlock] = []
    @State private var pendingAutoScrollWorkItem: DispatchWorkItem?
    @State private var autoScrollGeneration = 0
    
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
        let avatar: PlatformImage?
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
        ZStack(alignment: .bottom) {
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
                        ForEach(cachedRenderBlocks) { block in
                            switch block.kind {
                            case .notification(let message):
                                NotificationMessageView(message: message)
                            case .senderRun(let run):
                                Section {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ForEach(run.messages.indices, id: \.self) { index in
                                            let message = run.messages[index]
                                            switch run.type {
                                            case .userMessage:
                                                MessageBubbleView(
                                                    message: message,
                                                    onImageTap: onPreviewRequest,
                                                    hiddenPreviewSourceID: hiddenPreviewSourceID,
                                                    showSenderName: false,
                                                    showTimestamp: shouldShowTimestamp(in: run.messages, index: index)
                                                )
                                            case .privateMessage:
                                                PrivateMessageBubbleView(
                                                    message: message,
                                                    onImageTap: onPreviewRequest,
                                                    hiddenPreviewSourceID: hiddenPreviewSourceID,
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
                                        isSentBySelf: run.isSentBySelf,
                                        avatar: run.avatar
                                    )
                                }
                            }
                        }
                        Color.clear
                            .frame(height: 1)
                            .padding(.bottom, 4)
                            .id(bottomID)
                    }
                    .padding(.top, 16)
                    .padding(.leading, isSplitLayout ? 4 : 16)
                    .padding(.trailing, 16)
                    .offset(y: layoutCompensationY)
                }
                .scrollClipDisabled(true)
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
                .onChange(of: serverManager.messages) { _, _ in
                    rebuildRenderBlocks(reason: "messages_changed")
                    scheduleAutoScrollToBottom(proxy: proxy)
                }
                .onChange(of: isTextFieldFocused) { _, focused in
                    if focused {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                            scrollToBottom(proxy: proxy)
                        }
                    }
                }
                .onAppear {
                    rebuildRenderBlocks(reason: "list_appear")
                    scrollToBottom(proxy: proxy, animated: false)
                }
                .onDisappear {
                    pendingAutoScrollWorkItem?.cancel()
                    pendingAutoScrollWorkItem = nil
                }
                #if os(iOS)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    scheduleAutoScrollToBottom(proxy: proxy)
                }
                #else
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    scheduleAutoScrollToBottom(proxy: proxy)
                }
                #endif
            }
        }
        #if os(iOS)
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: MessageTopAnchorFramePreferenceKey.self,
                    value: geo.frame(in: .global)
                )
            }
        )
        #endif
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isTextFieldFocused)
        
        // 拖拽逻辑
        .onDrop(of: [.image], isTargeted: $isDragTargeted) { providers in
            handleDrop(providers: providers)
        }
        .onPreferenceChange(MessageThumbnailFramePreferenceKey.self) { frames in
            onThumbnailFramesChanged(frames)
        }
        #if os(iOS)
        .onPreferenceChange(MessageTopAnchorFramePreferenceKey.self) { frame in
            onTopAnchorFrameChanged(frame)
        }
        #endif
    }
    
    // MARK: - Logic Helpers
    private func buildRenderBlocks(from messages: [ChatMessage]) -> [RenderBlock] {
        var blocks: [RenderBlock] = []
        var pendingRunMessages: [ChatMessage] = []
        var pendingRunType: ChatMessageType = .userMessage
        var pendingRunIdentity: SenderIdentity?
        var pendingRunIsSentBySelf = false

        func flushPendingRun() {
            guard let identity = pendingRunIdentity, !pendingRunMessages.isEmpty else { return }
            let runID = "run-\(pendingRunMessages[0].id.uuidString)"
            let senderSession = pendingRunMessages.first?.senderSession
            let run = SenderMessageRun(
                id: runID,
                type: pendingRunType,
                displayName: identity.displayName,
                isSentBySelf: pendingRunIsSentBySelf,
                avatar: serverManager.avatarImage(for: senderSession),
                messages: pendingRunMessages
            )
            blocks.append(RenderBlock(id: runID, kind: .senderRun(run)))
            pendingRunMessages.removeAll(keepingCapacity: true)
            pendingRunIdentity = nil
        }

        for message in messages {
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

    private func rebuildRenderBlocks(reason: String) {
        let start = CACurrentMediaTime()
        let blocks = buildRenderBlocks(from: serverManager.messages)
        cachedRenderBlocks = blocks

        let elapsedMs = (CACurrentMediaTime() - start) * 1000.0
        if elapsedMs >= 1.0 || serverManager.messages.count >= 80 {
            MumbleLogger.ui.debug(
                "PERF message_render_blocks reason=\(reason) messages=\(serverManager.messages.count) blocks=\(blocks.count) elapsed_ms=\(String(format: "%.2f", elapsedMs))"
            )
        }
    }

    private func scheduleAutoScrollToBottom(proxy: ScrollViewProxy) {
        pendingAutoScrollWorkItem?.cancel()
        autoScrollGeneration += 1
        let generation = autoScrollGeneration

        let work = DispatchWorkItem {
            scrollToBottom(proxy: proxy)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                guard autoScrollGeneration == generation else { return }
                scrollToBottom(proxy: proxy, animated: false)
            }
        }

        pendingAutoScrollWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func senderIdentity(for message: ChatMessage) -> SenderIdentity {
        switch message.type {
        case .userMessage:
            let displayName = message.senderName
            let senderIdentityKey = message.senderSession.map { "session-\($0)" } ?? "name-\(displayName)"
            return SenderIdentity(
                key: "user|\(message.isSentBySelf)|\(senderIdentityKey)",
                displayName: displayName
            )
        case .privateMessage:
            let peerName = message.privatePeerName ?? message.senderName
            let displayName = message.isSentBySelf
                ? String(format: NSLocalizedString("PM to %@", comment: ""), peerName)
                : String(format: NSLocalizedString("PM from %@", comment: ""), peerName)
            let senderIdentityKey = message.senderSession.map { "session-\($0)" } ?? "name-\(peerName)"
            return SenderIdentity(
                key: "private|\(message.isSentBySelf)|\(senderIdentityKey)",
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

#if os(macOS)
private typealias MessagePlatformColor = NSColor
private typealias MessagePlatformFont = NSFont
#else
private typealias MessagePlatformColor = UIColor
private typealias MessagePlatformFont = UIFont
#endif

private let messageLinkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

private func makeMessageBodyAttributedString(
    text: String,
    baseColor: MessagePlatformColor,
    linkColor: MessagePlatformColor,
    font: MessagePlatformFont
) -> NSAttributedString {
    let mutable = NSMutableAttributedString(string: text)
    let fullRange = NSRange(location: 0, length: mutable.length)
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineBreakMode = .byCharWrapping
    
    mutable.addAttributes(
        [
            .font: font,
            .foregroundColor: baseColor,
            .paragraphStyle: paragraphStyle
        ],
        range: fullRange
    )
    
    if let detector = messageLinkDetector {
        detector.enumerateMatches(in: text, options: [], range: fullRange) { result, _, _ in
            guard let result, let url = result.url else { return }
            mutable.addAttributes(
                [
                    .link: url,
                    .foregroundColor: linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ],
                range: result.range
            )
        }
    }
    
    return mutable
}

private struct MessageBodyTextView: View {
    let text: String
    let isSentBySelf: Bool
    
    #if os(macOS)
    @Environment(\.colorScheme) private var colorScheme
    #endif
    
    private var attributedText: NSAttributedString {
        #if os(macOS)
        let baseColor = isSentBySelf ? NSColor.white : NSColor.labelColor
        let linkColor = NSColor.systemPink
        let font = NSFont.systemFont(ofSize: 13)
        #else
        let baseColor = isSentBySelf ? UIColor.white : UIColor.label
        let linkColor = UIColor.systemPink
        let font = UIFont.systemFont(ofSize: 17)
        #endif
        
        return makeMessageBodyAttributedString(
            text: text,
            baseColor: baseColor,
            linkColor: linkColor,
            font: font
        )
    }
    
    var body: some View {
        Text(text)
            #if os(macOS)
            .font(.system(size: 13))
            #else
            .font(.system(size: 17))
            #endif
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .overlay(alignment: .topLeading) {
                PlatformMessageTextView(attributedText: attributedText)
            }
    }
}

#if os(iOS)
private struct PlatformMessageTextView: UIViewRepresentable {
    let attributedText: NSAttributedString
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView(frame: .zero)
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.delegate = context.coordinator
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.lineBreakMode = .byCharWrapping
        textView.adjustsFontForContentSizeCategory = true
        textView.linkTextAttributes = [
            .foregroundColor: UIColor.systemPink,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        return textView
    }
    
    func updateUIView(_ uiView: UITextView, context: Context) {
        if !uiView.attributedText.isEqual(to: attributedText) {
            uiView.attributedText = attributedText
        }
    }
    
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 0
        guard width > 0 else { return nil }
        let target = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        let size = uiView.sizeThatFits(target)
        return CGSize(width: width, height: ceil(size.height))
    }
    
    final class Coordinator: NSObject, UITextViewDelegate {
        func textView(
            _ textView: UITextView,
            primaryActionFor textItem: UITextItem,
            defaultAction: UIAction
        ) -> UIAction? {
            if case .link(let url) = textItem.content {
                return UIAction { _ in UIApplication.shared.open(url) }
            }
            return defaultAction
        }
    }
}
#else
private struct PlatformMessageTextView: NSViewRepresentable {
    let attributedText: NSAttributedString
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView(frame: .zero)
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.delegate = context.coordinator
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byCharWrapping
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.systemPink,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]
        return textView
    }
    
    func updateNSView(_ nsView: NSTextView, context: Context) {
        if !nsView.attributedString().isEqual(to: attributedText) {
            nsView.textStorage?.setAttributedString(attributedText)
        }
    }
    
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 0
        guard width > 0, let textContainer = nsView.textContainer, let layoutManager = nsView.layoutManager else {
            return nil
        }
        textContainer.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        return CGSize(width: width, height: ceil(usedRect.height))
    }
    
    final class Coordinator: NSObject, NSTextViewDelegate {
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL else { return false }
            NSWorkspace.shared.open(url)
            return true
        }
    }
}
#endif

private struct SenderStickyHeaderView: View {
    let title: String
    let isSentBySelf: Bool
    let avatar: PlatformImage?
    @Environment(\.colorScheme) private var colorScheme
    #if os(macOS)
    private let avatarSize: CGFloat = 20
    private let headerHorizontalPadding: CGFloat = 6
    private let headerVerticalPadding: CGFloat = 6
    private let titleFontSize: CGFloat = 12
    #else
    private let avatarSize: CGFloat = 24
    private let headerHorizontalPadding: CGFloat = 8
    private let headerVerticalPadding: CGFloat = 8
    private let titleFontSize: CGFloat = 13
    #endif

    var body: some View {
        HStack {
            if isSentBySelf {
                Spacer(minLength: 0)
            }

            if #available(iOS 26.0, macOS 26.0, *) {
                headerContent
                    .padding(.horizontal, headerHorizontalPadding)
                    .padding(.vertical, headerVerticalPadding)
                    .fixedSize(horizontal: true, vertical: false)
                    .background(
                        Capsule()
                            .fill(colorScheme == .dark ? Color.clear : Color.white.opacity(0.15))
                    )
                    .glassEffect(
                        .regular,
                        in: .capsule
                    )
                    .shadow(
                        color: colorScheme == .light ? .black.opacity(0.10) : .black.opacity(0.08),
                        radius: colorScheme == .light ? 6 : 3,
                        x: 0, y: 1
                    )
            } else {
                headerContent
                    .padding(.horizontal, headerHorizontalPadding)
                    .padding(.vertical, headerVerticalPadding)
                    .fixedSize(horizontal: true, vertical: false)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .fill(colorScheme == .dark ? Color.black.opacity(0.65) : Color.white.opacity(0.65))
                    )
                    .shadow(
                        color: colorScheme == .light ? .black.opacity(0.08) : .black.opacity(0.06),
                        radius: colorScheme == .light ? 5 : 2,
                        x: 0, y: 1
                    )
            }

            if !isSentBySelf {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
    }

    private var headerContent: some View {
        HStack(spacing: 2) {
            if !isSentBySelf {
                avatarView
            }
            Text(title)
                .font(.system(size: titleFontSize, weight: .semibold))
                .fontWeight(.semibold)
                .modifier(StickyHeaderAdaptiveTextModifier())
                .lineLimit(1)
                .padding(.horizontal, 3)
            if isSentBySelf {
                avatarView
            }
        }
    }

    private var avatarView: some View {
        Group {
            if let avatar {
                Image(platformImage: avatar)
                    .resizable()
                    .scaledToFill()
                    .frame(width: avatarSize, height: avatarSize)
                    .clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: avatarSize))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct MessageBubbleView: View {
    let message: ChatMessage
    let onImageTap: (MessageImageTapPayload) -> Void
    let hiddenPreviewSourceID: String?
    let showSenderName: Bool
    let showTimestamp: Bool
    
    #if os(macOS)
    private let selfMinGap: CGFloat = 60
    private let otherMinGap: CGFloat = 80
    #else
    private let selfMinGap: CGFloat = 32
    private let otherMinGap: CGFloat = 40
    #endif
    
    var body: some View {
        HStack {
            if message.isSentBySelf { Spacer(minLength: selfMinGap) }
            VStack(alignment: message.isSentBySelf ? .trailing : .leading, spacing: 4) {
            if showSenderName && !message.isSentBySelf {
                Text(message.senderName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 6) {
                if !message.plainTextMessage.isEmpty {
                    MessageBodyTextView(
                        text: message.plainTextMessage,
                        isSentBySelf: message.isSentBySelf
                    )
                }
                if !message.images.isEmpty {
                    ForEach(0..<message.images.count, id: \.self) { index in
                        let sourceID = "\(message.id.uuidString)-\(index)"
                        let isHiddenForPreview = (hiddenPreviewSourceID == sourceID)
                        Button(action: {
                            onImageTap(
                                MessageImageTapPayload(
                                    sourceID: sourceID,
                                    image: message.images[index]
                                )
                            )
                        }) {
                            Image(platformImage: message.images[index])
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 200)
                                .background(
                                    GeometryReader { geo in
                                        Color.clear.preference(
                                            key: MessageThumbnailFramePreferenceKey.self,
                                            value: [sourceID: geo.frame(in: .global)]
                                        )
                                    }
                                )
                                #if os(macOS)
                                .cornerRadius(10)
                                #else
                                .cornerRadius(12)
                                #endif
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(!isHiddenForPreview)
                        .opacity(isHiddenForPreview ? 0 : 1)
                        .animation(.easeOut(duration: 0.18), value: isHiddenForPreview)
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
            .foregroundColor(message.isSentBySelf ? .white : .primary)
            #else
            .padding(.horizontal, message.images.isEmpty ? 16 : 12)
            .padding(.vertical, 12)
            .background(
                message.isSentBySelf ? Color.accentColor : Color.systemGray3,
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .foregroundColor(message.isSentBySelf ? .white : .primary)
            #endif
            
            if showTimestamp {
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
            }
            }
            if !message.isSentBySelf { Spacer(minLength: otherMinGap) }
        }
    }
}

// MARK: - Private Message Bubble

private struct PrivateMessageBubbleView: View {
    let message: ChatMessage
    let onImageTap: (MessageImageTapPayload) -> Void
    let hiddenPreviewSourceID: String?
    let showSenderLabel: Bool
    let showTimestamp: Bool
    
    #if os(macOS)
    private let selfMinGap: CGFloat = 60
    private let otherMinGap: CGFloat = 80
    #else
    private let selfMinGap: CGFloat = 32
    private let otherMinGap: CGFloat = 40
    #endif
    
    var body: some View {
        HStack {
            if message.isSentBySelf { Spacer(minLength: selfMinGap) }
            VStack(alignment: message.isSentBySelf ? .trailing : .leading, spacing: 4) {
            // 私聊标签
            if showSenderLabel {
                HStack(spacing: 4) {
                    Image(systemName: "envelope.fill")
                        .font(.system(size: 10))
                    if message.isSentBySelf {
                        Text(
                            String(
                                format: NSLocalizedString("PM to %@", comment: ""),
                                message.privatePeerName ?? "?"
                            )
                        )
                            .font(.system(size: 12, weight: .semibold))
                    } else {
                        Text(
                            String(
                                format: NSLocalizedString("PM from %@", comment: ""),
                                message.privatePeerName ?? message.senderName
                            )
                        )
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .foregroundColor(.purple)
                .padding(.horizontal, 4)
            }
            
            // 消息内容
            VStack(alignment: .leading, spacing: 6) {
                if !message.plainTextMessage.isEmpty {
                    MessageBodyTextView(
                        text: message.plainTextMessage,
                        isSentBySelf: message.isSentBySelf
                    )
                }
                if !message.images.isEmpty {
                    ForEach(0..<message.images.count, id: \.self) { index in
                        let sourceID = "\(message.id.uuidString)-\(index)"
                        let isHiddenForPreview = (hiddenPreviewSourceID == sourceID)
                        Button(action: {
                            onImageTap(
                                MessageImageTapPayload(
                                    sourceID: sourceID,
                                    image: message.images[index]
                                )
                            )
                        }) {
                            Image(platformImage: message.images[index])
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 200)
                                .background(
                                    GeometryReader { geo in
                                        Color.clear.preference(
                                            key: MessageThumbnailFramePreferenceKey.self,
                                            value: [sourceID: geo.frame(in: .global)]
                                        )
                                    }
                                )
                                #if os(macOS)
                                .cornerRadius(10)
                                #else
                                .cornerRadius(12)
                                #endif
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(!isHiddenForPreview)
                        .opacity(isHiddenForPreview ? 0 : 1)
                        .animation(.easeOut(duration: 0.18), value: isHiddenForPreview)
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
            .foregroundColor(message.isSentBySelf ? .white : .primary)
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
            .foregroundColor(message.isSentBySelf ? .white : .primary)
            #endif
            
            if showTimestamp {
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
            }
            }
            if !message.isSentBySelf { Spacer(minLength: otherMinGap) }
        }
    }
}

struct ImageConfirmationView: View {
    let image: PlatformImage
    let onCancel: () -> Void
    let onSend: (PlatformImage) async -> Void
    @State private var isSending = false
    
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
                
                HStack(spacing: 20) {
                    Button("Cancel", role: .cancel) {
                        InteractionFeedback.cancel()
                        onCancel()
                    }
                        .buttonStyle(.bordered).controlSize(.large)
                        .keyboardShortcut(.cancelAction)
                    Button("Send") {
                        guard !isSending else { return }
                        isSending = true
                        Task { await onSend(image) }
                    }
                    .disabled(isSending)
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.bottom)
        .interactiveDismissDisabled(isSending)
        .onAppear {
            AppState.shared.setAutomationCurrentScreen("imageSendConfirm")
        }
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
                    .glassEffect(.regular.interactive(), in: .circle)
                    .shadow(color: inputControlShadowColor, radius: inputControlShadowRadius, x: 0, y: inputControlShadowYOffset)
                
                messageTextField
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20.0))
                    .shadow(color: inputControlShadowColor, radius: inputControlShadowRadius, x: 0, y: inputControlShadowYOffset)
                
                sendButton
                    .glassEffect(.regular.interactive().tint(sendButtonGlassTint), in: .circle)
                    .shadow(color: inputControlShadowColor, radius: inputControlShadowRadius, x: 0, y: inputControlShadowYOffset)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    private var sendButtonGlassTint: Color {
        if text.isEmpty {
            return colorScheme == .light ? .gray.opacity(0.55) : .gray.opacity(0.7)
        }
        return colorScheme == .light ? .blue.opacity(0.8) : .blue.opacity(0.7)
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
                        .fill(colorScheme == .dark ? Color.black.opacity(0.06) : Color.clear)
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
            prompt: Text("Type a message...").foregroundColor(.secondary),
            axis: .vertical
        )
            .foregroundStyle(.primary)
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
            .onKeyPress(KeyEquivalent("v"), phases: .down) { keyPress in
                guard keyPress.modifiers.contains(.command) else { return .ignored }
                return handleMacPasteFromPasteboard() ? .handled : .ignored
            }
            .onPasteCommand(of: [.image]) { providers in
                handlePastedImages(providers)
            }
            #else
            .onKeyPress(.return, phases: .down) { keyPress in
                if keyPress.modifiers.contains(.command) {
                    text += "\n"
                    return .handled
                }
                onSendText()
                return .handled
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
            Circle()
                .fill(Color.white.opacity(0.001))
                #if os(macOS)
                .frame(width: 32, height: 32)
                #else
                .frame(width: 40, height: 40)
                #endif
                .overlay(
                    Image(systemName: "arrow.up")
                        #if os(macOS)
                        .font(.system(size: 16, weight: .semibold))
                        #else
                        .font(.system(size: 17, weight: .semibold))
                        #endif
                        .foregroundColor(.white)
                )
        }
        .buttonStyle(.plain)
        .disabled(text.isEmpty)
    }
}

private struct StickyHeaderAdaptiveTextModifier: ViewModifier {
    func body(content: Content) -> some View {
        ZStack {
            content
                .foregroundColor(.primary)
        }
    }
}

extension CGSize {
    static func + (lhs: CGSize, rhs: CGSize) -> CGSize {
        return CGSize(width: lhs.width + rhs.width, height: lhs.height + rhs.height)
    }
}
