//
//  NotchViewController.swift
//  ClaudeIsland
//
//  Hosts the SwiftUI NotchView in AppKit
//

import AppKit
import SwiftUI

/// Hosting view for the notch content.
/// The window is sized to the visible content, so no custom hit-testing is
/// needed — AppKit's normal dispatch applies.
class NotchHostingView<Content: View>: NSHostingView<Content> {
    /// Deliver the first click even when the panel is not key.
    /// Peek opens without activating the app (openReason == .notification),
    /// so without this the initial click is swallowed by window activation.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

class NotchViewController: NSViewController {
    private let viewModel: NotchViewModel
    private var hostingView: NotchHostingView<NotchView>!

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        hostingView = NotchHostingView(rootView: NotchView(viewModel: viewModel))
        self.view = hostingView
    }
}
