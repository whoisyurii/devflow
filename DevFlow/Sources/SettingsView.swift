import SwiftUI
import AppKit

struct DevFlowSettingsView: View {
    @Bindable var model: BridgeModel
    @State private var draft = Settings()
    @State private var pat = ""
    @State private var showingPreview = false
    @State private var loaded = false
    @State private var saving = false
    @State private var status = ""

    var body: some View {
        TabView {
            Tab("Azure DevOps", systemImage: "cloud") {
                Form {
                    Section("Workspace") {
                        TextField("Organization", text: $draft.organization, prompt: Text("contoso"))
                        TextField("Project", text: $draft.project)
                        TextField("Repository", text: $draft.repository)
                        TextField("My email (optional)", text: $draft.myEmail)
                        TextField("Colleague’s email", text: $draft.colleagueEmail)
                        Text("Leave your email empty to use the authenticated Azure identity. Your colleague’s email enables their PR view. Work items are always personal.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Sign-in") {
                        Picker("Authentication", selection: $draft.authentication) {
                            Text("Microsoft sign-in (ADO MCP)").tag("interactive")
                            Text("Existing Azure CLI login").tag("azcli")
                            Text("PAT in macOS Keychain").tag("pat")
                            Text("Bearer token environment variable").tag("envvar")
                        }
                        if draft.authentication == "interactive" {
                            Text("Connect opens Microsoft sign-in through the official ADO MCP server. The connection stays alive while DevFlow runs.").font(.caption).foregroundStyle(.secondary)
                        }
                        if draft.authentication == "pat" {
                            SecureField("Personal access token", text: $pat)
                            Button("Save token to Keychain") {
                                do { try model.savePAT(pat, organization: draft.organization); pat = ""; status = "Saved to macOS Keychain." }
                                catch { model.error = error.localizedDescription }
                            }.disabled(pat.isEmpty || draft.organization.isEmpty)
                        }
                        if draft.authentication == "envvar" {
                            TextField("Variable name", text: $draft.tokenEnvironmentVariable)
                            Text("The variable must be available in the environment that launches DevFlow.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section("Work items") {
                        TextField("Project (optional)", text: $draft.workItemProject, prompt: Text("Same as repository project"))
                        TextField("Types (optional)", text: $draft.workItemTypes, prompt: Text("Activity, User Story, Bug"))
                        Text("Use a separate project for Boards if needed. Comma-separated types limit the list to your board; leave empty for all types. Work items show your open assignments, with status and Created today filters.").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Save") { save(connect: false) }.disabled(saving || !model.ready)
                        Button("Save and connect") { save(connect: true) }.buttonStyle(.borderedProminent).disabled(saving || !model.ready || model.busy)
                        Spacer()
                        if model.snapshot.connection != "disconnected" { Button("Disconnect") { model.perform("disconnect") } }
                    }
                    if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
                    ForEach(model.snapshot.errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                }.formStyle(.grouped)
            }
            Tab("Local sessions", systemImage: "terminal") {
                Form {
                    Section("Tracked project") {
                        HStack {
                            TextField("Repository checkout", text: $draft.sessionRepositoryPath, prompt: Text("/path/to/your/repository"))
                            Button("Choose folder…") { chooseRepository() }
                        }
                        TextField("Project folder", text: $draft.sessionSubdirectory)
                        Toggle("Include sessions at the repository root", isOn: $draft.includeRepositoryRoot)
                        Text("Only this Git repository is tracked. Linked worktrees are matched automatically; React.BFF includes ClientApp and its other subfolders.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Visible AI agent") {
                        Picker("Show", selection: $draft.agentProvider) {
                            Text("Codex only").tag("codex")
                            Text("Claude Code only").tag("claude")
                            Text("Both agents").tag("both")
                        }
                        Text("Single-agent mode gives the focus card more room. Switch here or in the notch header. In-scope history is retained for both agents; alerts follow the selected agent.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Save project and agent") { save(connect: false) }.disabled(!model.ready || saving)
                    }
                    Section("Claude Code and Codex") {
                        Text("Install DevFlow’s local event hooks to follow each session immediately. Existing hooks are preserved and configuration files are backed up.")
                        Text("Permission requests stay in the original agent. DevFlow only announces that input is needed.").font(.caption).foregroundStyle(.secondary)
                        Button("Preview hook installation…") {
                            Task { await model.previewHooks(); showingPreview = !model.hookPreview.isEmpty }
                        }.disabled(!model.ready)
                        if !model.snapshot.hookStatus.isEmpty { Text(model.snapshot.hookStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                    Section("Recent history") {
                        Toggle("Import recent sessions from this Mac", isOn: $draft.importHistory)
                        Text("Imports up to 100 matching transcripts per agent, checking at most 2,000 recent files. Live hooks retain the latest 50 completed answers per session. Imported history can be incomplete for very large transcripts.").font(.caption).foregroundStyle(.secondary)
                        Button("Save session preferences") { save(connect: false) }
                    }
                    Section("Workflow milestones") {
                        Text("After hooks are installed, use devflow-event.py from DevFlow’s Application Support folder at the end of a worktree setup or after a push. A push notification is emitted only when the remote branch matches local HEAD.").font(.caption)
                        Button("Show local tools") { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DevFlow")) }
                    }
                }.formStyle(.grouped)
            }
            Tab("Companion", systemImage: "bell") {
                Form {
                    Section("Appearance and alerts") {
                        Toggle("Show the notch companion", isOn: $draft.showNotch)
                        Toggle("Notify about meaningful changes", isOn: $draft.notifications)
                        Toggle("Play the soft notification chime", isOn: $draft.notificationSound)
                        Button("Preview chime") { model.playChime(preview: true) }
                        HStack {
                            Button("Preview Codex alert") { model.previewNotification(agent: "codex") }
                            Button("Preview Claude alert") { model.previewNotification(agent: "claude") }
                        }
                        Text(model.notificationStatus).font(.caption).foregroundStyle(.secondary)
                        Button("Enable macOS notifications") { model.requestNotifications() }
                        Button("Save preferences") { save(connect: false) }
                    }
                    Section("About DevFlow") {
                        Text("A local macOS companion for Claude Code, Codex and Azure DevOps.")
                        Text("Based on Coucou by Louis Raillé, under the MIT License. DevFlow uses its own identity and does not include Coucou’s protected character, artwork or sounds.").font(.caption).foregroundStyle(.secondary)
                        Text("Session history, settings and notification state stay on this Mac. Azure data is read through Microsoft’s local MCP server. No telemetry or model API calls.").font(.caption).foregroundStyle(.secondary)
                    }
                }.formStyle(.grouped)
            }
        }
        .padding(12).frame(width: 650, height: 730)
        .onAppear { loadDraft(); model.checkNotifications() }
        .onChange(of: model.ready) { loadDraft() }
        .onChange(of: model.snapshot.settings.agentProvider) { _, agent in draft.agentProvider = agent }
        .sheet(isPresented: $showingPreview) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Review local hook changes").font(.title2.bold())
                Text("Both settings files receive a dated backup. Existing hooks remain. Codex will ask you to trust the new hook definitions.").foregroundStyle(.secondary)
                ScrollView { Text(model.hookPreview).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack { Button("Cancel") { showingPreview = false }; Spacer(); Button("Install hooks") { Task { await model.installHooks(); showingPreview = !model.hookPreview.isEmpty } }.buttonStyle(.borderedProminent) }
            }.padding(24).frame(width: 700, height: 620)
        }
        .alert("DevFlow", isPresented: Binding(get: { !model.error.isEmpty }, set: { if !$0 { model.error = "" } })) {
            Button("OK") { model.error = "" }
        } message: { Text(model.error) }
    }
    private func loadDraft() { if model.ready && !loaded { draft = model.snapshot.settings; loaded = true } }
    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.title = "Choose your repository checkout"
        panel.prompt = "Use repository"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if !draft.sessionRepositoryPath.isEmpty { panel.directoryURL = URL(fileURLWithPath: draft.sessionRepositoryPath) }
        if panel.runModal() == .OK, let url = panel.url { draft.sessionRepositoryPath = url.path }
    }
    private func save(connect: Bool) {
        saving = true
        Task {
            do {
                try await model.save(draft)
                status = "Saved on this Mac."
                if connect { _ = try await model.request("connect") }
            } catch { model.error = error.localizedDescription }
            saving = false
        }
    }
}
