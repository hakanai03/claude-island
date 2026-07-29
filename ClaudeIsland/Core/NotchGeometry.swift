//
//  NotchGeometry.swift
//  ClaudeIsland
//
//  Geometry constants for the notch
//

import CoreGraphics
import Foundation

/// Static geometry facts about the notch and screen.
/// Hit-testing is handled by AppKit now that the window is sized to its
/// content, so this only carries layout inputs.
struct NotchGeometry: Sendable {
    let deviceNotchRect: CGRect
    let screenRect: CGRect
    let windowHeight: CGFloat
}
