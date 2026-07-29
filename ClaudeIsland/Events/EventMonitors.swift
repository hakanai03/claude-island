//
//  EventMonitors.swift
//  ClaudeIsland
//
//  Singleton that aggregates all event monitors.
//  Only a mouseDown monitor remains: hover is handled by SwiftUI (.onHover)
//  now that the window is sized to its content, and clicks inside the window
//  go through normal AppKit dispatch. This monitor exists solely to close the
//  opened panel when the user clicks outside the window.
//

import AppKit
import Combine

class EventMonitors {
    static let shared = EventMonitors()

    let mouseDown = PassthroughSubject<NSEvent, Never>()

    private var mouseDownMonitor: EventMonitor?

    private init() {
        setupMonitors()
    }

    private func setupMonitors() {
        mouseDownMonitor = EventMonitor(mask: .leftMouseDown) { [weak self] event in
            self?.mouseDown.send(event)
        }
        mouseDownMonitor?.start()
    }

    deinit {
        mouseDownMonitor?.stop()
    }
}
