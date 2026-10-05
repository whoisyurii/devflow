import AppKit
import Observation
import Security
import UserNotifications

@MainActor @Observable
final class BridgeModel {
    static let shared = BridgeModel()
    var snapshot = Snapshot()
    var error = ""
    var ready = false
    var hookPreview = ""
    var notificationStatus = ""
    @ObservationIgnored private var chime: NSSound?
    @ObservationIgnored private var lastChime = Date.distantPast
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var pending: [String: CheckedContinuation<Data, Error>] = [:]

    var unread: Int { snapshot.activity.filter { !$0.read }.count }
    var active: Int { snapshot.sessions.filter(\.active).count }
    var busy: Bool { ["connecting", "refreshing"].contains(snapshot.connection) }

    func start() {
        guard process == nil else { return }
        guard let node = Self.findNode() else {
            error = "Node.js 22 or later is required. Install it, then relaunch DevFlow."
            return
        }
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("bridge"),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("main.mjs").path) else {
            error = "The local bridge is missing. Rebuild DevFlow with scripts/build.sh."
            return
        }
        let child = Process()
        child.executableURL = node
        child.arguments = [root.appendingPathComponent("main.mjs").path]
        child.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = node.deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        child.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
        input = stdin.fileHandleForWriting
        let stream = BridgeStream()
        streamTask?.cancel()
        streamTask = Task { @MainActor [weak self] in
            for await event in stream.events {
                guard !Task.isCancelled else { break }
                self?.receive(event)
            }
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; stream.finish(); return }
            stream.append(data)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        // Drain this launch's stdout before marking it stopped. A final response
        // can still be on the decoding queue when Process reports termination.
        let consumer = streamTask
        child.terminationHandler = { [weak self] child in
            let status = child.terminationStatus
            Task { @MainActor [weak self] in
                await consumer?.value
                guard let self, self.process === child else { return }
                self.ready = false; self.process = nil; self.input = nil
                self.streamTask = nil
                if status != 0 { self.error = "The local bridge stopped (exit \(status)). Relaunch DevFlow to reconnect." }
                for continuation in self.pending.values { continuation.resume(throwing: BridgeError.message("Local bridge stopped.")) }
                self.pending.removeAll()
            }
        }
        do { try child.run(); process = child }
        catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            stream.finish(); streamTask?.cancel(); streamTask = nil
            input?.closeFile(); input = nil
            self.error = "Could not start the local bridge: \(error.localizedDescription)"
        }
    }
    func stop() {
        input?.closeFile(); input = nil
        // EOF may arrive before a stalled startup has installed its reader.
        // SIGTERM also reaches the bridge's graceful shutdown handler.
        if let process, process.isRunning { process.terminate() }
    }
    private func receive(_ event: BridgeStreamEvent) {
        switch event {
        case .failure(let message): error = message
        case .message(let message):
            switch message {
            case .snapshot(let state):
                snapshot = state
                ready = true
                NotificationCenter.default.post(name: .devflowStateChanged, object: nil)
            case .notice(let entry): notify(entry)
            case .fatal(let message): error = message
            case .response(let id, let result, let message):
                guard let continuation = pending.removeValue(forKey: id) else { return }
                if let message { continuation.resume(throwing: BridgeError.message(message)) }
                else { continuation.resume(returning: result) }
            case .ignored: break
            }
        }
    }
    func request(_ method: String, params: [String: Any] = [:]) async throws -> Data {
        guard let input else { throw BridgeError.message("The local bridge is not running.") }
        let id = UUID().uuidString
        var data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        data.append(10)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try input.write(contentsOf: data) }
            catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(180))
                self?.pending.removeValue(forKey: id)?.resume(throwing: BridgeError.message("The request timed out. Check Azure sign-in or disconnect and retry."))
            }
        }
    }
    func perform(_ method: String, params: [String: Any] = [:]) {
        Task { do { _ = try await request(method, params: params) } catch { self.error = error.localizedDescription } }
    }
    func save(_ settings: Settings) async throws {
        let data = try JSONEncoder().encode(settings)
        let params = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        _ = try await request("configure", params: params)
    }
    func previewHooks() async {
        do { let data = try await request("previewHooks"); hookPreview = try JSONDecoder().decode(String.self, from: data) }
        catch { self.error = error.localizedDescription }
    }
    func installHooks() async {
        do { _ = try await request("installHooks"); hookPreview = "" }
        catch { self.error = error.localizedDescription }
    }
    func openIsland(section: String? = nil) {
        if section == "activity" { AppState.shared.show(.inbox) }
        NotificationCenter.default.post(name: .devflowOpenIsland, object: nil)
    }
    func openActivity(_ activity: Activity) {
        perform("markRead", params: ["id": activity.id])
        if !activity.sessionID.isEmpty {
            AppState.shared.showSession(activity.sessionID)
            openIsland()
        } else { openWeb(activity.url) }
    }
    func dismissNotice(_ activity: Activity) {
        // Dismiss the presentation only. The Inbox and future session alerts
        // keep their existing behavior, including the unread state.
        NotificationCenter.default.post(name: .devflowDismissNotice, object: activity.id)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [activity.id])
        center.removeDeliveredNotifications(withIdentifiers: [activity.id])
    }
    func openWeb(_ string: String) {
        if let url = safeWebURL(string) { NSWorkspace.shared.open(url) }
    }
    func selectAgent(_ agent: String) {
        guard ["codex", "claude", "both"].contains(agent) else { return }
        if agent != "both" { AppState.shared.setFocus(agent) }
        perform("configure", params: ["agentProvider": agent])
    }
    func checkNotifications() {
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationStatus = settings.authorizationStatus == .authorized ? "System banners enabled."
                : settings.authorizationStatus == .denied ? "System banners are disabled in macOS Settings. Notch previews and the chime still work."
                : "Enable macOS notifications for system banners."
        }
    }
    func playChime(preview: Bool = false) {
        guard preview || snapshot.settings.notificationSound else { return }
        guard preview || Date.now.timeIntervalSince(lastChime) > 0.8 else { return }
        guard let url = Bundle.main.url(forResource: "DevFlowChime", withExtension: "wav") else {
            error = "The notification sound is missing. Rebuild DevFlow."; return
        }
        chime?.stop()
        chime = NSSound(contentsOf: url, byReference: true)
        chime?.volume = 0.5
        if chime?.play() != true { error = "Could not play the notification sound." }
        lastChime = .now
    }
    func previewNotification(agent: String) {
        let entry = Activity(id: UUID().uuidString, title: "Input needed", body: "Choose how to continue in the terminal.",
                             date: ISO8601DateFormatter().string(from: .now), read: false, url: "", sessionID: "",
                             agent: agent, sessionTitle: "Notification preview", worktree: "feature-worktree",
                             branch: "feature/example", cwd: snapshot.settings.sessionRepositoryPath,
                             pending: "Choose how to continue in the terminal.")
        notify(entry)
    }
    func requestNotifications() {
        Task {
            do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]); checkNotifications() }
            catch { self.error = error.localizedDescription }
        }
    }
    private func notify(_ entry: Activity) {
        NotificationCenter.default.post(name: .devflowNotice, object: entry)
        playChime()
        let content = UNMutableNotificationContent()
        content.title = entry.agent == nil ? entry.title : "\(entry.agentName) · \(entry.title)"
        if let worktree = entry.worktree { content.subtitle = "\(worktree) · \(entry.branch ?? "Unknown branch")" }
        content.body = [entry.sessionTitle, entry.pending ?? entry.body].compactMap { $0 }.joined(separator: "\n")
        // The app plays one chime for both notch and banner; avoid a duplicate system sound.
        content.userInfo = ["activityID": entry.id]
        let request = UNNotificationRequest(identifier: entry.id, content: content, trigger: nil)
        Task {
            do { try await UNUserNotificationCenter.current().add(request) }
            catch { notificationStatus = "System banner unavailable: " + error.localizedDescription }
        }
    }
    func savePAT(_ secret: String, organization: String) throws {
        guard !secret.isEmpty, !organization.isEmpty else { throw BridgeError.message("Enter an organization and PAT first.") }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "devflow.azure-devops", kSecAttrAccount as String: organization]
        let value = [kSecValueData as String: Data(secret.utf8)]
        let status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            let addStatus = SecItemAdd(query.merging(value) { _, new in new } as CFDictionary, nil)
            if addStatus != errSecSuccess { throw BridgeError.message("Could not save the PAT to Keychain (\(addStatus)).") }
        } else if status != errSecSuccess { throw BridgeError.message("Could not update Keychain (\(status)).") }
    }
    private static func findNode() -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] { candidates += path.split(separator: ":").map { String($0) + "/node" } }
        candidates += ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        let versions = fm.homeDirectoryForCurrentUser.appendingPathComponent(".nvm/versions/node")
        if let entries = try? fm.contentsOfDirectory(atPath: versions.path) {
            candidates += entries.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { versions.appendingPathComponent($0 + "/bin/node").path }
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}
enum BridgeError: LocalizedError { case message(String); var errorDescription: String? { if case let .message(value) = self { return value }; return nil } }
extension Notification.Name {
    static let devflowOpenIsland = Notification.Name("devflow.openIsland")
    static let devflowStateChanged = Notification.Name("devflow.stateChanged")
}
