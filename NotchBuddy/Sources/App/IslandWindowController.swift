import AppKit
import SwiftUI

// Coucou’s fixed transparent panel and click-through hit testing. Keeping the
// panel fixed lets the SwiftUI island morph without moving a desktop window.
@MainActor
final class IslandWindowController: NSWindowController {
    private var state: AppState { .shared }
    let fsm = IslandStateMachine()
    private var frameTimer: Timer?
    private var keyMonitor: Any?
    private var wasInIsland = false

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
        fsm.isHeldOpen = { AppState.shared.isPinned }
        fsm.onTransition = { [weak self] _, to in
            guard let self else { return }
            // Stay available in the notch even when idle, as requested.
            self.state.mode = to == .home || to == .coucou ? .expanded : .compact
        }
        fsm.reveal()
        frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollFrame() }
        }
        RunLoop.main.add(frameTimer!, forMode: .common)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown && event.keyCode == 53 { self.collapse(); return nil }
            if event.type == .leftMouseUp && event.window == self.window && self.state.mode != .expanded {
                self.expand(); return nil
            }
            return event
        }
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: .devflowStateChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(expand), name: .devflowOpenIsland, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(collapse), name: .islandCollapse, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(announce(_:)), name: .devflowNotice, object: nil)
        update()
    }

    @objc private func update() {
        state.snapshot = BridgeModel.shared.snapshot
        guard state.snapshot.settings.showNotch else { window?.orderOut(nil); return }
        guard let screen = Self.notchScreen() ?? NSScreen.main else { return }
        let geometry = IslandScreenGeometry(screenWidth: screen.frame.width, safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryLeftWidth: screen.auxiliaryTopLeftArea?.width, auxiliaryRightWidth: screen.auxiliaryTopRightArea?.width,
            menuBarHeight: NSStatusBar.system.thickness)
        state.notchWidth = geometry.width; state.notchHeight = geometry.height; state.hasNotch = geometry.hasNotch
        window?.setFrameOrigin(NSPoint(x: screen.frame.midX - 360, y: screen.frame.maxY - 420))
        window?.orderFrontRegardless()
    }
    private func pollFrame() {
        guard let panel = window as? IslandPanel, panel.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        let local = CGPoint(x: mouse.x - panel.frame.minX, y: mouse.y - panel.frame.minY)
        let rect = panel.currentIslandFrame(nw: state.notchWidth, nh: state.notchHeight)
        let hoverRect = !state.hasNotch && state.mode != .expanded ? rect : rect.insetBy(dx: -6, dy: -6)
        let inside = hoverRect.contains(local)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        if inside && !wasInIsland { fsm.mouseEntered() }
        if !inside && wasInIsland { fsm.mouseLeft() }
        wasInIsland = inside
    }
    @objc func expand() {
        state.mode = .expanded; fsm.openedExternally(); state.lastActivity = .now
        window?.orderFrontRegardless(); window?.makeKey()
        if !wasInIsland { fsm.mouseLeft() }
    }
    @objc func collapse() {
        state.isPinned = false; state.view = .overview; state.latestNotice = nil
        fsm.collapse(); state.mode = .compact; window?.resignKey()
    }
    @objc private func announce(_ note: Notification) {
        guard let entry = note.object as? Activity else { return }
        // Do not interrupt someone reading a session or detail list.
        guard !state.isPinned else { return }
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
}
