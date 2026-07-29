//
//  NotchWindowController.swift
//  ClaudeIsland
//
//  Controls the notch window positioning and lifecycle.
//  The window is kept just large enough for the currently visible content
//  (notch + activity bar when closed, panel + shadow margin when opened),
//  anchored top-center. Everything outside the window naturally receives
//  clicks — no pass-through hacks needed.
//

import AppKit
import Combine
import SwiftUI

class NotchWindowController: NSWindowController {
    let viewModel: NotchViewModel
    private let screen: NSScreen
    private var cancellables = Set<AnyCancellable>()
    private var pendingShrink: DispatchWorkItem?
    private var frameUpdateScheduled = false

    /// Margin around the visible content for shadow and hover slack
    private static let contentMargin: CGFloat = 24
    /// Horizontal padding the opened panel adds around its content (corner radii)
    private static let openedHorizontalPadding: CGFloat = 52

    init(screen: NSScreen) {
        self.screen = screen

        let screenFrame = screen.frame
        let notchSize = screen.notchSize

        // Height envelope used by NotchGeometry (not the actual window height)
        let windowHeight: CGFloat = 750

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

        // Create the window (initial frame: closed state)
        let notchWindow = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init(window: notchWindow)

        let hostingController = NotchViewController(viewModel: viewModel)
        notchWindow.contentViewController = hostingController

        notchWindow.setFrame(desiredFrame(), display: false)

        // Track focus behavior on open
        viewModel.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak notchWindow, weak viewModel] status in
                if status == .opened, viewModel?.openReason != .notification {
                    // Don't steal focus when opened by notification (task finished)
                    NSApp.activate(ignoringOtherApps: false)
                    notchWindow?.makeKey()
                }
            }
            .store(in: &cancellables)

        // Resize the window whenever the content envelope may have changed
        // (status, content type, dynamic panel sizes, activity bar width)
        viewModel.objectWillChange
            .sink { [weak self] _ in self?.scheduleFrameUpdate() }
            .store(in: &cancellables)

        // Close on clicks outside the window. Global monitor: clicks in other
        // apps (they already received the click — no repost needed).
        // Local monitor: clicks inside our window are filtered by the frame check.
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

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Window Frame Management

    /// Coalesce frame updates: objectWillChange fires before state mutates,
    /// so apply on the next runloop turn.
    private func scheduleFrameUpdate() {
        guard !frameUpdateScheduled else { return }
        frameUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.frameUpdateScheduled = false
            self.updateWindowFrame()
        }
    }

    private func desiredFrame() -> NSRect {
        let screenFrame = screen.frame
        let margin = Self.contentMargin
        let width: CGFloat
        let height: CGFloat

        switch viewModel.status {
        case .opened:
            let panel = viewModel.openedSize
            width = panel.width + Self.openedHorizontalPadding + margin * 2
            height = panel.height + margin * 2
        case .closed, .popping:
            let notch = viewModel.deviceNotchRect
            width = notch.width + viewModel.closedExpansionWidth + margin * 2
            // Extra headroom below the notch for the bounce animation
            height = notch.height + 20
        }

        return NSRect(
            x: (screenFrame.minX + screenFrame.maxX - width) / 2,
            y: screenFrame.maxY - height,
            width: width,
            height: height
        )
    }

    /// Grow immediately (content must never be clipped), shrink after the
    /// close/collapse animation has finished.
    private func updateWindowFrame() {
        guard let window = self.window else { return }
        let target = desiredFrame()
        guard target != window.frame else { return }

        pendingShrink?.cancel()
        pendingShrink = nil

        let current = window.frame
        let growsWidth = target.width > current.width
        let growsHeight = target.height > current.height
        let shrinksWidth = target.width < current.width
        let shrinksHeight = target.height < current.height

        if growsWidth || growsHeight {
            // Apply the union so no dimension shrinks mid-animation
            let unionWidth = max(target.width, current.width)
            let unionHeight = max(target.height, current.height)
            let screenFrame = screen.frame
            let union = NSRect(
                x: (screenFrame.minX + screenFrame.maxX - unionWidth) / 2,
                y: screenFrame.maxY - unionHeight,
                width: unionWidth,
                height: unionHeight
            )
            // display: false — synchronous display work inside setFrame can
            // land in the AppKit display cycle, where SwiftUI's reaction to
            // the geometry change re-enters the constraints pass and crashes
            window.setFrame(union, display: false)
        }

        if shrinksWidth || shrinksHeight {
            let work = DispatchWorkItem { [weak self] in
                guard let self, let window = self.window else { return }
                window.setFrame(self.desiredFrame(), display: false)
            }
            pendingShrink = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
    }
}
