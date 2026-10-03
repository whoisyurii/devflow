import SwiftUI

// Coucou’s original overview: 322-point focus card + four switching pills.
struct OverviewView: View {
    @ObservedObject var state: AppState
    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .topLeading) {
                CardBackground(wash: state.latestNotice == nil ? nil : .green)
                PillSymbol(task: state.focusTask)
                    .frame(width: 58, height: 58).position(x: 58, y: 49)
                if let notice = state.latestNotice {
                    Button { state.showActivity(notice) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(notice.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Text(notice.body).font(.system(size: 11)).foregroundColor(Color(hex: "#9398A1")).lineLimit(3)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 108).padding(.trailing, 12).padding(.top, 12)
                    }.buttonStyle(.plain)
                } else {
                    IntegrationCardView(state: state)
                }
            }.frame(width: 322)
            CardBackground(wash: nil) { AgentPillsView(state: state) }
        }
    }
}

struct IntegrationCardView: View {
    @ObservedObject var state: AppState
    private var task: AgentTask { state.focusTask }
    private var sessions: [SessionRecord] { state.snapshot.sessions.filter { $0.agent == task.id } }
    var body: some View {
        if task.id == "azure" {
            AzurePulseCardView(state: state)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Circle().fill(Color(hex: task.color)).frame(width: 7, height: 7)
                    Text(task.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { openDetail() } label: {
                        Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .medium))
                            .foregroundColor(Color(hex: "#5F646D")).frame(width: 16, height: 16)
                            .background(Color.white.opacity(0.07)).clipShape(Circle())
                    }.buttonStyle(.plain).accessibilityLabel("Open \(task.name)")
                }
                .padding(.top, 6).padding(.leading, 108).padding(.trailing, 12)
                VStack(alignment: .leading, spacing: 4) {
                    if task.id == "work" {
                        stat("person", "Assigned to me", count: count("mine"), section: .mine)
                        stat("sun.max", "New today", count: count("today"), section: .today)
                        stat("calendar", "This sprint", count: count("sprint"), section: .sprint)
                    } else if task.id == "inbox" {
                        Button { state.show(.inbox) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(task.count) unread updates").font(.system(size: 12, weight: .medium))
                                Text(state.snapshot.activity.first?.title ?? "Session and Azure updates appear here")
                                    .font(.system(size: 11)).foregroundColor(Color(hex: "#6B7079")).lineLimit(2)
                            }
                        }.buttonStyle(.plain)
                    } else {
                        Button { openDetail() } label: {
                            HStack(spacing: 4) {
                                Text("\(task.count) active").foregroundColor(Color(hex: task.color))
                                Text("· \(sessions.count) sessions").foregroundColor(Color(hex: "#6B7079"))
                            }.font(.system(size: 11))
                        }.buttonStyle(.plain)
                        if task.state == .working && !task.steps.isEmpty {
                            TickerView(task: task).id(sessions.first { $0.active }?.id ?? sessions.first?.id)
                                .frame(height: 44).offset(x: 6, y: -2)
                        } else {
                            Text(sessions.first?.displayTitle ?? "Ready for local sessions")
                                .font(.system(size: 11)).foregroundColor(Color(hex: "#9398A1")).lineLimit(2)
                        }
                    }
                }.padding(.top, 6).padding(.leading, 108).padding(.trailing, 12)
            }.frame(maxWidth: .infinity, alignment: .topLeading).padding(.top, 4).clipped()
        }
    }
    private func count(_ bucket: String) -> Int { state.snapshot.workItems.filter { $0.buckets.contains(bucket) }.count }
    private func stat(_ icon: String, _ label: String, count: Int, section: DetailSection) -> some View {
        AzureStatRow(icon: icon, iconColor: task.color, label: label, value: "\(count)") { state.show(section) }
    }
    private func openDetail() {
        switch task.id {
        case "claude": state.show(.claude)
        case "codex": state.show(.codex)
        case "work": state.show(.mine)
        default: state.show(.inbox)
        }
    }
}

// Adapted from GitHubPulseCardView: same title, inset, statistic rows and actions.
struct AzurePulseCardView: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: "#60A5FA")).frame(width: 7, height: 7)
                Text("Azure DevOps").font(.system(size: 12, weight: .semibold))
                Text(state.snapshot.connection == "connected" ? "" : state.snapshot.connection)
                    .font(.system(size: 10)).foregroundColor(Color(hex: "#8E939C")).lineLimit(1)
            }.padding(.top, 6).padding(.leading, 108).padding(.trailing, 12)
            VStack(alignment: .leading, spacing: 4) {
                AzureStatRow(icon: "arrow.triangle.pull", iconColor: "#60A5FA", label: "My PRs",
                             value: "\(state.snapshot.pullRequests.filter { $0.buckets.contains("mine") }.count)") { state.show(.myPRs) }
                AzureStatRow(icon: "eye", iconColor: "#8AB4F8", label: "Reviews",
                             value: "\(state.snapshot.pullRequests.filter(\.reviewRequested).count)") { state.show(.toReview) }
                let active = state.snapshot.pipelines.filter { ["running", "queued"].contains($0.status) }.count
                AzureStatRow(icon: "checkmark.seal.fill", iconColor: active > 0 ? "#F5A524" : "#6B7079",
                             label: "Pipelines", value: active > 0 ? "\(active) active" : "\(state.snapshot.pipelines.count)") { state.show(.pipelines) }
            }.padding(.top, 6).padding(.leading, 108).padding(.trailing, 12)
        }.frame(maxWidth: .infinity, alignment: .topLeading).padding(.top, 4).clipped()
    }
}

// GitHubDetailView’s back header, scrolling rows and muted hierarchy, expanded
// only when reading a list. PR rows themselves are the original GitHub row component.
struct WorkflowDetailView: View {
    @ObservedObject var state: AppState
    @State private var activeOnly = true
    @State private var search = ""
    private var sessionSection: Bool { [.claude, .codex].contains(state.section) }
    private var azureSection: Bool { [.myPRs, .toReview, .colleague, .allPRs, .pipelines].contains(state.section) }
    private var workSection: Bool { [.mine, .today, .sprint, .due].contains(state.section) }
    private var filters: [DetailSection] {
        if sessionSection { return [.claude, .codex] }
        if azureSection { return [.myPRs, .toReview, .colleague, .allPRs, .pipelines] }
        if workSection { return [.mine, .today, .sprint, .due] }
        return []
    }
    var body: some View {
        CardBackground(wash: nil) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    backButton("\(state.section.title)") { state.view = .overview }
                    Spacer()
                    if state.section == .pipelines {
                        Toggle("Active only", isOn: $activeOnly).toggleStyle(.checkbox).font(.system(size: 10))
                    } else if sessionSection {
                        TextField("Find a session…", text: $search).textFieldStyle(.plain)
                            .font(.system(size: 11)).frame(width: 180)
                    } else if state.section == .inbox {
                        Button("Mark all read") { BridgeModel.shared.perform("markRead") }
                            .buttonStyle(.plain).font(.system(size: 10)).foregroundColor(Color(hex: "#8E939C"))
                    }
                }
                if !filters.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(filters, id: \.rawValue) { section in
                            Button { state.section = section; search = "" } label: {
                                Text(section.title).font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 9).padding(.vertical, 4)
                                    .background(state.section == section ? Color(hex: "#2B2E34") : Color(hex: "#0E0F11"), in: Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) { rows }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if azureSection || workSection {
                    connectionFooter
                } else if sessionSection {
                    Text("Local sessions · hooks provide live status · history imports recent answers")
                        .font(.system(size: 9)).foregroundColor(Color(hex: "#6B7079"))
                }
            }.padding(14)
        }
    }

    @ViewBuilder private var rows: some View {
        if sessionSection {
            let sessions = state.snapshot.sessions.filter {
                $0.agent == state.section.rawValue && (search.isEmpty || ($0.displayTitle + $0.cwd).localizedCaseInsensitiveContains(search))
            }
            if sessions.isEmpty { empty("No local sessions found.") }
            ForEach(sessions) { session in
                Button { state.showSession(session.id) } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(statusColor(session.state)).frame(width: 5, height: 5).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.displayTitle).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text("\(session.project) · \(session.state) · \(session.answers.count) answers")
                                .font(.system(size: 10)).foregroundColor(Color(hex: "#8E939C"))
                        }
                        Spacer()
                        Text(displayDate(session.updatedAt)).font(.system(size: 9)).foregroundColor(Color(hex: "#6B7079"))
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        } else if state.section == .pipelines {
            let builds = state.snapshot.pipelines.filter { !activeOnly || ["running", "queued"].contains($0.status) }
            if builds.isEmpty { empty(activeOnly ? "No running or queued pipelines." : "No recent pipelines.") }
            ForEach(builds) { build in
                Button { BridgeModel.shared.openWeb(build.url) } label: {
                    HStack(spacing: 5) {
                        Circle().fill(statusColor(build.status)).frame(width: 5, height: 5)
                        Text("\(build.name) #\(build.number)").font(.system(size: 11)).lineLimit(1)
                        Text(build.branch).font(.system(size: 10)).foregroundColor(Color(hex: "#9398A1")).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(build.status).font(.system(size: 10)).foregroundColor(statusColor(build.status))
                    }.frame(height: 22)
                }.buttonStyle(.plain).help("\(build.requestedBy) · \(displayDate(build.date)) · Open run in Azure")
            }
        } else if azureSection {
            let prs = state.snapshot.pullRequests.filter { state.section == .allPRs || $0.buckets.contains(state.section.bucket) }
            if state.section == .colleague && state.snapshot.settings.colleagueEmail.isEmpty {
                empty("Set your colleague’s Azure email in Settings to use this filter.")
            } else if prs.isEmpty { empty("No open pull requests in this view.") }
            ForEach(prs) { pr in
                VStack(alignment: .leading, spacing: 1) {
                    AzurePRRowView(pr: pr, showCI: true)
                    Text("\(pr.author) · \(pr.review) · \(pr.checks) · \(pr.branch) → \(pr.target)")
                        .font(.system(size: 9)).foregroundColor(Color(hex: "#6B7079")).lineLimit(1).padding(.leading, 10)
                }.help(pr.reviewers.map { "\($0.name): \(reviewVote($0.vote))" }.joined(separator: "\n"))
            }
        } else if workSection {
            let items = state.snapshot.workItems.filter { $0.buckets.contains(state.section.bucket) }
            if state.section == .sprint && state.snapshot.settings.team.isEmpty { empty("Set your Azure team in Settings to load the current sprint.") }
            else if state.section == .due && state.snapshot.settings.dueDateField.isEmpty { empty("Set your process’s due-date field in Settings. Azure has no universal due-date field.") }
            else if items.isEmpty { empty("No work items in this view.") }
            ForEach(items) { item in
                Button { BridgeModel.shared.openWeb(item.url) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "checklist").font(.system(size: 10)).foregroundColor(Color(hex: "#A78BFA"))
                        Text("#\(item.id)").font(.system(size: 10)).foregroundColor(Color(hex: "#9398A1"))
                        Text(item.title).font(.system(size: 11)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(item.state).font(.system(size: 10)).foregroundColor(Color(hex: "#8E939C"))
                    }.frame(height: 22)
                }.buttonStyle(.plain).help("\(item.type) · \(item.assignedTo) · \(item.iteration)")
            }
        } else {
            if state.snapshot.activity.isEmpty { empty("New session completions, workflow events and Azure changes appear here.") }
            ForEach(state.snapshot.activity) { entry in
                Button { state.showActivity(entry) } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(entry.read ? Color.clear : Color(hex: "#F5A524")).frame(width: 5, height: 5).padding(.top, 4)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.title).font(.system(size: 12, weight: .medium))
                            Text(entry.body).font(.system(size: 10)).foregroundColor(Color(hex: "#9398A1")).lineLimit(2)
                        }
                        Spacer()
                        Text(displayDate(entry.date)).font(.system(size: 9)).foregroundColor(Color(hex: "#6B7079"))
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }
    private var connectionFooter: some View {
        HStack {
            Text(state.snapshot.errors.first ?? "\(state.snapshot.connection.capitalized) · \(state.snapshot.lastSync.map(displayDate) ?? "Not synced")\(workSection ? " · up to 200 items per view" : "")")
                .font(.system(size: 9)).foregroundColor(Color(hex: state.snapshot.errors.isEmpty ? "#6B7079" : "#F5A524"))
                .lineLimit(2).textSelection(.enabled)
            Spacer()
            if state.snapshot.connection == "disconnected" {
                Button("Connect") { BridgeModel.shared.perform("connect") }.buttonStyle(.plain).font(.system(size: 11))
            }
        }
    }
    private func empty(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C")).padding(.vertical, 12)
    }
}

struct SessionAnswerView: View {
    @ObservedObject var state: AppState
    var body: some View {
        CardBackground(wash: nil) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    backButton(state.selectedSession?.displayTitle ?? "Session") { state.view = .detail }
                    Spacer(minLength: 8)
                    if let session = state.selectedSession {
                        Button("Copy answers") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(session.answers.map(\.text).joined(separator: "\n\n"), forType: .string)
                        }.buttonStyle(.plain).font(.system(size: 10))
                        if session.agent == "codex", let id = UUID(uuidString: session.externalID) {
                            Button("Open Codex ↗") { NSWorkspace.shared.open(URL(string: "codex://threads/\(id.uuidString.lowercased())")!) }
                                .buttonStyle(.plain).font(.system(size: 10))
                        }
                    }
                }
                if let session = state.selectedSession {
                    Text("\(session.agentName) · \(session.state) · \(session.cwd)\(session.branch.isEmpty ? "" : " · " + session.branch)")
                        .font(.system(size: 9)).foregroundColor(Color(hex: "#6B7079")).lineLimit(1).textSelection(.enabled)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if session.answers.isEmpty {
                                Text("No final answer yet. Live status: \(session.state).")
                                    .font(.system(size: 12)).foregroundColor(Color(hex: "#9398A1"))
                                ForEach(session.steps.suffix(20)) { step in
                                    Text(step.text).font(.system(size: 11)).textSelection(.enabled)
                                }
                            }
                            ForEach(session.answers.reversed()) { answer in
                                Text(displayDate(answer.date)).font(.system(size: 9)).foregroundColor(Color(hex: "#6B7079"))
                                ChatMarkdownView(markdown: answer.text)
                                Divider().overlay(Color.white.opacity(0.06))
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.padding(14)
        }
    }
}

@MainActor private func backButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        HStack(spacing: 3) {
            Image(systemName: "chevron.left").font(.system(size: 8, weight: .medium))
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        }.foregroundColor(Color(hex: "#F5F6F8"))
    }.buttonStyle(.plain).help("Back")
}
private func statusColor(_ status: String) -> Color {
    switch status {
    case "waiting", "queued", "running", "working", "thinking": Color(hex: "#F5A524")
    case "failed", "error", "partiallySucceeded": Color(hex: "#F4505E")
    case "finished", "succeeded": Color(hex: "#22C55E")
    default: Color(hex: "#6B7079")
    }
}
private func reviewVote(_ vote: Int) -> String {
    switch vote { case 10: "Approved"; case 5: "Approved with suggestions"; case -5: "Waiting for author"; case -10: "Rejected"; default: "No vote" }
}
