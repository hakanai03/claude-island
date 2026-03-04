//
//  NotchView.swift
//  ClaudeIsland
//
//  The main dynamic island SwiftUI view with accurate notch shape
//

import AppKit
import CoreGraphics
import SwiftUI

// Corner radius constants
private let cornerRadiusInsets = (
    opened: (top: CGFloat(19), bottom: CGFloat(24)),
    closed: (top: CGFloat(6), bottom: CGFloat(14))
)

struct NotchView: View {
    @ObservedObject var viewModel: NotchViewModel
    @StateObject private var sessionMonitor = ClaudeSessionMonitor()
    @StateObject private var activityCoordinator = NotchActivityCoordinator.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @State private var previousPendingIds: Set<String> = []
    @State private var previousWaitingForInputIds: Set<String> = []
    @State private var waitingForInputTimestamps: [String: Date] = [:]  // sessionId -> when it entered waitingForInput
    @State private var isVisible: Bool = false
    @State private var isHovering: Bool = false
    @State private var isBouncing: Bool = false

    @Namespace private var activityNamespace

    /// Whether any non-ended sessions exist (for persistent crab display)
    private var hasAnySessions: Bool {
        sessionMonitor.instances.contains { $0.phase != .ended }
    }

    /// Number of active sessions (for stacked crab display)
    private var activeSessionCount: Int {
        let active = sessionMonitor.instances.filter {
            $0.phase != .idle && $0.phase != .ended
        }
        return max(active.count, sessionMonitor.instances.isEmpty ? 0 : 1)
    }

    /// Extra width needed for stacked crab icons
    private var extraCrabWidth: CGFloat {
        let count = min(activeSessionCount, 2)
        guard count > 1 else { return 0 }
        return CGFloat(count - 1) * (14 * 0.35)
    }

    /// Whether any Claude session is currently processing or compacting
    private var isAnyProcessing: Bool {
        sessionMonitor.instances.contains { $0.phase == .processing || $0.phase == .compacting }
    }

    /// Whether any Claude session has a pending permission request
    private var hasPendingPermission: Bool {
        sessionMonitor.instances.contains { $0.phase.isWaitingForApproval }
    }

    /// Whether any Claude session is waiting for user input (done/ready state) within the display window
    private var hasWaitingForInput: Bool {
        let now = Date()
        let displayDuration: TimeInterval = 10  // Show checkmark for 10 seconds

        return sessionMonitor.instances.contains { session in
            guard session.phase == .waitingForInput else { return false }
            // Only show if within the 30-second display window
            if let enteredAt = waitingForInputTimestamps[session.stableId] {
                return now.timeIntervalSince(enteredAt) < displayDuration
            }
            return false
        }
    }

    // MARK: - Sizing

    private var closedNotchSize: CGSize {
        CGSize(
            width: viewModel.deviceNotchRect.width,
            height: viewModel.deviceNotchRect.height
        )
    }

    /// Extra width for expanding activities (like Dynamic Island)
    private var expansionWidth: CGFloat {
        // Permission indicator adds width on left side only
        let permissionIndicatorWidth: CGFloat = hasPendingPermission ? 18 : 0

        // Expand for processing activity
        if activityCoordinator.expandingActivity.show {
            switch activityCoordinator.expandingActivity.type {
            case .claude:
                let baseWidth = 2 * max(0, closedNotchSize.height - 12) + 20
                return baseWidth + permissionIndicatorWidth + extraCrabWidth
            case .none:
                break
            }
        }

        // Expand for pending permissions (left indicator) or waiting for input (checkmark on right)
        if hasPendingPermission {
            return 2 * max(0, closedNotchSize.height - 12) + 20 + permissionIndicatorWidth + extraCrabWidth
        }

        // Waiting for input just shows checkmark on right, no extra left indicator
        if hasWaitingForInput {
            return 2 * max(0, closedNotchSize.height - 12) + 20 + extraCrabWidth
        }

        // Sessions exist but idle: crab on left, idle indicator on right
        if hasAnySessions {
            return 2 * max(0, closedNotchSize.height - 12) + 20 + extraCrabWidth
        }

        return 0
    }

    private var notchSize: CGSize {
        switch viewModel.status {
        case .closed, .popping:
            return closedNotchSize
        case .opened:
            return viewModel.openedSize
        }
    }

    /// Width of the closed content (notch + any expansion)
    private var closedContentWidth: CGFloat {
        closedNotchSize.width + expansionWidth
    }

    // MARK: - Corner Radii

    private var topCornerRadius: CGFloat {
        viewModel.status == .opened
            ? cornerRadiusInsets.opened.top
            : cornerRadiusInsets.closed.top
    }

    private var bottomCornerRadius: CGFloat {
        viewModel.status == .opened
            ? cornerRadiusInsets.opened.bottom
            : cornerRadiusInsets.closed.bottom
    }

    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius
        )
    }

    // Animation springs
    private let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
    private let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            // Outer container does NOT receive hits - only the notch content does
            VStack(spacing: 0) {
                notchLayout
                    .frame(
                        maxWidth: viewModel.status == .opened ? notchSize.width : nil,
                        alignment: .top
                    )
                    .padding(
                        .horizontal,
                        viewModel.status == .opened
                            ? cornerRadiusInsets.opened.top
                            : cornerRadiusInsets.closed.bottom
                    )
                    .padding([.horizontal, .bottom], viewModel.status == .opened ? 12 : 0)
                    .background(.black)
                    .clipShape(currentNotchShape)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .shadow(
                        color: (viewModel.status == .opened || isHovering) ? .black.opacity(0.7) : .clear,
                        radius: 6
                    )
                    .frame(
                        maxWidth: viewModel.status == .opened ? notchSize.width : nil,
                        maxHeight: viewModel.status == .opened ? notchSize.height : nil,
                        alignment: .top
                    )
                    .animation(viewModel.status == .opened ? openAnimation : closeAnimation, value: viewModel.status)
                    .animation(openAnimation, value: notchSize) // Animate container size changes between content types
                    .animation(.smooth, value: activityCoordinator.expandingActivity)
                    .animation(.smooth, value: hasPendingPermission)
                    .animation(.smooth, value: hasWaitingForInput)
                    .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isBouncing)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                            isHovering = hovering
                        }
                    }
                    .onTapGesture {
                        if viewModel.status != .opened {
                            viewModel.notchOpen(reason: .click)
                        }
                    }
            }
        }
        .opacity(isVisible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .onAppear {
            sessionMonitor.startMonitoring()
            // On non-notched devices, keep visible so users have a target to interact with
            if !viewModel.hasPhysicalNotch {
                isVisible = true
            }
        }
        .onChange(of: viewModel.status) { oldStatus, newStatus in
            handleStatusChange(from: oldStatus, to: newStatus)
        }
        .onChange(of: sessionMonitor.pendingInstances) { _, sessions in
            handlePendingSessionsChange(sessions)
        }
        .onChange(of: sessionMonitor.instances) { _, instances in
            handleProcessingChange()
            handleWaitingForInputChange(instances)
        }
        .onChange(of: expansionWidth) { _, newWidth in
            viewModel.closedExpansionWidth = newWidth
        }
    }

    // MARK: - Notch Layout

    private var isProcessing: Bool {
        activityCoordinator.expandingActivity.show && activityCoordinator.expandingActivity.type == .claude
    }

    /// Whether to show the expanded closed state (processing, pending permission, or waiting for input)
    private var showClosedActivity: Bool {
        isProcessing || hasPendingPermission || hasWaitingForInput
    }

    @ViewBuilder
    private var notchLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row - always present, contains crab and spinner that persist across states
            headerRow
                .frame(height: max(24, closedNotchSize.height))

            // Main content only when opened
            if viewModel.status == .opened {
                contentView
                    .frame(width: notchSize.width - 24) // Fixed width to prevent reflow
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.8, anchor: .top)
                                .combined(with: .opacity)
                                .animation(.smooth(duration: 0.35)),
                            removal: .opacity.animation(.easeOut(duration: 0.15))
                        )
                    )
            }
        }
    }

    // MARK: - Header Row (persists across states)

    /// Whether to show the crab icon in the closed header (sessions exist OR activity showing)
    private var showCrab: Bool {
        showClosedActivity || (viewModel.status != .opened && hasAnySessions)
    }

    @ViewBuilder
    private var headerRow: some View {
        HStack(spacing: 0) {
            // Left side - crab (persistent when sessions exist) + optional permission indicator
            if showCrab {
                HStack(spacing: 4) {
                    StackedCrabIcons(count: activeSessionCount, size: 14, animateLegs: isProcessing)
                        .matchedGeometryEffect(id: "crab", in: activityNamespace, isSource: showCrab)

                    // Permission indicator only (amber) - waiting for input shows checkmark on right
                    if hasPendingPermission {
                        PermissionIndicatorIcon(size: 14, color: Color(red: 0.85, green: 0.47, blue: 0.34))
                            .matchedGeometryEffect(id: "status-indicator", in: activityNamespace, isSource: showClosedActivity)
                    }
                }
                .frame(width: viewModel.status == .opened ? nil : sideWidth + (hasPendingPermission ? 18 : 0))
                .padding(.leading, viewModel.status == .opened ? 8 : 0)
            }

            // Center content
            if viewModel.status == .opened {
                // Opened: show header content
                openedHeaderContent
            } else if !showCrab {
                // Closed without any sessions: empty space
                Rectangle()
                    .fill(.clear)
                    .frame(width: closedNotchSize.width - 20)
            } else {
                // Closed with crab (with or without activity): black spacer
                Rectangle()
                    .fill(.black)
                    .frame(width: closedNotchSize.width - cornerRadiusInsets.closed.top + (isBouncing ? 16 : 0))
            }

            // Right side - spinner when processing/pending, checkmark when waiting, idle icon otherwise
            if showCrab {
                if isProcessing || hasPendingPermission {
                    ProcessingSpinner()
                        .matchedGeometryEffect(id: "spinner", in: activityNamespace, isSource: showClosedActivity)
                        .frame(width: viewModel.status == .opened ? 20 : sideWidth)
                } else if hasWaitingForInput {
                    // Checkmark for waiting-for-input on the right side
                    ReadyForInputIndicatorIcon(size: 14, color: TerminalColors.green)
                        .matchedGeometryEffect(id: "spinner", in: activityNamespace, isSource: showClosedActivity)
                        .frame(width: viewModel.status == .opened ? 20 : sideWidth)
                } else {
                    // Idle dot - Claude color
                    Circle()
                        .fill(TerminalColors.prompt.opacity(0.6))
                        .frame(width: 6, height: 6)
                        .matchedGeometryEffect(id: "spinner", in: activityNamespace, isSource: showCrab)
                        .frame(width: viewModel.status == .opened ? 20 : sideWidth)
                }
            }
        }
        .frame(height: closedNotchSize.height)
    }

    private var sideWidth: CGFloat {
        max(0, closedNotchSize.height - 12) + 10
    }

    // MARK: - Opened Header Content

    @ViewBuilder
    private var openedHeaderContent: some View {
        HStack(spacing: 12) {
            // Show static crab only if not showing it in headerRow
            // (headerRow handles crab when showCrab is true)
            if !showCrab {
                StackedCrabIcons(count: activeSessionCount, size: 14)
                    .matchedGeometryEffect(id: "crab", in: activityNamespace, isSource: !showCrab)
                    .padding(.leading, 8)
            }

            Spacer()

            // Menu toggle
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    viewModel.toggleMenu()
                    if viewModel.contentType == .menu {
                        updateManager.markUpdateSeen()
                    }
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: viewModel.contentType == .menu ? "xmark" : "line.3.horizontal")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())

                    // Green dot for unseen update
                    if updateManager.hasUnseenUpdate && viewModel.contentType != .menu {
                        Circle()
                            .fill(TerminalColors.green)
                            .frame(width: 6, height: 6)
                            .offset(x: -2, y: 2)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Content View (Opened State)

    @ViewBuilder
    private var contentView: some View {
        Group {
            switch viewModel.contentType {
            case .instances:
                ClaudeInstancesView(
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel
                )
            case .menu:
                NotchMenuView(viewModel: viewModel)
            case .chat(let session):
                ChatView(
                    sessionId: session.sessionId,
                    initialSession: session,
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel
                )
            case .peek(let session):
                peekContentView(session: session)
            }
        }
        .frame(width: notchSize.width - 24) // Fixed width to prevent text reflow
        // Removed .id() - was causing view recreation and performance issues
    }

    // MARK: - Event Handlers

    private func handleProcessingChange() {
        if isAnyProcessing || hasPendingPermission {
            // Show claude activity when processing or waiting for permission
            activityCoordinator.showActivity(type: .claude)
            isVisible = true
        } else if hasWaitingForInput {
            // Keep visible for waiting-for-input but hide the processing spinner
            activityCoordinator.hideActivity()
            isVisible = true
        } else {
            // Hide activity when done
            activityCoordinator.hideActivity()

            // Delay hiding the notch until animation completes
            // Don't hide on non-notched devices - users need a visible target
            // Don't hide while sessions exist - keep crab visible
            if viewModel.status == .closed && viewModel.hasPhysicalNotch && !hasAnySessions {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if !isAnyProcessing && !hasPendingPermission && !hasWaitingForInput && !hasAnySessions && viewModel.status == .closed {
                        isVisible = false
                    }
                }
            }
        }
    }

    private func handleStatusChange(from oldStatus: NotchStatus, to newStatus: NotchStatus) {
        switch newStatus {
        case .opened, .popping:
            isVisible = true
            // Clear waiting-for-input timestamps only when manually opened (user acknowledged)
            if viewModel.openReason == .click || viewModel.openReason == .hover {
                waitingForInputTimestamps.removeAll()
            }
            // Auto-navigate to first pending permission session's chat
            if let firstPending = sessionMonitor.pendingInstances.first {
                viewModel.showChat(for: firstPending)
            }
        case .closed:
            // Don't hide on non-notched devices - users need a visible target
            guard viewModel.hasPhysicalNotch else { return }
            // Don't hide while sessions exist - keep crab visible
            guard !hasAnySessions else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if viewModel.status == .closed && !isAnyProcessing && !hasPendingPermission && !hasWaitingForInput && !hasAnySessions && !activityCoordinator.expandingActivity.show {
                    isVisible = false
                }
            }
        }
    }

    private func handlePendingSessionsChange(_ sessions: [SessionState]) {
        let currentIds = Set(sessions.map { $0.stableId })
        let newPendingIds = currentIds.subtracting(previousPendingIds)

        // Only act on sessions with actual permission requests (not waitingForInput etc.)
        let ignoredTools: Set<String> = ["EnterPlanMode", "ExitPlanMode"]
        let actionablePending = sessions.filter { session in
            guard newPendingIds.contains(session.stableId) else { return false }
            // Must have an active permission — skip waitingForInput and other non-permission states
            guard let permission = session.activePermission else { return false }
            return !ignoredTools.contains(permission.toolName)
        }

        if !actionablePending.isEmpty {
            let firstNewPending = actionablePending.first
            let terminalVisible = TerminalVisibilityDetector.isTerminalVisibleOnCurrentSpace()

            if viewModel.status == .closed && !terminalVisible {
                viewModel.notchOpen(reason: .notification)
                // handleStatusChange will auto-navigate via pendingInstances
            } else if viewModel.status == .closed && terminalVisible, let pending = firstNewPending {
                // Terminal visible — show compact peek instead of full open
                viewModel.startPeek(for: pending)
            } else if viewModel.status == .opened, let pending = firstNewPending {
                // Already open — navigate to the new pending session
                viewModel.showChat(for: pending)
            }

            // Play permission sound for newly pending sessions
            let newlyPendingSessions = sessions.filter { newPendingIds.contains($0.stableId) }
            if let soundName = AppSettings.permissionSound.soundName {
                Task {
                    let shouldPlay = await shouldPlayNotificationSound(for: newlyPendingSessions)
                    if shouldPlay {
                        await MainActor.run {
                            NSSound(named: soundName)?.play()
                        }
                    }
                }
            }
        }

        previousPendingIds = currentIds
    }

    private func handleWaitingForInputChange(_ instances: [SessionState]) {
        // Get sessions that are now waiting for input
        let waitingForInputSessions = instances.filter { $0.phase == .waitingForInput }
        let currentIds = Set(waitingForInputSessions.map { $0.stableId })
        let newWaitingIds = currentIds.subtracting(previousWaitingForInputIds)

        // Track timestamps for newly waiting sessions
        let now = Date()
        for session in waitingForInputSessions where newWaitingIds.contains(session.stableId) {
            waitingForInputTimestamps[session.stableId] = now
        }

        // Clean up timestamps for sessions no longer waiting
        let staleIds = Set(waitingForInputTimestamps.keys).subtracting(currentIds)
        for staleId in staleIds {
            waitingForInputTimestamps.removeValue(forKey: staleId)
        }

        // Bounce the notch when a session newly enters waitingForInput state
        if !newWaitingIds.isEmpty {
            let capturedNewWaitingIds = newWaitingIds

            // Debounce: wait 1.5s and verify sessions are still waiting
            // (SubagentStop/PostToolUse can cause transient waitingForInput)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                let stillWaiting = sessionMonitor.instances.filter {
                    $0.phase == .waitingForInput && capturedNewWaitingIds.contains($0.stableId)
                }
                guard !stillWaiting.isEmpty else { return }

                // Play notification sound if the session is not actively focused
                if let soundName = AppSettings.notificationSound.soundName {
                    Task {
                        let shouldPlaySound = await shouldPlayNotificationSound(for: stillWaiting)
                        if shouldPlaySound {
                            await MainActor.run {
                                NSSound(named: soundName)?.play()
                            }
                        }
                    }
                }

                // Trigger bounce animation to get user's attention
                isBouncing = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    isBouncing = false
                }
            }

            // Schedule hiding the checkmark after 10 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [self] in
                // Trigger a UI update to re-evaluate hasWaitingForInput
                handleProcessingChange()
            }
        }

        previousWaitingForInputIds = currentIds
    }

    // MARK: - Peek Content View

    @ViewBuilder
    private func peekContentView(session: SessionState) -> some View {
        let toolName: String = {
            guard let lastTool = ChatHistoryManager.shared.history(for: session.sessionId)
                .compactMap({ item -> ToolCallItem? in
                    if case .toolCall(let tool) = item.type { return tool }
                    return nil
                })
                .last(where: { $0.status == .waitingForApproval })
            else { return "Permission required" }
            let name = MCPToolFormatter.formatToolName(lastTool.name)
            let preview = lastTool.inputPreview
            return preview.isEmpty ? name : "\(name)(\(preview))"
        }()

        let hasAlways = session.activePermission?.hasAlwaysOption ?? false

        HStack(spacing: 8) {
            // Tool name (tap to expand to full chat)
            Button {
                viewModel.showChat(for: session)
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                    Text(toolName)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)

            // Allow button
            Button {
                sessionMonitor.approvePermission(sessionId: session.sessionId)
                viewModel.notchClose()
            } label: {
                Text("Allow")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.9))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            // Always button (only when available)
            if hasAlways {
                Button {
                    sessionMonitor.approvePermissionAlways(sessionId: session.sessionId)
                    viewModel.notchClose()
                } label: {
                    Text("Always")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.2))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    /// Determine if notification sound should play for the given sessions
    /// Returns true if ANY session is not actively focused
    private func shouldPlayNotificationSound(for sessions: [SessionState]) async -> Bool {
        for session in sessions {
            guard let pid = session.pid else {
                // No PID means we can't check focus, assume not focused
                return true
            }

            let isFocused = await TerminalVisibilityDetector.isSessionFocused(sessionPid: pid)
            if !isFocused {
                return true
            }
        }

        return false
    }
}
