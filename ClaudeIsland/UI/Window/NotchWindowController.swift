//
//  NotchWindowController.swift
//  ClaudeIsland
//
//  Controls the notch windows and lifecycle.
//
//  Two windows, neither of which ever resizes while hosting SwiftUI:
//  - panelWindow: fixed-size envelope (max panel bounds), top-center, hosts
//    the SwiftUI NotchView. Ignores mouse events while closed so clicks pass
//    through; accepts them while opened. Never resizing avoids macOS 26's
//    fatal SwiftUI-in-layout-pass re-entrancy when NSHostingView windows
//    change frame.
//  - hotspotWindow: a tiny plain-AppKit window over the notch (+ activity
//    bar) that provides hover/click detection while the panel is closed.
//    It has no SwiftUI, so resizing it (activity bar width) is safe.
//

import AppKit
import Combine
import SwiftUI

/// Plain view over the notch: forwards hover and click to the view model
private final class NotchHotspotView: NSView {
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

class NotchWindowController: NSWindowController {
    let viewModel: NotchViewModel
    private let screen: NSScreen
    private var cancellables = Set<AnyCancellable>()
    private var hotspotWindow: NSPanel?

    /// Fixed envelope for the panel window: large enough for every opened
    /// content size (chat 600x580 + corner padding + shadow margins)
    private static let envelopeSize = NSSize(width: 700, height: 750)

    init(screen: NSScreen) {
        self.screen = screen

        let screenFrame = screen.frame
        let notchSize = screen.notchSize

        let windowHeight: CGFloat = Self.envelopeSize.height

        // Device notch rect - positioned at center
        let deviceNotchRect = CGRect(
            x: (screenFrame.width - notchSize.width) / 2,
            y: 0,
            width: notchSize.width,
            height: notchSize.height
        )

        // Create view model
        self.viewModel = NotchViewModel(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenFrame,
            windowHeight: windowHeight,
            hasPhysicalNotch: screen.hasPhysicalNotch
        )

        // Fixed panel window frame — never changes after this
        let panelFrame = NSRect(
            x: (screenFrame.minX + screenFrame.maxX - Self.envelopeSize.width) / 2,
            y: screenFrame.maxY - Self.envelopeSize.height,
            width: Self.envelopeSize.width,
            height: Self.envelopeSize.height
        )

        let notchWindow = NotchPanel(
            contentRect: panelFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init(window: notchWindow)

        let hostingController = NotchViewController(viewModel: viewModel)
        notchWindow.contentViewController = hostingController
        notchWindow.setFrame(panelFrame, display: true)

        // Closed: clicks pass through the (invisible) envelope.
        // Opened: panel content takes clicks; outside-panel clicks inside the
        // envelope are handled by the SwiftUI scrim (close).
        notchWindow.ignoresMouseEvents = true

        setupHotspotWindow()

        viewModel.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak notchWindow, weak viewModel] status in
                switch status {
                case .opened:
                    notchWindow?.ignoresMouseEvents = false
                    self?.hotspotWindow?.orderOut(nil)
                    if viewModel?.openReason != .notification {
                        // Don't steal focus when opened by notification
                        NSApp.activate(ignoringOtherApps: false)
                        notchWindow?.makeKey()
                    }
                case .closed, .popping:
                    notchWindow?.ignoresMouseEvents = true
                    self?.hotspotWindow?.orderFrontRegardless()
                }
            }
            .store(in: &cancellables)

        // The activity bar widens the clickable notch area while closed
        viewModel.$closedExpansionWidth
            .receive(on: DispatchQueue.main)
            .sink { [weak self] width in
                self?.updateHotspotFrame(expansionWidth: width)
            }
            .store(in: &cancellables)

        // Close when clicking outside the envelope (other apps' windows —
        // they already received the click, so nothing needs re-posting)
        EventMonitors.shared.mouseDown
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.viewModel.status == .opened,
                      let window = self.window else { return }
                if !window.frame.contains(NSEvent.mouseLocation) {
                    self.viewModel.notchClose()
                }
            }
            .store(in: &cancellables)

        // Perform boot animation after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.viewModel.performBootAnimation()
        }

        #if DEBUG
        setupUITestHook()
        #endif
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Hotspot Window

    private func setupHotspotWindow() {
        let hotspot = NSPanel(
            contentRect: hotspotFrame(expansionWidth: viewModel.closedExpansionWidth),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        hotspot.isFloatingPanel = true
        hotspot.isOpaque = false
        hotspot.backgroundColor = .clear
        hotspot.hasShadow = false
        hotspot.isMovable = false
        hotspot.collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        hotspot.level = .mainMenu + 4
        hotspot.ignoresMouseEvents = false

        let view = NotchHotspotView()
        view.onHover = { [weak self] hovering in
            self?.viewModel.handleHover(hovering)
        }
        view.onClick = { [weak self] in
            guard let self, self.viewModel.status != .opened else { return }
            self.viewModel.notchOpen(reason: .click)
        }
        hotspot.contentView = view

        hotspot.orderFrontRegardless()
        hotspotWindow = hotspot
    }

    private func hotspotFrame(expansionWidth: CGFloat) -> NSRect {
        let screenFrame = screen.frame
        let notch = viewModel.deviceNotchRect
        let width = notch.width + expansionWidth + 20
        let height = notch.height + 10
        return NSRect(
            x: (screenFrame.minX + screenFrame.maxX - width) / 2,
            y: screenFrame.maxY - height,
            width: width,
            height: height
        )
    }

    private func updateHotspotFrame(expansionWidth: CGFloat) {
        // Plain AppKit view — resizing this window is safe
        hotspotWindow?.setFrame(hotspotFrame(expansionWidth: expansionWidth), display: false)
    }

    #if DEBUG
    /// Debug-only UI test hook: lets automated tests drive clicks through the
    /// real in-process event path (window.sendEvent → responder chain → SwiftUI)
    /// without Accessibility permission. Post a distributed notification named
    /// "com.claudeisland.uitest" with object "click:<x>:<yFromTop>" in screen
    /// coordinates (origin top-left).
    private func setupUITestHook() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.claudeisland.uitest"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let cmd = note.object as? String else { return }
            let parts = cmd.split(separator: ":")
            switch parts.first {
            case "click":
                guard parts.count == 3,
                      let x = Double(parts[1]), let yTop = Double(parts[2]) else { return }
                self.uitestClick(x: CGFloat(x), yFromTop: CGFloat(yTop))
            case "close":
                self.viewModel.notchClose()
            case "open":
                self.viewModel.notchOpen(reason: .click)
            case "instances":
                self.viewModel.exitChat()
            case "dumptree":
                let pid = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
                let tree = ProcessTreeBuilder.shared.buildTree()
                var out = "tree size: \(tree.count)\n"
                var current = pid
                var depth = 0
                while current > 1 && depth < 20 {
                    guard let info = tree[current] else { out += "MISSING \(current)\n"; break }
                    out += "\(info.pid) ppid=\(info.ppid) tty=\(info.tty ?? "nil") cmd=\(info.command)\n"
                    current = info.ppid
                    depth += 1
                }
                out += "isInTmux=\(ProcessTreeBuilder.shared.isInTmux(pid: pid, tree: tree)) "
                out += "hasClaudeAncestor=\(ProcessTreeBuilder.shared.hasClaudeAncestor(pid: pid, tree: tree))\n"
                try? out.write(toFile: "/tmp/claude-island-tree.txt", atomically: true, encoding: .utf8)
            case "dumpsessions":
                Task { @MainActor in
                    var out = ""
                    for s in await SessionStore.shared.allSessions() {
                        out += "id=\(s.sessionId.prefix(8)) tty=\(s.tty ?? "nil") pid=\(s.pid.map(String.init) ?? "nil") "
                        out += "phase=\(String(describing: s.phase).prefix(30)) headless=\(s.isHeadless) subagent=\(s.isSubagent) bg=\(s.pendingBackgroundTasks) "
                        out += "tmux=\(s.isInTmux) cwd=\(s.cwd) title=\(s.displayTitle.prefix(40))\n"
                    }
                    try? out.write(toFile: "/tmp/claude-island-sessions.txt", atomically: true, encoding: .utf8)
                }
            case "dumphistory":
                let prefix = parts.count > 1 ? String(parts[1]) : ""
                Task { @MainActor in
                    if !ChatHistoryManager.shared.histories.keys.contains(where: { $0.hasPrefix(prefix) }),
                       let s = await SessionStore.shared.allSessions().first(where: { $0.sessionId.hasPrefix(prefix) }) {
                        await ChatHistoryManager.shared.loadFromFile(sessionId: s.sessionId, cwd: s.cwd)
                    }
                    let all = ChatHistoryManager.shared.histories
                    guard let (sid, items) = all.first(where: { $0.key.hasPrefix(prefix) }) else {
                        try? "no session matching \(prefix)".write(toFile: "/tmp/claude-island-history.txt", atomically: true, encoding: .utf8)
                        return
                    }
                    var out = "session \(sid): \(items.count) items\n"
                    for it in items.suffix(40) {
                        switch it.type {
                        case .user(let t): out += "USER: \(t.prefix(60))\n"
                        case .assistant(let t): out += "ASSISTANT: \(t.prefix(60))\n"
                        case .thinking(let t): out += "THINKING: \(t.prefix(40))\n"
                        case .interrupted: out += "INTERRUPTED\n"
                        case .toolCall(let t):
                            out += "TOOL name=[\(t.name)] status=\(t.status) preview=[\(t.inputPreview.prefix(40))] subtools=\(t.subagentTools.count)\n"
                        }
                    }
                    try? out.write(toFile: "/tmp/claude-island-history.txt", atomically: true, encoding: .utf8)
                }
            default:
                break
            }
        }
    }

    private func uitestClick(x: CGFloat, yFromTop: CGFloat) {
        guard let window = self.window else { return }
        let screenPoint = CGPoint(x: x, y: screen.frame.maxY - yFromTop)
        let windowPoint = window.convertPoint(fromScreen: screenPoint)

        func synthesize(_ type: NSEvent.EventType) {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: windowPoint,
                modifierFlags: [],
                timestamp: Foundation.ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ) else { return }
            window.sendEvent(event)
        }

        synthesize(.leftMouseDown)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            synthesize(.leftMouseUp)
        }
    }
    #endif
}
