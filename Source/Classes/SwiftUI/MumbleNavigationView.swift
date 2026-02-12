//
//  MumbleNavigationView.swift
//  Mumble
//
//  Created by 王梓田 on 2025/6/27.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// 导航配置协议 (保持不变)
protocol NavigationConfigurable {
    var title: String { get }
    var leftBarItems: [NavigationBarItem] { get }
    var rightBarItems: [NavigationBarItem] { get }
}

// 导航栏按钮项 (保持不变)
struct NavigationBarItem {
    let title: String?
    let systemImage: String?
    let action: () -> Void
    
    init(title: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = nil
        self.action = action
    }
    
    init(systemImage: String, action: @escaping () -> Void) {
        self.title = nil
        self.systemImage = systemImage
        self.action = action
    }
}

// 导航视图 (保持不变)
struct MumbleNavigationView<Content: View>: View {
    let config: NavigationConfigurable
    let content: Content
    
    init(config: NavigationConfigurable, @ViewBuilder content: () -> Content) {
        self.config = config
        self.content = content()
    }
    
    var body: some View {
        content
            .navigationTitle(config.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .toolbarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    ForEach(Array(config.leftBarItems.enumerated()), id: \.offset) { index, item in
                        createBarButton(item)
                    }
                }
                
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    ForEach(Array(config.rightBarItems.enumerated()), id: \.offset) { index, item in
                        createBarButton(item)
                    }
                }
                #else
                ToolbarItemGroup(placement: .automatic) {
                    ForEach(Array(config.leftBarItems.enumerated()), id: \.offset) { index, item in
                        createBarButton(item)
                    }
                }
                
                ToolbarItemGroup(placement: .automatic) {
                    ForEach(Array(config.rightBarItems.enumerated()), id: \.offset) { index, item in
                        createBarButton(item)
                    }
                }
                #endif
            }
    }
    
    @ViewBuilder
    private func createBarButton(_ item: NavigationBarItem) -> some View {
        Button {
            item.action()
        } label: {
            if let title = item.title {
                Text(NSLocalizedString(title, comment: ""))
                    .foregroundColor(.primary)
            } else if let systemImage = item.systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// 导航管理器 (保持不变)
class NavigationManager: ObservableObject {
    @Published var navigationPath: NavigationPath = NavigationPath()
    
    func navigate(to destination: NavigationDestination) {
        navigationPath.append(destination)
    }
    
    func goBack() {
        if !navigationPath.isEmpty {
            navigationPath.removeLast()
        }
    }
    
    func goToRoot() {
        navigationPath = NavigationPath()
    }
}


// --- 核心修复区域 ---

// 1. 定义 SwiftUI 视图的类型
enum SwiftUIControllerType: Hashable {
    case favouriteServerList
    case favouriteServerEdit(primaryKey: Int?)
    case channelList
}

// 2. 定义导航目标，并补全协议实现
enum NavigationDestination: Hashable {
    case objectiveC(ObjectiveCControllerType)
    case swiftUI(SwiftUIControllerType)
    
    // **已补全：手动实现 Equatable 协议**
    // 告诉 Swift 如何判断两个 NavigationDestination 是否相等
    static func == (lhs: NavigationDestination, rhs: NavigationDestination) -> Bool {
        switch (lhs, rhs) {
        case (.objectiveC(let lType), .objectiveC(let rType)):
            return lType == rType
        case (.swiftUI(let lType), .swiftUI(let rType)):
            return lType == rType
        default:
            return false
        }
    }
    
    // **已补全：手动实现 Hashable 协议**
    // 告诉 Swift 如何为 NavigationDestination 生成哈希值
    func hash(into hasher: inout Hasher) {
        switch self {
        case .objectiveC(let type):
            hasher.combine("objectiveC")
            hasher.combine(type)
        case .swiftUI(let type):
            hasher.combine("swiftUI")
            hasher.combine(type)
        }
    }
}

// Objective-C 控制器类型枚举 (保持不变)
enum ObjectiveCControllerType: Hashable, Equatable {
    case favouriteServers
    case preferences
    case legal
    case certificates
}

// Objective-C 视图控制器包装器 (保持不变)
#if os(iOS)
struct ObjectiveCViewWrapper: UIViewControllerRepresentable {
    let controllerType: ObjectiveCControllerType
    
    func makeUIViewController(context: Context) -> UIViewController {
        switch controllerType {
        case .favouriteServers:
            return MUFavouriteServerListController()
        case .preferences:
            return MUPreferencesViewController()
        case .legal:
            return MULegalViewController()
        case .certificates:
            return MUCertificatePreferencesViewController()
        }
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
#endif
