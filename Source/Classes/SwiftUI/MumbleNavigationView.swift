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

// Navigation state survives changes between compact and regular-width layouts.
class NavigationManager: ObservableObject {
    @Published var navigationPath: [NavigationDestination] = []
    @Published var presentsFavouriteServersSheet = false {
        didSet {
            if oldValue && !presentsFavouriteServersSheet {
                isDismissingFavouriteServersSheet = true
            }
        }
    }
    private var usesTabletLayout = false
    private var isDismissingFavouriteServersSheet = false
    private var restoreFavouriteServersAfterDismissal = false
    private var isFavouriteEditorPresented = false

    func openFavouriteServers() {
        guard !isDismissingFavouriteServersSheet else { return }
        if usesTabletLayout {
            presentsFavouriteServersSheet = true
        } else if navigationPath.last != .swiftUI(.favouriteServerList) {
            navigate(to: .swiftUI(.favouriteServerList))
        }
    }

    func updateFavouriteServersLayout(usesTabletLayout: Bool) {
        self.usesTabletLayout = usesTabletLayout
        adaptFavouriteServersPresentation()
    }

    func setFavouriteEditorPresented(_ isPresented: Bool) {
        isFavouriteEditorPresented = isPresented
        if !isPresented {
            adaptFavouriteServersPresentation()
        }
    }

    private func adaptFavouriteServersPresentation() {
        // Keep an active editor (including its unsaved fields) attached until
        // its dismissal completes. Rapid pose changes use the latest layout.
        guard !isFavouriteEditorPresented, !isDismissingFavouriteServersSheet else { return }
        if usesTabletLayout, navigationPath.last == .swiftUI(.favouriteServerList) {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                navigationPath.removeLast()
                presentsFavouriteServersSheet = true
            }
        } else if !usesTabletLayout, presentsFavouriteServersSheet {
            restoreFavouriteServersAfterDismissal = true
            presentsFavouriteServersSheet = false
        }
    }

    func favouriteServersSheetDidDismiss() {
        isDismissingFavouriteServersSheet = false
        guard restoreFavouriteServersAfterDismissal else { return }
        restoreFavouriteServersAfterDismissal = false
        openFavouriteServers()
    }

    func dismissFavouriteServersSheet() {
        restoreFavouriteServersAfterDismissal = false
        presentsFavouriteServersSheet = false
    }
    
    func navigate(to destination: NavigationDestination) {
        navigationPath.append(destination)
    }
    
    func goBack() {
        if !navigationPath.isEmpty {
            navigationPath.removeLast()
        }
    }
    
    func goToRoot() {
        navigationPath = []
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
    case swiftUI(SwiftUIControllerType)
}
