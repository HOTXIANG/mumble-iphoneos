//
//  MumbleWidgetBundle.swift
//  Mumble
//
//  Created by 王梓田 on 1/3/26.
//

import WidgetKit
import SwiftUI
import ActivityKit

@main
struct MumbleWidgetBundle: WidgetBundle {
    var body: some Widget {
        MumbleLiveActivity()
    }
}
