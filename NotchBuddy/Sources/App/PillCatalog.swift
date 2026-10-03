import Foundation

// The original focused-card + four shortcut pills layout, scoped to five sources.
enum PillCatalog {
    static let all: [AgentTask] = [
        .init(id: "claude", name: "Claude Code", color: "#E07950", symbol: "terminal"),
        .init(id: "codex", name: "Codex", color: "#2DD4BF", symbol: "chevron.left.forwardslash.chevron.right"),
        .init(id: "azure", name: "Azure DevOps", color: "#60A5FA", symbol: "arrow.triangle.branch"),
        .init(id: "work", name: "Work items", color: "#A78BFA", symbol: "checklist"),
        .init(id: "inbox", name: "Inbox", color: "#F5A524", symbol: "tray")
    ]
}
