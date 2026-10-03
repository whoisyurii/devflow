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
    var notifications = true
    var showNotch = true
    var importHistory = true
}
struct Answer: Codable, Identifiable, Sendable {
    let id: String
    let text: String
    let date: String
}
struct SessionRecord: Codable, Identifiable, Sendable {
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
    var agentName: String { agent == "codex" ? "Codex" : "Claude Code" }
    var displayTitle: String { title.isEmpty ? project : title }
    var active: Bool { ["working", "thinking", "waiting"].contains(state) }
}
struct Activity: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let body: String
    let date: String
    let read: Bool
    let url: String
    let sessionID: String
}
struct Reviewer: Codable, Sendable { let name: String; let vote: Int }
struct PullRequest: Codable, Identifiable, Sendable {
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
struct Pipeline: Codable, Identifiable, Sendable {
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
struct WorkItem: Codable, Identifiable, Sendable {
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
struct Snapshot: Decodable, Sendable {
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

func displayDate(_ string: String) -> String {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = parser.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    return date?.formatted(date: .abbreviated, time: .shortened) ?? string
}
