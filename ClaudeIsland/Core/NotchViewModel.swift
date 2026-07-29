//
//  NotchViewModel.swift
//  ClaudeIsland
//
//  State management for the dynamic island
//

import AppKit
import Combine
import SwiftUI

enum NotchStatus: Equatable {
    case closed
    case opened
    case popping
}

enum NotchOpenReason {
    case click
    case hover
    case notification
    case boot
    case unknown
}

enum NotchContentType: Equatable {
    case instances
    case menu
    case chat(SessionState)
    case peek(SessionState)

    var id: String {
        switch self {
        case .instances: return "instances"
        case .menu: return "menu"
        case .chat(let session): return "chat-\(session.sessionId)"
        case .peek(let session): return "peek-\(session.sessionId)"
        }
    }
}

@MainActor
class NotchViewModel: ObservableObject {
    // MARK: - Published State

    @Published var status: NotchStatus = .closed
    @Published var openReason: NotchOpenReason = .unknown
    @Published var contentType: NotchContentType = .instances
    @Published var isHovering: Bool = false
    @Published var closedExpansionWidth: CGFloat = 0

    /// Number of sessions currently needing user input (fed by NotchView).
    /// Sizes the peek queue and keeps it open while input is pending.
    @Published var pendingInputCount: Int = 0

    // MARK: - Dependencies

    private let screenSelector = ScreenSelector.shared
    let doneSoundSelector = SoundSelector()
    let permissionSoundSelector = SoundSelector()

    // MARK: - Geometry

    let geometry: NotchGeometry
    let spacing: CGFloat = 12
    let hasPhysicalNotch: Bool

    var deviceNotchRect: CGRect { geometry.deviceNotchRect }
    var screenRect: CGRect { geometry.screenRect }
    var windowHeight: CGFloat { geometry.windowHeight }

    /// Dynamic opened size based on content type
    var openedSize: CGSize {
        switch contentType {
        case .peek:
            // Stacked input queue: grow with pending items, capped
            let extraRows = max(0, pendingInputCount - 1)
            return CGSize(
                width: min(screenRect.width * 0.4, 420),
                height: min(110 + CGFloat(extraRows) * 84, 360)
            )
        case .chat:
            // Large size for chat view
            return CGSize(
                width: min(screenRect.width * 0.5, 600),
                height: 580
            )
        case .menu:
            // Compact size for settings menu
            return CGSize(
                width: min(screenRect.width * 0.4, 480),
                height: 420 + screenSelector.expandedPickerHeight + doneSoundSelector.expandedPickerHeight + permissionSoundSelector.expandedPickerHeight
            )
        case .instances:
            return CGSize(
                width: min(screenRect.width * 0.4, 480),
                height: 320
            )
        }
    }

    // MARK: - Animation

    var animation: Animation {
        .easeOut(duration: 0.25)
    }

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()
    private var hoverTimer: DispatchWorkItem?
    private var peekTimer: DispatchWorkItem?

    // MARK: - Initialization

    init(deviceNotchRect: CGRect, screenRect: CGRect, windowHeight: CGFloat, hasPhysicalNotch: Bool) {
        self.geometry = NotchGeometry(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenRect,
            windowHeight: windowHeight
        )
        self.hasPhysicalNotch = hasPhysicalNotch
        observeSelectors()
    }

    private func observeSelectors() {
        screenSelector.$isPickerExpanded
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        doneSoundSelector.$isPickerExpanded
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        permissionSoundSelector.$isPickerExpanded
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// The chat session we're viewing (persists across close/open)
    private var currentChatSession: SessionState?

    /// Hover state driven by the SwiftUI view (.onHover on the notch content).
    /// Auto-expands after 1 second of hovering while closed.
    func handleHover(_ hovering: Bool) {
        isHovering = hovering

        hoverTimer?.cancel()
        hoverTimer = nil

        guard hovering, status == .closed || status == .popping else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.isHovering else { return }
            self.notchOpen(reason: .hover)
        }
        hoverTimer = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    // MARK: - Actions

    func notchOpen(reason: NotchOpenReason = .unknown) {
        // Cancel peek if we're doing a full open
        peekTimer?.cancel()
        peekTimer = nil

        openReason = reason
        status = .opened

        // Don't restore chat on notification - show instances list instead
        if reason == .notification {
            currentChatSession = nil
            return
        }

        // Restore chat session if we had one open before
        if let chatSession = currentChatSession {
            // Avoid unnecessary updates if already showing this chat
            if case .chat(let current) = contentType, current.sessionId == chatSession.sessionId {
                return
            }
            contentType = .chat(chatSession)
        }
    }

    func notchClose() {
        peekTimer?.cancel()
        peekTimer = nil
        // Save chat session before closing if in chat mode
        if case .chat(let session) = contentType {
            currentChatSession = session
        }
        status = .closed
        contentType = .instances
    }

    func notchPop() {
        guard status == .closed else { return }
        status = .popping
    }

    func notchUnpop() {
        guard status == .popping else { return }
        status = .closed
    }

    func toggleMenu() {
        contentType = contentType == .menu ? .instances : .menu
    }

    func startPeek(for session: SessionState) {
        guard status == .closed || status == .popping else { return }
        peekTimer?.cancel()
        contentType = .peek(session)
        status = .opened
        openReason = .notification

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Stay open while input is still pending — NotchView closes the
            // peek when the queue empties
            if case .peek = self.contentType, self.pendingInputCount == 0 {
                self.notchClose()
            }
        }
        peekTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }

    /// Expand a peek to the full chat view for the same session
    func expandPeekToChat() {
        guard case .peek(let session) = contentType else { return }
        peekTimer?.cancel()
        peekTimer = nil
        contentType = .chat(session)
    }

    func showChat(for session: SessionState) {
        // Avoid unnecessary updates if already showing this chat
        if case .chat(let current) = contentType, current.sessionId == session.sessionId {
            return
        }
        contentType = .chat(session)
    }

    /// Go back to instances list and clear saved chat state
    func exitChat() {
        currentChatSession = nil
        contentType = .instances
    }

    /// Perform boot animation: expand briefly then collapse
    func performBootAnimation() {
        notchOpen(reason: .boot)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, self.openReason == .boot else { return }
            self.notchClose()
        }
    }
}
