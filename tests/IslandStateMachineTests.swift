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
        print("Notch hover and collapse: 11 cases passed")
    }
}
