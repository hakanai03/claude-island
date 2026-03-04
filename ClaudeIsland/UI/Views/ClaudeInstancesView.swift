//
//  ClaudeInstancesView.swift
//  ClaudeIsland
//
//  Minimal instances list matching Dynamic Island aesthetic
//

import Combine
import SwiftUI

struct ClaudeInstancesView: View {
    @ObservedObject var sessionMonitor: ClaudeSessionMonitor
    @ObservedObject var viewModel: NotchViewModel

    @State private var collapsedGroups: Set<String> = []

    var body: some View {
        if sessionMonitor.instances.isEmpty {
            emptyState
        } else {
            instancesList
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No sessions")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.4))

            Text("Run claude in terminal")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.25))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Instances List

    /// Priority: active (approval/processing/compacting) > waitingForInput > idle
    /// Secondary sort: by last user message date (stable - doesn't change when agent responds)
    /// Note: approval requests stay in their date-based position to avoid layout shift
    private var sortedInstances: [SessionState] {
        sessionMonitor.instances.sorted { a, b in
            let priorityA = phasePriority(a.phase)
            let priorityB = phasePriority(b.phase)
            if priorityA != priorityB {
                return priorityA < priorityB
            }
            // Sort by last user message date (more recent first)
            // Fall back to lastActivity if no user messages yet
            let dateA = a.lastUserMessageDate ?? a.lastActivity
            let dateB = b.lastUserMessageDate ?? b.lastActivity
            return dateA > dateB
        }
    }

    /// Lower number = higher priority
    /// Approval requests share priority with processing to maintain stable ordering
    private func phasePriority(_ phase: SessionPhase) -> Int {
        switch phase {
        case .waitingForApproval, .processing, .compacting: return 0
        case .waitingForInput: return 1
        case .idle, .ended: return 2
        }
    }

    /// Group subagents under their parent (same cwd)
    private var groupedInstances: [(parent: SessionState, children: [SessionState])] {
        let sorted = sortedInstances
        let parents = sorted.filter { !$0.isSubagent }
        let subagents = sorted.filter { $0.isSubagent }

        var result: [(parent: SessionState, children: [SessionState])] = []
        var assignedSubagentIds: Set<String> = []

        for parent in parents {
            let children = subagents.filter { $0.cwd == parent.cwd && !assignedSubagentIds.contains($0.sessionId) }
            for child in children {
                assignedSubagentIds.insert(child.sessionId)
            }
            result.append((parent: parent, children: children))
        }

        // Orphan subagents (no parent found) - show as standalone
        let orphans = subagents.filter { !assignedSubagentIds.contains($0.sessionId) }
        for orphan in orphans {
            result.append((parent: orphan, children: []))
        }

        return result
    }

    private var instancesList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 2) {
                ForEach(groupedInstances, id: \.parent.stableId) { group in
                    // Parent row
                    HStack(spacing: 0) {
                        // Fold/expand toggle for groups with children
                        if !group.children.isEmpty {
                            Button {
                                withAnimation(Animation.spring(response: 0.25, dampingFraction: 0.8)) {
                                    toggleCollapse(group.parent.stableId)
                                }
                            } label: {
                                Image(systemName: collapsedGroups.contains(group.parent.stableId) ? "chevron.right" : "chevron.down")
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundColor(.white.opacity(0.3))
                                    .frame(width: 16, height: 16)
                            }
                            .buttonStyle(.plain)
                        }

                        InstanceRow(
                            session: group.parent,
                            onFocus: { focusSession(group.parent) },
                            onChat: { openChat(group.parent) },
                            onOpenShell: { openShellForSession(group.parent) },
                            onArchive: { archiveSession(group.parent) },
                            onApprove: { approveSession(group.parent) },
                            onReject: { rejectSession(group.parent) }
                        )
                    }
                    .id(group.parent.stableId)

                    // Collapsed badge
                    if !group.children.isEmpty && collapsedGroups.contains(group.parent.stableId) {
                        CollapsedAgentBadge(
                            childCount: group.children.count,
                            hasActive: group.children.contains { $0.phase != .idle && $0.phase != .ended }
                        ) {
                            withAnimation(Animation.spring(response: 0.25, dampingFraction: 0.8)) {
                                toggleCollapse(group.parent.stableId)
                            }
                        }
                    }

                    // Expanded children
                    if !group.children.isEmpty && !collapsedGroups.contains(group.parent.stableId) {
                        ForEach(group.children) { child in
                            InstanceRow(
                                session: child,
                                isSubagentRow: true,
                                onFocus: { focusSession(child) },
                                onChat: { openChat(child) },
                                onOpenShell: { openShellForSession(child) },
                                onArchive: { archiveSession(child) },
                                onApprove: { approveSession(child) },
                                onReject: { rejectSession(child) }
                            )
                            .padding(.leading, 20)
                            .id(child.stableId)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: - Collapse Toggle

    private func toggleCollapse(_ groupId: String) {
        if collapsedGroups.contains(groupId) {
            collapsedGroups.remove(groupId)
        } else {
            collapsedGroups.insert(groupId)
        }
    }

    // MARK: - Actions

    private func focusSession(_ session: SessionState) {
        guard session.isInTmux else { return }

        Task {
            if let pid = session.pid {
                _ = await YabaiController.shared.focusWindow(forClaudePid: pid)
            } else {
                _ = await YabaiController.shared.focusWindow(forWorkingDirectory: session.cwd)
            }
        }
    }

    private func openChat(_ session: SessionState) {
        viewModel.showChat(for: session)
    }

    private func approveSession(_ session: SessionState) {
        sessionMonitor.approvePermission(sessionId: session.sessionId)
    }

    private func rejectSession(_ session: SessionState) {
        sessionMonitor.denyPermission(sessionId: session.sessionId, reason: nil)
    }

    private func archiveSession(_ session: SessionState) {
        sessionMonitor.archiveSession(sessionId: session.sessionId)
    }

    private func openShellForSession(_ session: SessionState) {
        if session.isInTmux {
            focusSession(session)
        } else {
            Task {
                // Try to focus the existing terminal first
                if let pid = session.pid {
                    let focused = await TerminalLauncher.shared.focusExistingTerminal(sessionPid: pid)
                    if focused {
                        viewModel.notchClose()
                        return
                    }
                }
                // Fallback: open a new terminal at the cwd
                await TerminalLauncher.shared.openTerminal(at: session.cwd, sessionPid: session.pid)
            }
        }
        viewModel.notchClose()
    }
}

// MARK: - Instance Row

struct InstanceRow: View {
    let session: SessionState
    var isSubagentRow: Bool = false
    let onFocus: () -> Void
    let onChat: () -> Void
    let onOpenShell: () -> Void
    let onArchive: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void

    @State private var isHovered = false
    @State private var spinnerPhase = 0
    @State private var isYabaiAvailable = false

    private let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)
    private let spinnerSymbols = ["·", "✢", "✳", "∗", "✻", "✽"]
    private let spinnerTimer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    /// Whether we're showing the approval UI
    private var isWaitingForApproval: Bool {
        session.phase.isWaitingForApproval
    }

    /// Whether the pending tool requires interactive input (not just approve/deny)
    private var isInteractiveTool: Bool {
        guard let toolName = session.pendingToolName else { return false }
        return toolName == "AskUserQuestion"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // State indicator on left
            stateIndicator
                .frame(width: 14)

            // Text content
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if isSubagentRow {
                        Image(systemName: "person")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.35))
                    }
                    Text(session.displayTitle)
                        .font(.system(size: isSubagentRow ? 12 : 13, weight: .medium))
                        .foregroundColor(.white.opacity(isSubagentRow ? 0.7 : 1.0))
                        .lineLimit(1)
                }

                // Show tool call when waiting for approval, otherwise last activity
                if isWaitingForApproval, let toolName = session.pendingToolName {
                    // Show tool name in amber + input on same line
                    HStack(spacing: 4) {
                        Text(MCPToolFormatter.formatToolName(toolName))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(TerminalColors.amber.opacity(0.9))
                        if isInteractiveTool {
                            let questionText = AskQuestionInput.parse(from: session.activePermission?.toolInput)?.question
                            Text(questionText ?? "Needs your input")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                                .lineLimit(1)
                        } else if let cmdInput = session.activePermission?.toolInput,
                                  let cmd = cmdInput["command"]?.value as? String {
                            // Bash: show command prominently
                            Text(cmd)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.white.opacity(0.5))
                                .lineLimit(1)
                        } else if let cmdInput = session.activePermission?.toolInput,
                                  let path = cmdInput["file_path"]?.value as? String {
                            // File tools: show file path
                            Text(path)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.white.opacity(0.5))
                                .lineLimit(1)
                        } else if let input = session.pendingToolInput {
                            Text(input)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                                .lineLimit(1)
                        }
                    }
                } else if let role = session.lastMessageRole {
                    switch role {
                    case "tool":
                        // Tool call - show tool name + input
                        HStack(spacing: 4) {
                            if let toolName = session.lastToolName {
                                Text(MCPToolFormatter.formatToolName(toolName))
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                            if let input = session.lastMessage {
                                Text(input)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.4))
                                    .lineLimit(1)
                            }
                        }
                    case "user":
                        // User message - prefix with "You:"
                        HStack(spacing: 4) {
                            Text("You:")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.5))
                            if let msg = session.lastMessage {
                                Text(msg)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.4))
                                    .lineLimit(1)
                            }
                        }
                    default:
                        // Assistant message - just show text
                        if let msg = session.lastMessage {
                            Text(msg)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.4))
                                .lineLimit(1)
                        }
                    }
                } else if let lastMsg = session.lastMessage {
                    Text(lastMsg)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            // Action icons or approval buttons
            if isWaitingForApproval && isInteractiveTool {
                // Interactive tools like AskUserQuestion - show chat + terminal buttons
                HStack(spacing: 8) {
                    IconButton(icon: "bubble.left") {
                        onChat()
                    }

                    // Go to Terminal button (only if yabai available)
                    if isYabaiAvailable {
                        TerminalButton(
                            isEnabled: session.isInTmux,
                            onTap: { onFocus() }
                        )
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else if isWaitingForApproval {
                InlineApprovalButtons(
                    onChat: onChat,
                    onApprove: onApprove,
                    onReject: onReject
                )
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                HStack(spacing: 8) {
                    // Shell icon - open terminal at session cwd
                    IconButton(icon: "terminal") {
                        onOpenShell()
                    }

                    // Focus icon (only for tmux instances with yabai)
                    if session.isInTmux && isYabaiAvailable {
                        IconButton(icon: "eye") {
                            onFocus()
                        }
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            onChat()
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isWaitingForApproval)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
        )
        .onHover { isHovered = $0 }
        .task {
            isYabaiAvailable = await WindowFinder.shared.isYabaiAvailable()
        }
    }

    @ViewBuilder
    private var stateIndicator: some View {
        switch session.phase {
        case .processing, .compacting:
            Text(spinnerSymbols[spinnerPhase % spinnerSymbols.count])
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(claudeOrange)
                .onReceive(spinnerTimer) { _ in
                    spinnerPhase = (spinnerPhase + 1) % spinnerSymbols.count
                }
        case .waitingForApproval:
            Text(spinnerSymbols[spinnerPhase % spinnerSymbols.count])
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(TerminalColors.amber)
                .onReceive(spinnerTimer) { _ in
                    spinnerPhase = (spinnerPhase + 1) % spinnerSymbols.count
                }
        case .waitingForInput:
            Circle()
                .fill(TerminalColors.green)
                .frame(width: 6, height: 6)
        case .idle, .ended:
            Circle()
                .fill(Color.white.opacity(0.2))
                .frame(width: 6, height: 6)
        }
    }

}

// MARK: - Inline Approval Buttons

/// Compact inline approval buttons with staggered animation
struct InlineApprovalButtons: View {
    let onChat: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void

    @State private var showChatButton = false
    @State private var showDenyButton = false
    @State private var showAllowButton = false

    var body: some View {
        HStack(spacing: 6) {
            // Chat button
            IconButton(icon: "bubble.left") {
                onChat()
            }
            .opacity(showChatButton ? 1 : 0)
            .scaleEffect(showChatButton ? 1 : 0.8)

            Button {
                onReject()
            } label: {
                Text("Deny")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showDenyButton ? 1 : 0)
            .scaleEffect(showDenyButton ? 1 : 0.8)

            Button {
                onApprove()
            } label: {
                Text("Allow")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.9))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showAllowButton ? 1 : 0)
            .scaleEffect(showAllowButton ? 1 : 0.8)
        }
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.0)) {
                showChatButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                showDenyButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.1)) {
                showAllowButton = true
            }
        }
    }
}

// MARK: - Icon Button

struct IconButton: View {
    let icon: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isHovered ? .white.opacity(0.8) : .white.opacity(0.4))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Collapsed Agent Badge

struct CollapsedAgentBadge: View {
    let childCount: Int
    let hasActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button {
            onTap()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.2")
                    .font(.system(size: 9))
                Text("+\(childCount) agent\(childCount == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .medium))
                if hasActive {
                    Circle()
                        .fill(Color(red: 0.85, green: 0.47, blue: 0.34))
                        .frame(width: 5, height: 5)
                }
            }
            .foregroundColor(.white.opacity(0.35))
            .padding(.leading, 40)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Compact Terminal Button (inline in description)

struct CompactTerminalButton: View {
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button {
            if isEnabled {
                onTap()
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "terminal")
                    .font(.system(size: 8, weight: .medium))
                Text("Go to Terminal")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(isEnabled ? .white.opacity(0.9) : .white.opacity(0.3))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isEnabled ? Color.white.opacity(0.15) : Color.white.opacity(0.05))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Terminal Button

struct TerminalButton: View {
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button {
            if isEnabled {
                onTap()
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "terminal")
                    .font(.system(size: 9, weight: .medium))
                Text("Terminal")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isEnabled ? .black : .white.opacity(0.4))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isEnabled ? Color.white.opacity(0.95) : Color.white.opacity(0.1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
