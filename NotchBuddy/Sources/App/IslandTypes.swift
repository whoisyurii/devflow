import SwiftUI

// Coucou’s modes and dimensions. Detail screens extend the same island.
enum IslandMode: String { case hidden, compact, expanded }
enum IslandView: String { case overview, detail, answer }
enum BotState: String { case idle, working, thinking, approval, error, finished }
enum PillBadge { case approval, finished, error }
enum CIState { case pending, success, failure, unknown }

struct AgentTask: Identifiable {
    let id: String
    let name: String
    let color: String
    let symbol: String
    var state: BotState = .idle
    var count = 0
    var steps: [String] = []
    var stepIndex: Int { max(0, steps.count - 1) }
    var pillBadge: PillBadge?
}

enum IslandConst {
    static let notchWidth = IslandScreenGeometry.fallbackNotchWidth
    static let notchHeight: CGFloat = 32
    static let expandedWidth: CGFloat = 640
    static let roundedCorner: CGFloat = 14
    static let expandedCorner: CGFloat = 22
}

enum DetailSection: String, CaseIterable {
    case claude, codex, myPRs, toReview, colleague, allPRs, pipelines, mine, today, sprint, due, inbox
    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .myPRs: "My PRs"
        case .toReview: "Reviews"
        case .colleague: "Colleague"
        case .allPRs: "All PRs"
        case .pipelines: "Pipelines"
        case .mine: "Assigned to me"
        case .today: "Created today"
        case .sprint: "Current sprint"
        case .due: "Due today"
        case .inbox: "Inbox"
        }
    }
    var bucket: String {
        switch self {
        case .myPRs, .mine: "mine"
        case .toReview: "review"
        case .colleague: "colleague"
        case .today: "today"
        case .sprint: "sprint"
        case .due: "due"
        default: "all"
        }
    }
}

extension PullRequest {
    var ci: CIState {
        switch checks {
        case "Build failed": .failure
        case "Build running": .pending
        case "Build passed": .success
        default: .unknown
        }
    }
}

func islandSize(mode: IslandMode, view: IslandView,
                nw: CGFloat = IslandConst.notchWidth,
                nh: CGFloat = IslandConst.notchHeight) -> (CGFloat, CGFloat) {
    switch mode {
    case .hidden: (nw, nh)
    case .compact: (nw + 160, nh)
    case .expanded: (IslandConst.expandedWidth, view == .overview ? 160 : 360)
    }
}
