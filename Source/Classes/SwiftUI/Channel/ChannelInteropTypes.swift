//
//  ChannelInteropTypes.swift
//  Mumble
//

import Foundation

/// Wrap non-Sendable ObjC instances when hopping through async closures.
struct UnsafeTransfer<T>: @unchecked Sendable {
    let value: T
}
