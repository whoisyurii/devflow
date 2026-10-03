# Working on this fork

Keep Coucou’s original notch interface. Reuse its components and GitHub-style views for Azure; do not introduce a replacement dashboard or a new visual language.

Scope: local Claude Code/Codex sessions and read-only Azure DevOps PRs, builds and work items. Preserve per-session identity, completed answers, existing user hooks and agent approval boundaries. Keep personal settings, Azure metadata, credentials and transcripts out of Git.

- `NotchBuddy/Sources/App`: retained/scoped Coucou UI.
- `DevFlow/Sources`: app entry, settings, local process bridge and data models.
- `bridge`: Node MCP client, local state, history import, Unix event relay and hook installer.
- `scripts/build.sh`: XcodeGen + native macOS build.
- `scripts/test.sh`: Node/Python tests, including local IPC.

Do not add unrelated integrations or ship Coucou’s separately licensed artwork. New UI should use the original island/card/pill components. Hook changes require a preview, merge and backup; never replace another tool’s hooks or trust hooks on the user’s behalf.
