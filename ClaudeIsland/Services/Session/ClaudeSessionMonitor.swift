//
//  ClaudeSessionMonitor.swift
//  ClaudeIsland
//
//  MainActor wrapper around SessionStore for UI binding.
//  Publishes SessionState arrays for SwiftUI observation.
//

import AppKit
import Combine
import Foundation

@MainActor
class ClaudeSessionMonitor: ObservableObject {
    @Published var instances: [SessionState] = []
    @Published var pendingInstances: [SessionState] = []

    private var cancellables = Set<AnyCancellable>()

    init() {
        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.updateFromSessions(sessions)
            }
            .store(in: &cancellables)

        InterruptWatcherManager.shared.delegate = self
    }

    // MARK: - Monitoring Lifecycle

    func startMonitoring() {
        HookSocketServer.shared.start(
            onEvent: { event in
                // Skip Notification(permission_prompt) if session already has a socket-based
                // pending permission (PermissionRequest has richer data — don't overwrite it)
                if event.event == "Notification" && event.notificationType == "permission_prompt"
                    && HookSocketServer.shared.hasPendingPermission(sessionId: event.sessionId) {
                    return
                }

                Task {
                    await SessionStore.shared.process(.hookReceived(event))
                }

                if event.sessionPhase == .processing {
                    Task { @MainActor in
                        InterruptWatcherManager.shared.startWatching(
                            sessionId: event.sessionId,
                            cwd: event.cwd,
                            transcriptPath: event.transcriptPath
                        )
                    }
                }

                if event.status == "ended" {
                    Task { @MainActor in
                        InterruptWatcherManager.shared.stopWatching(sessionId: event.sessionId)
                    }
                }

                if event.event == "Stop" {
                    HookSocketServer.shared.cancelPendingPermissions(sessionId: event.sessionId)
                }

                if event.event == "PostToolUse", let toolUseId = event.toolUseId {
                    HookSocketServer.shared.cancelPendingPermission(toolUseId: toolUseId)
                }
            },
            onPermissionFailure: { sessionId, toolUseId in
                Task {
                    await SessionStore.shared.process(
                        .permissionSocketFailed(sessionId: sessionId, toolUseId: toolUseId)
                    )
                }
            }
        )
    }

    func stopMonitoring() {
        HookSocketServer.shared.stop()
    }

    // MARK: - Permission Handling

    func approvePermission(sessionId: String) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else {
                return
            }

            // Notification-based permission (team mode) — no socket, use TTY keystrokes
            if permission.toolUseId.hasPrefix("notification-") {
                await sendKeystrokeApproval(session: session, keystroke: "1")
            } else {
                HookSocketServer.shared.respondToPermission(
                    toolUseId: permission.toolUseId,
                    decision: "allow"
                )
            }

            await SessionStore.shared.process(
                .permissionApproved(sessionId: sessionId, toolUseId: permission.toolUseId)
            )
        }
    }

    /// Approve a permission request with "always allow" via terminal keystroke
    func approvePermissionAlways(sessionId: String) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else {
                return
            }

            if !permission.toolUseId.hasPrefix("notification-") {
                // Socket-based: close socket without responding → Python exits →
                // Claude Code shows terminal prompt → then send keystroke "2"
                HookSocketServer.shared.cancelPendingPermission(toolUseId: permission.toolUseId)
                try? await Task.sleep(for: .milliseconds(300))
            }

            // Send "2" keystroke to select "Yes, and don't ask again for: ..."
            await sendKeystrokeApproval(session: session, keystroke: "2")

            await SessionStore.shared.process(
                .permissionApproved(sessionId: sessionId, toolUseId: permission.toolUseId)
            )
        }
    }

    func denyPermission(sessionId: String, reason: String?) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else {
                return
            }

            // Notification-based permission (team mode) — no socket, use TTY keystrokes
            if permission.toolUseId.hasPrefix("notification-") {
                await sendKeystrokeApproval(session: session, keystroke: "n")
            } else {
                HookSocketServer.shared.respondToPermission(
                    toolUseId: permission.toolUseId,
                    decision: "deny",
                    reason: reason
                )
            }

            await SessionStore.shared.process(
                .permissionDenied(sessionId: sessionId, toolUseId: permission.toolUseId, reason: reason)
            )
        }
    }

    /// Send a keystroke to a session's terminal (for notification-based permissions)
    private func sendKeystrokeApproval(session: SessionState, keystroke: String) async {
        guard let tty = session.tty else { return }
        let tmuxTarget: TmuxTarget? = session.isInTmux ? await Self.findTmuxTarget(tty: tty) : nil
        _ = await ToolApprovalHandler.shared.sendMessageWithFallback(
            keystroke,
            tty: tty,
            isInTmux: session.isInTmux,
            pid: session.pid,
            tmuxTarget: tmuxTarget
        )
    }

    /// Archive (remove) a session from the instances list
    func archiveSession(sessionId: String) {
        Task {
            await SessionStore.shared.process(.sessionEnded(sessionId: sessionId))
        }
    }

    // MARK: - AskUserQuestion Handling

    /// Answer an AskUserQuestion by allowing the permission and typing the answer into tmux
    func answerQuestion(sessionId: String, answer: String) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else { return }

            // 1. Allow the tool via socket
            HookSocketServer.shared.respondToPermission(
                toolUseId: permission.toolUseId,
                decision: "allow"
            )
            await SessionStore.shared.process(
                .permissionApproved(sessionId: sessionId, toolUseId: permission.toolUseId)
            )

            // 2. After delay, type answer into terminal
            guard let tty = session.tty else { return }
            try? await Task.sleep(for: .milliseconds(500))

            // Resolve tmux target once
            let tmuxTarget: TmuxTarget? = session.isInTmux ? await Self.findTmuxTarget(tty: tty) : nil

            // Split by newline for multi-part answers (e.g., "Other" option: "3\ncustom text")
            let parts = answer.components(separatedBy: "\n")

            for (index, part) in parts.enumerated() {
                if index > 0 {
                    try? await Task.sleep(for: .milliseconds(300))
                }
                _ = await ToolApprovalHandler.shared.sendMessageWithFallback(
                    part,
                    tty: tty,
                    isInTmux: session.isInTmux,
                    pid: session.pid,
                    tmuxTarget: tmuxTarget
                )
            }
        }
    }

    // MARK: - Tmux Helpers

    /// Find the tmux target for a given TTY (shared helper)
    static func findTmuxTarget(tty: String) async -> TmuxTarget? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return nil
        }

        do {
            let output = try await ProcessExecutor.shared.run(
                tmuxPath,
                arguments: ["list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index} #{pane_tty}"]
            )

            let lines = output.components(separatedBy: "\n")
            for line in lines {
                let parts = line.components(separatedBy: " ")
                guard parts.count >= 2 else { continue }

                let target = parts[0]
                let paneTty = parts[1].replacingOccurrences(of: "/dev/", with: "")

                if paneTty == tty {
                    return TmuxTarget(from: target)
                }
            }
        } catch {
            return nil
        }

        return nil
    }

    // MARK: - State Update

    private func updateFromSessions(_ sessions: [SessionState]) {
        instances = sessions
        // Only update pendingInstances when the set of pending IDs actually changes
        // to prevent unnecessary SwiftUI onChange triggers from SubagentStop/PostToolUse etc.
        let newPending = sessions.filter { $0.needsAttention }
        let newIds = Set(newPending.map { $0.stableId })
        let oldIds = Set(pendingInstances.map { $0.stableId })
        if newIds != oldIds {
            pendingInstances = newPending
        }
    }

    // MARK: - History Loading (for UI)

    /// Request history load for a session
    func loadHistory(sessionId: String, cwd: String) {
        Task {
            await SessionStore.shared.process(.loadHistory(sessionId: sessionId, cwd: cwd))
        }
    }
}

// MARK: - Interrupt Watcher Delegate

extension ClaudeSessionMonitor: JSONLInterruptWatcherDelegate {
    nonisolated func didDetectInterrupt(sessionId: String) {
        Task {
            await SessionStore.shared.process(.interruptDetected(sessionId: sessionId))
        }

        Task { @MainActor in
            InterruptWatcherManager.shared.stopWatching(sessionId: sessionId)
        }
    }
}
