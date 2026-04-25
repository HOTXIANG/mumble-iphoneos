//
//  AudioBarView.swift
//  Mumble
//

import SwiftUI

struct AudioBarView: View {
    var level: Float      // 当前音量 (0.0 - 1.0)
    var lower: Float      // 下限 (Silence Below)
    var upper: Float      // 上限 (Speech Above)

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let width = size.width
                let height = size.height
                let safeLevel = min(1.0, max(0, CGFloat(level)))
                let safeLower = max(0, min(1, CGFloat(lower)))
                let safeUpper = max(safeLower, min(1, CGFloat(upper)))
                let lowerX = safeLower * width
                let upperX = safeUpper * width
                let levelX = safeLevel * width

                fillBand(in: &context, x: 0, width: lowerX, height: height, color: .red.opacity(0.2))
                fillBand(in: &context, x: lowerX, width: upperX - lowerX, height: height, color: .yellow.opacity(0.2))
                fillBand(in: &context, x: upperX, width: width - upperX, height: height, color: .green.opacity(0.2))

                fillBand(in: &context, x: 0, width: min(lowerX, levelX), height: height, color: .red)
                fillBand(in: &context, x: lowerX, width: min(max(levelX - lowerX, 0), upperX - lowerX), height: height, color: .yellow)
                fillBand(in: &context, x: upperX, width: max(levelX - upperX, 0), height: height, color: .green)

                fillBand(in: &context, x: lowerX, width: 2, height: height, color: .primary.opacity(0.5))
                fillBand(in: &context, x: upperX, width: 2, height: height, color: .primary.opacity(0.5))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(height: 24)
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .clipped()
    }

    private func fillBand(in context: inout GraphicsContext, x: CGFloat, width: CGFloat, height: CGFloat, color: Color) {
        guard width > 0 else { return }
        context.fill(
            Path(CGRect(x: x, y: 0, width: width, height: height)),
            with: .color(color)
        )
    }
}

struct LiveAudioBarView: View {
    let meter: AudioMeterModel
    let lower: Float
    let upper: Float

    var body: some View {
        TimelineView(.animation(minimumInterval: AudioMeterModel.refreshInterval)) { _ in
            AudioBarView(
                level: meter.levelSnapshot(),
                lower: lower,
                upper: upper
            )
        }
    }
}

struct LiveAudioMeterPercentText: View {
    let meter: AudioMeterModel

    var body: some View {
        TimelineView(.animation(minimumInterval: AudioMeterModel.refreshInterval)) { _ in
            Text("\(Int((Double(meter.levelSnapshot()) * 100).rounded()))%")
        }
    }
}
