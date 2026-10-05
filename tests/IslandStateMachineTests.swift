import Foundation

@main
enum IslandStateMachineTests {
    @MainActor static func main() async throws {
        let fsm = IslandStateMachine()
        fsm.hoverOpenDelay = 0.015
        fsm.homeToPetitDelay = 0.02
        fsm.petitToHiddenDelay = 10
        func wait() async throws { try await Task.sleep(for: .milliseconds(70)) }

        fsm.mouseEntered()
        precondition(fsm.state == .petit)
        try await wait()
        precondition(fsm.state == .home, "Hover should expand without a click")
        fsm.mouseLeft()
        try await wait()
        precondition(fsm.state == .petit, "Pointer exit should collapse promptly")

        fsm.mouseEntered(); fsm.mouseLeft()
        try await wait()
        precondition(fsm.state == .petit, "Passing across the notch must not open it later")
        fsm.mouseEntered()
        try await wait()
        fsm.mouseLeft(); fsm.mouseEntered()
        try await wait()
        precondition(fsm.state == .home, "Re-entry cancels pending collapse")

        fsm.collapse()
        try await wait()
        precondition(fsm.state == .petit, "Escape/close must not reopen under the stationary pointer")
        fsm.mouseLeft(); fsm.mouseEntered()
        try await wait()
        precondition(fsm.state == .home, "New hover works after an explicit close")

        var pinned = true
        fsm.isHeldOpen = { pinned }
        fsm.mouseLeft()
        try await wait()
        precondition(fsm.state == .home, "Manual pin keeps the island open")
        pinned = false; fsm.mouseLeft()
        try await wait()
        precondition(fsm.state == .petit)

        fsm.mouseEntered(); fsm.collapse()
        try await wait()
        precondition(fsm.state == .petit, "Close cancels a pending hover open")
        fsm.openedExternally(); fsm.mouseLeft(after: 0.2)
        try await wait()
        precondition(fsm.state == .home, "External notices retain their longer reading time")
        fsm.cancelTimers()
        fsm.collapse(); fsm.mouseEntered(); fsm.click()
        precondition(fsm.state == .home, "Click opens immediately while the hover delay is pending")
        fsm.cancelTimers()

        // Polling repairs a missed exit, but repeated polls must not postpone it.
        fsm.openedExternally()
        for _ in 0..<6 {
            fsm.ensureCollapseWhenOutside()
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(fsm.state == .petit, "Repeated outside checks must still collapse after a missed exit")

        fsm.openedExternally(); fsm.mouseLeft(after: 0.2)
        for _ in 0..<6 {
            fsm.ensureCollapseWhenOutside()
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(fsm.state == .home, "Outside recovery must preserve a notice's existing reading timer")
        fsm.cancelTimers()

        pinned = true
        fsm.ensureCollapseWhenOutside()
        try await wait()
        precondition(fsm.state == .home, "A pin or open menu holds the island during outside polling")
        pinned = false
        fsm.ensureCollapseWhenOutside()
        try await wait()
        precondition(fsm.state == .petit, "Releasing the hold while already outside restores dismissal")

        fsm.openedExternally(); pinned = true; fsm.collapse()
        precondition(fsm.state == .petit, "Explicit dismissal works even while pinned")

        pinned = false; fsm.openedExternally(); fsm.mouseLeft()
        pinned = true
        try await wait()
        precondition(fsm.state == .home, "A newly acquired hold prevents an already scheduled collapse")
        pinned = false; fsm.ensureCollapseWhenOutside()
        try await wait()
        precondition(fsm.state == .petit, "An expired held timer cannot block later outside recovery")
        fsm.cancelTimers()
        print("Notch hover and collapse: 19 cases passed")
    }
}
