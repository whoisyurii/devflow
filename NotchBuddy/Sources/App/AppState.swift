import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var mode: IslandMode = .compact
    @Published var view: IslandView = .overview
    @Published var focusId = "codex"
    @Published var section: DetailSection = .codex
    @Published var sessionID: String?
    @Published var isPinned = false
    @Published var snapshot = Snapshot()
    @Published var latestNotice: Activity?
    @Published var notchWidth = IslandConst.notchWidth
    @Published var notchHeight = IslandConst.notchHeight
    var lastActivity = Date.now
    var hasNotch = true

    var tasks: [AgentTask] {
        PillCatalog.all.map { original in
            var task = original
            switch task.id {
            case "claude", "codex":
                let sessions = snapshot.sessions.filter { $0.agent == task.id }
                let current = sessions.first { $0.active } ?? sessions.first
                task.count = sessions.filter(\.active).count
                task.state = current?.state == "waiting" ? .approval : task.count > 0 ? .working : .idle
                task.steps = current?.steps.map(\.text) ?? []
                if sessions.contains(where: { $0.state == "waiting" }) { task.pillBadge = .approval }
            case "azure":
                task.count = snapshot.pullRequests.count
                if snapshot.pullRequests.contains(where: \.reviewRequested) { task.pillBadge = .approval }
                if snapshot.pipelines.contains(where: { $0.status == "running" }) { task.state = .working }
            case "work": task.count = snapshot.workItems.filter { $0.buckets.contains("today") }.count
            default:
                task.count = snapshot.activity.filter { !$0.read }.count
                if task.count > 0 { task.pillBadge = .finished }
            }
            return task
        }
    }
    var focusTask: AgentTask { tasks.first { $0.id == focusId } ?? tasks[0] }
    var selectedSession: SessionRecord? { snapshot.sessions.first { $0.id == sessionID } }

    func setFocus(_ id: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            focusId = id; view = .overview; sessionID = nil; latestNotice = nil
        }
        lastActivity = .now
    }
    func show(_ section: DetailSection) {
        self.section = section; view = .detail; isPinned = true; latestNotice = nil
    }
    func showSession(_ id: String) {
        sessionID = id; view = .answer; isPinned = true; latestNotice = nil
    }
    func showActivity(_ entry: Activity) {
        BridgeModel.shared.perform("markRead", params: ["id": entry.id])
        if !entry.sessionID.isEmpty { showSession(entry.sessionID) }
        else if !entry.url.isEmpty { BridgeModel.shared.openWeb(entry.url) }
    }
}
