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
            let w = geometry.size.width
            let h = geometry.size.height

            // 安全限制，防止 crash
            let safeLower = max(0, min(1, CGFloat(lower)))
            let safeUpper = max(safeLower, min(1, CGFloat(upper)))

            ZStack(alignment: .leading) {
                // 1. 底层：暗色背景 (显示阈值区间)
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.red.opacity(0.2))
                        .frame(width: safeLower * w)

                    Rectangle()
                        .fill(Color.yellow.opacity(0.2))
                        .frame(width: (safeUpper - safeLower) * w)

                    Rectangle()
                        .fill(Color.green.opacity(0.2))
                }

                // 2. 顶层：亮色前景 (被 mask 裁剪)
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.red)
                        .frame(width: safeLower * w)

                    Rectangle()
                        .fill(Color.yellow)
                        .frame(width: (safeUpper - safeLower) * w)

                    Rectangle()
                        .fill(Color.green)
                }
                .mask(
                    HStack {
                        Rectangle()
                            .frame(width: min(1.0, max(0, CGFloat(level))) * w)
                        Spacer(minLength: 0)
                    }
                    .animation(.linear(duration: 0.05), value: level)
                )

                // 3. 阈值分割线 (指示器)
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.5))
                        .frame(width: 2, height: h)
                        .offset(x: safeLower * w)

                    Rectangle()
                        .fill(Color.primary.opacity(0.5))
                        .frame(width: 2, height: h)
                        .offset(x: safeUpper * w)
                }
            }
        }
        .frame(height: 24)
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .clipped()
    }
}
