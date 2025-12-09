//
//  MumbleUIComponents.swift
//  Mumble
//
//  Created by 王梓田 on 2025/6/27.
//

import SwiftUI
import UIKit

// 通用菜单行 - 已升级为 Liquid Glass 风格
struct MenuRowView: View {
    let title: String
    let icon: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    // 修改 1: 使用 .primary 替代 .white。
                    // 这能保证图标在任何背景下都清晰可见（Vibrancy 效果）。
                    .foregroundStyle(.primary)
                    .frame(width: 24, height: 24)
                    .font(.system(size: 18, weight: .medium))
                
                Text(title)
                    // 修改 2: 同样使用 .primary 替代 .white。
                    .foregroundStyle(.primary)
                    .font(.system(size: 17, weight: .medium))
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    // 对于装饰性元素，可以使用 .secondary 或 .tertiary
                    .foregroundStyle(.secondary)
                    .font(.system(size: 14, weight: .medium))
            }
            .padding(.horizontal, 20)
            .frame(height: 54)
            // 修改 3: 这是核心！使用 .regularMaterial 实现官方推荐的玻璃模糊效果。
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// 通用列表行 (保持不变，但为未来做好了准备)
struct ListRowView: View {
    let title: String
    let subtitle: String?
    let action: (() -> Void)?
    
    init(title: String, subtitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.action = action
    }
    
    var body: some View {
        Button {
            action?()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 17))
                        .foregroundColor(.primary)
                    
                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(action == nil)
    }
}

// 头部图标视图 - 同样更新图标颜色以保持一致性
struct WelcomeHeaderView: View {
    var body: some View {
        VStack(spacing: 16) {
            // ✅ 核心修复：添加 resizable 和 frame 限制
            Image("TransparentLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 300, height: 300)
                .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
        }
    }
}
