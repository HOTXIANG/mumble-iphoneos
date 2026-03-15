//
//  ToastView.swift
//  Mumble
//
//  Created by 王梓田 on 12/8/25.
//

import SwiftUI

struct ToastView: View {
    let toast: AppToast

    private let cornerRadius: CGFloat = 24

    private let maxBannerWidth: CGFloat = {
        #if os(macOS)
        return 620
        #elseif os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? 620 : .infinity
        #else
        return .infinity
        #endif
    }()
    
    var body: some View {
        HStack(spacing: 12) {
            if toast.isChatMessageBanner {
                leadingAvatarView

                VStack(alignment: .leading, spacing: 2) {
                    Text(toast.senderName ?? "")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Text(toast.bodyText ?? "")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            } else {
                Image(systemName: iconName)
                    .foregroundColor(iconColor)
                    .font(.system(size: 20))

                Text(toast.message)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .modifier(GlassEffectModifier(cornerRadius: cornerRadius))
        .frame(maxWidth: maxBannerWidth)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8) // 距离顶部的距离
    }

    @ViewBuilder
    private var leadingAvatarView: some View {
        if let avatar = toast.avatarImage {
            Image(platformImage: avatar)
                .resizable()
                .scaledToFill()
                .frame(width: 34, height: 34)
                .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
                .frame(width: 34, height: 34)
        }
    }
    
    private var iconName: String {
        switch toast.type {
        case .error: return "exclamationmark.triangle.fill"
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        }
    }
    
    private var iconColor: Color {
        switch toast.type {
        case .error: return .red
        case .success: return .green
        case .info: return .blue
        }
    }
}
