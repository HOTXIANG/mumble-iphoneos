//
//  MumbleContentView.swift
//  Mumble
//
//  Created by 王梓田 on 2025/6/27.
//

import SwiftUI

// 简化的内容视图协议
protocol MumbleContentView: View {
    associatedtype ContentBody: View
    var navigationConfig: any NavigationConfigurable { get }
    var contentBody: ContentBody { get }
}

extension MumbleContentView {
    var body: some View {
        MumbleNavigationView(config: navigationConfig) {
            contentBody
        }
    }
}
