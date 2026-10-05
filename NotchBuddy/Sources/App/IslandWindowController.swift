import AppKit
import SwiftUI

// Coucou’s fixed transparent panel and click-through hit testing. Keeping the
// panel fixed lets the SwiftUI island morph without moving a desktop window.
@MainActor
final class IslandWindowController: NSWindowController {
    private var state: AppState { .shared }
    let fsm = IslandStateMachine()
    private var pointerTimer: Timer?
    private var keyMonitor: Any?
    private var globalMouseMonitor: Any?
    private var trackingMenus: Set<ObjectIdentifier> = []
    private var wasInIsland = false
    private var wasPinned = false
    private var noticeQueue: [Activity] = []

    convenience init() {
        let screen = Self.notchScreen() ?? NSScreen.main!
        let panel = IslandPanel(contentRect: NSRect(x: screen.frame.midX - 360, y: screen.frame.maxY - 420,
                                                   width: 720, height: 420),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.init(window: panel)
        panel.title = "DevFlow Notch"
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: IslandRootView().environmentObject(state))
        host.frame = NSRect(origin: .zero, size: panel.frame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        fsm.isHeldOpen = { [weak self] in
            guard let self else { return false }
            return self.state.isPinned || !self.trackingMenus.isEmpty
        }
        fsm.onTransition = { [weak self] _, to in
            guard let self else { return }
            // Stay available in the notch even when idle, as requested.
            let mode: IslandMode = to == .home || to == .coucou ? .expanded : .compact
            if self.state.mode != mode { self.state.mode = mode }
            if self.state.mode == .expanded { self.window?.makeKey() }
            else { self.window?.resignKey() }
        }
        fsm.reveal()
        // This samples pointer hit testing, not animation frames. SwiftUI's
        // animation transaction follows the display's own rendering cadence.
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollPointer() }
        }
        RunLoop.main.add(pointerTimer!, forMode: .common)
        let mouseDown: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseDown.union(.keyDown)) { [weak self] event in
            guard let self else { return event }
            // Menus own Escape and their item clicks until tracking ends.
            guard self.trackingMenus.isEmpty else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 && event.window == self.window && self.state.mode == .expanded {
                    self.collapse(); return nil
                }
                return event
            }
            if self.state.mode == .expanded {
                self.dismissForOutsideClick(at: NSEvent.mouseLocation, anotherWindow: event.window != self.window)
            } else if event.type == .leftMouseDown && event.window == self.window,
                      self.islandFrameInScreen()?.contains(NSEvent.mouseLocation) == true {
                self.expand(); return nil
            }
            // Dismissing the notch must not consume the destination app's click.
            return event
        }
        // A local monitor cannot see clicks delivered to another application.
        // Global mouse events do not require Accessibility access.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDown) { [weak self] _ in
            self?.dismissForOutsideClick(at: NSEvent.mouseLocation)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: .devflowStateChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateScreenGeometry), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(expand), name: .devflowOpenIsland, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(collapse), name: .islandCollapse, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(announce(_:)), name: .devflowNotice, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(dismissNotice(_:)), name: .devflowDismissNotice, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuDidBeginTracking(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuDidEndTracking(_:)), name: NSMenu.didEndTrackingNotification, object: nil)
        updateScreenGeometry()
        update()
    }

    func stopMonitoring() {
        pointerTimer?.invalidate(); pointerTimer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        keyMonitor = nil; globalMouseMonitor = nil
        trackingMenus.removeAll()
        fsm.cancelTimers()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func update() {
        let snapshot = BridgeModel.shared.snapshot
        if state.snapshot != snapshot { state.snapshot = snapshot }
        let visibleSessions = Set(state.snapshot.sessions.map(\.id))
        if let notice = state.latestNotice, !notice.sessionID.isEmpty, !visibleSessions.contains(notice.sessionID) {
            state.latestNotice = nil
        }
        noticeQueue.removeAll { !$0.sessionID.isEmpty && !visibleSessions.contains($0.sessionID) }
        if !state.tasks.contains(where: { $0.id == state.focusId }) {
            state.setFocus(state.snapshot.settings.agentProvider == "claude" ? "claude" : "codex")
        }
        if [.claude, .codex].contains(state.section), state.singleAgent,
           state.section.rawValue != state.snapshot.settings.agentProvider {
            state.section = state.snapshot.settings.agentProvider == "claude" ? .claude : .codex
        }
        if state.view == .answer, state.selectedSession == nil { state.show(state.section) }
        guard state.snapshot.settings.showNotch else {
            if window?.isVisible == true { window?.orderOut(nil) }
            return
        }
        // Data changes must not repeatedly raise or reposition the panel.
        if window?.isVisible == false { window?.orderFrontRegardless() }
    }
    @objc private func updateScreenGeometry() {
        guard let screen = Self.notchScreen() ?? NSScreen.main else { return }
        let geometry = IslandScreenGeometry(screenWidth: screen.frame.width, safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryLeftWidth: screen.auxiliaryTopLeftArea?.width, auxiliaryRightWidth: screen.auxiliaryTopRightArea?.width,
            menuBarHeight: NSStatusBar.system.thickness)
        if state.notchWidth != geometry.width { state.notchWidth = geometry.width }
        if state.notchHeight != geometry.height { state.notchHeight = geometry.height }
        state.hasNotch = geometry.hasNotch
        let origin = NSPoint(x: screen.frame.midX - 360, y: screen.frame.maxY - 420)
        if window?.frame.origin != origin { window?.setFrameOrigin(origin) }
    }
    private func pollPointer() {
        guard let panel = window as? IslandPanel, panel.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        guard let rect = islandFrameInScreen() else { return }
        let hoverRect = !state.hasNotch && state.mode != .expanded ? rect : rect.insetBy(dx: -6, dy: -6)
        let inside = hoverRect.contains(mouse)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        if trackingMenus.isEmpty {
            if inside && !wasInIsland { fsm.mouseEntered() }
            if !inside && (wasInIsland || wasPinned && !state.isPinned) { fsm.mouseLeft() }
            if !inside && state.mode == .expanded { fsm.ensureCollapseWhenOutside() }
        }
        wasInIsland = inside
        wasPinned = state.isPinned
        if trackingMenus.isEmpty && !inside && !state.isPinned && state.mode != .expanded && !noticeQueue.isEmpty {
            presentNotice(noticeQueue.removeFirst())
        }
    }
    private func islandFrameInScreen() -> CGRect? {
        guard let panel = window as? IslandPanel else { return nil }
        return panel.currentIslandFrame(nw: state.notchWidth, nh: state.notchHeight)
            .offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
    }
    private func dismissForOutsideClick(at point: NSPoint, anotherWindow: Bool = false) {
        guard window?.isVisible == true, state.mode == .expanded, trackingMenus.isEmpty,
              let frame = islandFrameInScreen(), anotherWindow || !frame.contains(point) else { return }
        // Like Escape and the chevron, an outside click explicitly dismisses a pin.
        collapse()
    }
    @objc private func menuDidBeginTracking(_ note: Notification) {
        guard let menu = note.object as? NSMenu else { return }
        trackingMenus.insert(ObjectIdentifier(menu))
        if state.mode == .expanded { fsm.mouseEntered() }
        else { fsm.mouseLeft() } // Cancel a pending hover-open while a menu owns input.
    }
    @objc private func menuDidEndTracking(_ note: Notification) {
        guard let menu = note.object as? NSMenu else { return }
        trackingMenus.remove(ObjectIdentifier(menu))
        // A menu may have moved the pointer outside without a fresh leave edge.
        if trackingMenus.isEmpty { pollPointer() }
    }
    @objc func expand() {
        if state.mode != .expanded { state.mode = .expanded }
        fsm.openedExternally(); state.lastActivity = .now
        window?.orderFrontRegardless(); window?.makeKey()
        // Notices/menu opens get reading time; ordinary pointer exits close promptly.
        if !wasInIsland { fsm.mouseLeft(after: 4) }
    }
    @objc func collapse() {
        noticeQueue.removeAll()
        state.isPinned = false; state.latestNotice = nil
        fsm.collapse()
        if state.mode != .compact { state.mode = .compact }
        window?.resignKey()
    }
    @objc private func announce(_ note: Notification) {
        guard let entry = note.object as? Activity else { return }
        // Do not interrupt someone reading a session or detail list.
        guard trackingMenus.isEmpty, !state.isPinned, !(state.mode == .expanded && wasInIsland) else {
            noticeQueue.append(entry); noticeQueue = Array(noticeQueue.suffix(10)); return
        }
        presentNotice(entry)
    }
    @objc private func dismissNotice(_ note: Notification) {
        guard let id = note.object as? String else { return }
        noticeQueue.removeAll { $0.id == id }
        guard state.latestNotice?.id == id else { return }
        state.latestNotice = nil
        // Keep the current pin and expansion state. Clearing the preview
        // reveals the normal overview without discarding unrelated alerts.
    }
    private func presentNotice(_ entry: Activity) {
        state.latestNotice = entry; state.view = .overview; expand()
    }
    static func notchScreen() -> NSScreen? { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } }
}

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    func currentIslandFrame(nw: CGFloat, nh: CGFloat) -> CGRect {
        let state = AppState.shared
        let (w, h) = islandSize(mode: state.mode, view: state.view, nw: nw, nh: nh)
        return CGRect(x: (frame.width - w) / 2, y: frame.height - h, width: w, height: h)
    }
}
extension Notification.Name {
    static let islandCollapse = Notification.Name("devflow.collapse")
    static let devflowNotice = Notification.Name("devflow.notice")
    static let devflowDismissNotice = Notification.Name("devflow.dismissNotice")
}
