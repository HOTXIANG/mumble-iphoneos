//
//  UIConstants.swift
//  Mumble
//
//  Created by Claude on 2026/3/4.
//

import SwiftUI

// MARK: - UI Constants

/// UI 尺寸配置，支持 iOS/macOS 差异化
enum UIConstants {
    // MARK: - Spacing

    enum Spacing {
        /// 行与行之间的间隙
        #if os(macOS)
        static let rowSpacing: CGFloat = 6.0
        /// 行内部的垂直边距
        static let rowPaddingV: CGFloat = 4.0
        /// 行内部的水平边距
        static let rowPaddingH: CGFloat = 8.0
        /// 水平间距
        static let hSpacing: CGFloat = 4.0
        #else
        static let rowSpacing: CGFloat = 7.0
        static let rowPaddingV: CGFloat = 6.0
        static let rowPaddingH: CGFloat = 12.0
        static let hSpacing: CGFloat = 6.0
        #endif
    }

    // MARK: - Font Size

    enum FontSize {
        /// 正文字体大小
        #if os(macOS)
        static let body: CGFloat = 13.0
        /// 图标大小
        static let icon: CGFloat = 14.0
        #else
        static let body: CGFloat = 16.0
        static let icon: CGFloat = 18.0
        #endif
    }

    // MARK: - Icon Size

    enum IconSize {
        /// 箭头大小
        #if os(macOS)
        static let arrow: CGFloat = 9.0
        /// 箭头占位宽度
        static let arrowWidth: CGFloat = 14.0
        /// 频道图标大小
        static let channel: CGFloat = 10.0
        /// 频道图标宽度
        static let channelWidth: CGFloat = 16.0
        #else
        static let arrow: CGFloat = 10.0
        static let arrowWidth: CGFloat = 16.0
        static let channel: CGFloat = 12.0
        static let channelWidth: CGFloat = 20.0
        #endif
    }

    // MARK: - Content Height

    enum ContentHeight {
        /// 内容高度
        #if os(macOS)
        static let row: CGFloat = 24.0
        #else
        static let row: CGFloat = 27.0
        #endif
    }

    // MARK: - Indent

    enum Indent {
        /// 每级缩进
        #if os(macOS)
        static let unit: CGFloat = 12.0
        #else
        static let unit: CGFloat = 16.0
        #endif
    }
}