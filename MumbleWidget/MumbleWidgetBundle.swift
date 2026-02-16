//
//  MumbleWidgetBundle.swift
//  Mumble
//
//  Created by 王梓田 on 1/3/26.
//

import WidgetKit
import SwiftUI

@main
struct MumbleWidgetBundle: WidgetBundle {
    var body: some Widget {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        MumbleLiveActivity()
        #endif
        MumbleServerWidget()
    }
}
