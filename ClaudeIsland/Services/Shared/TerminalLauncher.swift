//
//  TerminalLauncher.swift
//  ClaudeIsland
//
//  Opens a terminal window at a given working directory
//

import AppKit
import Foundation
import os.log

/// Launches a terminal application at a specified directory
actor TerminalLauncher {
    static let shared = TerminalLauncher()
    private static let logger = Logger(subsystem: "com.claudeisland", category: "TerminalLauncher")

    private init() {}

    /// Open a terminal at the given working directory
    /// Detects the user's terminal from the session's process tree, falling back to Terminal.app
    func openTerminal(at cwd: String, sessionPid: Int?) async {
        let terminalApp = detectTerminalApp(sessionPid: sessionPid)
        Self.logger.info("Opening \(terminalApp, privacy: .public) at \(cwd, privacy: .public)")

        let url = URL(fileURLWithPath: cwd)
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = []

        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminalApp) {
            do {
                try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
            } catch {
                Self.logger.error("Failed to open terminal: \(error.localizedDescription, privacy: .public)")
                // Fallback to Terminal.app
                await openWithTerminalApp(cwd: cwd)
            }
        } else {
            // Bundle ID not found, fallback
            await openWithTerminalApp(cwd: cwd)
        }
    }

    /// Detect which terminal app the user is running from the process tree
    private func detectTerminalApp(sessionPid: Int?) -> String {
        guard let pid = sessionPid else {
            return "com.apple.Terminal"
        }

        let tree = ProcessTreeBuilder.shared.buildTree()
        guard let terminalPid = ProcessTreeBuilder.shared.findTerminalPid(forProcess: pid, tree: tree),
              let terminalInfo = tree[terminalPid] else {
            return "com.apple.Terminal"
        }

        // Map process command to bundle identifier
        let command = terminalInfo.command.lowercased()
        if command.contains("ghostty") { return "com.mitchellh.ghostty" }
        if command.contains("iterm") { return "com.googlecode.iterm2" }
        if command.contains("alacritty") { return "io.alacritty" }
        if command.contains("kitty") { return "net.kovidgoyal.kitty" }
        if command.contains("warp") { return "dev.warp.Warp-Stable" }
        if command.contains("wezterm") { return "com.github.wez.wezterm" }
        if command.contains("hyper") { return "co.zeit.hyper" }

        return "com.apple.Terminal"
    }

    /// Focus the existing terminal window for a session (non-tmux)
    /// Returns true if successfully focused, false if should fall back to opening new window
    func focusExistingTerminal(sessionPid: Int) async -> Bool {
        let tree = ProcessTreeBuilder.shared.buildTree()
        guard let terminalPid = ProcessTreeBuilder.shared.findTerminalPid(
            forProcess: sessionPid, tree: tree
        ) else {
            Self.logger.info("No terminal PID found for session pid \(sessionPid)")
            return false
        }

        let runningApps = NSWorkspace.shared.runningApplications

        // Try matching terminalPid directly, then walk up parents
        // (e.g. iTermServer PID != main iTerm2 app PID)
        let terminalApp: NSRunningApplication? = findRunningApp(
            startingFrom: terminalPid, tree: tree, runningApps: runningApps
        )
        guard let terminalApp else {
            Self.logger.info("Terminal app not in running applications for pid \(terminalPid)")
            return false
        }

        let appPid = Int(terminalApp.processIdentifier)

        // If yabai is available, focus the specific window
        if await WindowFinder.shared.isYabaiAvailable() {
            let windows = await WindowFinder.shared.getAllWindows()
            let terminalWindows = WindowFinder.shared.findWindows(
                forTerminalPid: appPid, windows: windows
            )
            if let targetWindow = terminalWindows.first {
                _ = await WindowFocuser.shared.focusWindow(id: targetWindow.id)
                Self.logger.debug("Focused terminal window \(targetWindow.id) via yabai")
                return true
            }
        }

        // Without yabai: activate the terminal app (brings to front)
        terminalApp.activate()
        Self.logger.debug("Activated terminal app pid \(appPid)")
        return true
    }

    /// Walk up from a PID to find a matching NSRunningApplication
    /// Handles cases like iTermServer (child) vs iTerm2 (parent app)
    private func findRunningApp(
        startingFrom pid: Int,
        tree: [Int: ProcessInfo],
        runningApps: [NSRunningApplication]
    ) -> NSRunningApplication? {
        var current = pid
        var depth = 0

        while current > 1 && depth < 10 {
            if let app = runningApps.first(where: { $0.processIdentifier == pid_t(current) }) {
                return app
            }
            guard let info = tree[current] else { break }
            current = info.ppid
            depth += 1
        }

        return nil
    }

    /// Fallback: open with Terminal.app using `open` command
    private func openWithTerminalApp(cwd: String) async {
        _ = await ProcessExecutor.shared.runWithResult(
            "/usr/bin/open",
            arguments: ["-a", "Terminal", cwd]
        )
    }
}
