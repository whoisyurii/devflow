import Foundation

struct Settings: Codable, Equatable, Sendable {
    var organization = ""
    var project = ""
    var repository = ""
    var myEmail = ""
    var colleagueEmail = ""
    var workItemProject = ""
    var workItemTypes = ""
    var authentication = "interactive"
    var tokenEnvironmentVariable = "ADO_MCP_AUTH_TOKEN"
    var sessionRepositoryPath = ""
    var sessionSubdirectory = "React.BFF"
    var includeRepositoryRoot = true
    var agentProvider = "both"
    var notificationSound = true
    var notifications = true
    var showNotch = true
    var importHistory = true
}
struct Answer: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let text: String
    let date: String
}
struct SessionRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let agent: String
    let externalID: String
    let title: String
    let project: String
    let cwd: String
    let branch: String
    let state: String
    let updatedAt: String
    let answers: [Answer]
    let steps: [Answer]
    let transcriptPath: String
    let source: String
    var worktree: String?
    var worktreePath: String?
    var pending: String?
    var agentName: String { agent == "codex" ? "Codex" : "Claude Code" }
    var displayTitle: String { title.isEmpty ? project : title }
    var active: Bool { ["working", "thinking", "waiting"].contains(state) }
}
struct Activity: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let body: String
    let date: String
    let read: Bool
    let url: String
    let sessionID: String
    var agent: String?
    var sessionTitle: String?
    var worktree: String?
    var branch: String?
    var cwd: String?
    var pending: String?
    var agentName: String { agent == "codex" ? "Codex" : agent == "claude" ? "Claude Code" : "DevFlow" }
}
struct Reviewer: Codable, Equatable, Sendable { let name: String; let vote: Int }
struct PullRequest: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let author: String
    let branch: String
    let target: String
    let draft: Bool
    let review: String
    let reviewRequested: Bool
    let reviewers: [Reviewer]
    let buckets: [String]
    let checks: String
    let url: String
}
struct Pipeline: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let number: String
    let status: String
    let branch: String
    let commit: String
    let requestedBy: String
    let date: String
    let startedAt: String
    let finishedAt: String
    let url: String
}
struct WorkItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let state: String
    let type: String
    let assignedTo: String
    let iteration: String
    let createdAt: String
    let buckets: [String]
    let url: String
}
struct Snapshot: Decodable, Equatable, Sendable {
    var sessions: [SessionRecord] = []
    var activity: [Activity] = []
    var pullRequests: [PullRequest] = []
    var pipelines: [Pipeline] = []
    var workItems: [WorkItem] = []
    var connection = "disconnected"
    var lastSync: String?
    var errors: [String] = []
    var hookStatus = ""
    var settings = Settings()
}

// Shared immutable format styles avoid rebuilding ISO8601 formatters per row.
private let fractionalDateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
private let wholeDateStyle = Date.ISO8601FormatStyle()

func displayDate(_ string: String) -> String {
    let date = (try? fractionalDateStyle.parse(string)) ?? (try? wholeDateStyle.parse(string))
    return date?.formatted(date: .abbreviated, time: .shortened) ?? string
}
