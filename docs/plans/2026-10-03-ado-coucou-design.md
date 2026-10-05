# Approved scope: Coucou for two macOS developers

The user authorized a fork focused on Claude Code, Codex and Azure DevOps. Both developers use macOS. Existing Azure access uses the official MCP server’s interactive browser/localhost sign-in; a separately stored reusable token must not be assumed.

The user explicitly corrected an initial redesign: preserve Coucou’s basic notch design, elements, motion and shortcut views, and adapt its GitHub UI to Azure. The separate dashboard was discarded. The result uses Coucou’s original 640-point island, 160-point overview, focused card with four pills, card/pill components and GitHub row styles. Detail lists and full answers grow within that island. Protected branding/character/sounds remain excluded from distribution.

Five sources fill the existing layout: Claude Code, Codex, Azure DevOps, work items and inbox. Azure provides personal/review/colleague/all PR filters and pipeline runs; work-item filters cover assigned, new today, sprint and configurable due dates.

The native app owns a long-lived local Node bridge. That bridge owns an official ADO MCP child, private Unix socket, bounded transcript import and durable local state. This avoids reading another application’s credential cache. Azure calls are restricted to read tools. Partial refresh failures keep prior data and expose errors; each feed establishes its own silent notification baseline.

Hook installation previews and merges existing configuration with backups, never approves actions and never bypasses Codex hook trust. Local transcript import provides useful history before hooks run; stale sessions are not falsely shown as live. Workflow-ready/push announcements use an explicit verified helper after setup/push, rather than guessing readiness from filesystem changes.

Verification includes native Swift compilation, Node/Python fixture tests, a real Unix socket/daemon round trip and manual native checks of the notch, Azure data and session answers. Personal settings and live data are kept outside the repository.
