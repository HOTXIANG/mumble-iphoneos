//
//  ToastView.swift
//  Mumble
//
//  Created by 王梓田 on 12/8/25.
//

import SwiftUI

struct ToastView: View {
    let toast: AppToast
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundColor(iconColor)
                .font(.system(size: 20))
            
            Text(toast.message)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.primary)
                .multilineTextAlignment(.leading)
            
            Spacer()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(.regularMaterial) // 毛玻璃背景
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
        .padding(.horizontal, 16)
        .padding(.top, 8) // 距离顶部的距离
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
