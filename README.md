# DevFlow — a Coucou fork for Azure DevOps

A macOS notch companion for a small development team using **Claude Code, Codex and Azure DevOps**. Based on [Coucou](https://github.com/Louis-CFM/coucou) by Louis Raillé.

This fork keeps Coucou’s 640-point expanding island, compact notch geometry, spring transitions, focused card, four shortcut pills, card backgrounds, hover effects, badges, session ticker and Markdown renderer. Its GitHub statistic rows and PR rows are adapted to Azure DevOps. There is no separate dashboard, chat provider, GitHub connection, n8n, mail, music or billing integration.

## In the notch

Hover over or click the compact notch to open Coucou’s original two-card overview. Select a pill to move that source into the focus card. Lists and answers expand inside the same notch. Moving away closes it promptly; the pin button keeps it open. Escape folds it away, and the next hover restores your last view. The companion stays available across Spaces, including fullscreen apps.

- **Claude Code / Codex:** separate local sessions, live hook events, permission-needed announcements, completed answers, searchable recent history, Markdown/code rendering and copy. Codex answers can open their original chat.
- **Azure DevOps:** my PRs, requested reviews, a configured colleague’s PRs, all open PRs in the selected repository, reviewer votes, matching build results, **Today / All** pipeline filters plus an independent **Active only** switch. Today uses the queue date in your Mac’s time zone; All shows the loaded history. Rows open Azure for changes and logs.
- **Work items:** your own open assignments, All / Created today, exact Azure status filtering and title/#ID search. Status and search filters combine with the date choice; counts and a clear action make the active scope visible. Boards can use a different project from the repository, and an optional work-item type list matches your board’s scope. Each developer sees their own assignments; colleague settings apply only to PRs.
- **Inbox:** durable unread session and Azure updates. New events peek from the notch without interrupting a pinned detail view. macOS banners are optional.

Azure operations are read-only. DevFlow does not approve agent permissions, merge PRs, edit tickets or run/cancel pipelines.

## Build and run

Requires macOS 15+, Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen), Node.js 22.16+ and Python 3. The build packages pinned npm dependencies; Node remains a local prerequisite. Homebrew and nvm installations are discovered when launched from Finder.

```sh
./scripts/build.sh
open build/Build/Products/Debug/DevFlow.app
```

Copy the resulting app to `~/Applications` for everyday use. Add it to macOS **Login Items** if you want it to start at login. This is an unsigned internal development build, not a notarized release.

## Azure setup

Open **Settings → Azure DevOps**, enter your organization, project and repository, and choose **Save and connect**. Leave **My email** empty to use the signed-in Azure account. Enter your colleague’s Azure identity email to enable their PR filter. In the Work items section, set Project when Boards live elsewhere, and optionally a comma-separated Types list from that board. A blank work-item project uses the repository project.

The default is the official [`@azure-devops/mcp`](https://github.com/microsoft/azure-devops-mcp) server and its normal Microsoft browser/localhost authentication. A long-lived local MCP process handles all polling while the app runs. DevFlow does not extract or assume a reusable token from Claude or Codex. On launch, connect once; the Microsoft server controls when reauthentication is needed.

Existing Azure CLI authentication is an alternative. An optional PAT is stored in macOS Keychain under `devflow.azure-devops`, never in settings. Bearer-token environment mode is also available. The configured organization and project must be accessible to that identity.

The Reviews view includes open PRs where you are an assigned reviewer, including ones you already voted on; hover a row for reviewer votes. PR build badges only describe matching PR merge-commit builds; they are **not** a claim that every Azure branch policy has passed. Pipeline and work-item queries are bounded: up to 100 recent builds plus 100 running and 100 queued builds, and up to 200 personal open work items per query (all recent assignments and items created today). PR discovery paginates up to 2,000 open PRs.

## Local session hooks

Open **Settings → Local sessions → Preview hook installation**. Installation merges DevFlow command hooks into `~/.claude/settings.json` and `~/.codex/hooks.json`, preserves other tools’ hooks and creates dated backups. It refuses installation if either configuration changed after preview.

Start a new Claude Code session after installation. **Review and trust the new hook definitions in Codex’s Hooks settings or `/hooks`** where supported by your client. DevFlow does not bypass that trust step. A client that does not run these hooks still appears through local transcript import, without guaranteed immediate live status or completion banners.

The relay sends events through a private local Unix socket, times out after 150 ms and always leaves agent permissions to the originating client. It does not copy tool outputs. Recent history imports the 100 latest transcript files for each agent, with a 2 MiB tail limit per large transcript. It retains up to 200 sessions, 50 completed answers and 60 status steps per session, and 500 inbox entries. Missing or stale active-state evidence is shown as unknown; imported old answers do not create a flood of notifications.

### Worktree and push milestones

The installed helper is an explicit workflow integration. Call it after your setup script has finished or your push has succeeded:

```sh
python3 "$HOME/Library/Application Support/DevFlow/devflow-event.py" worktree-ready --path /path/to/worktree
python3 "$HOME/Library/Application Support/DevFlow/devflow-event.py" branch-pushed --path /path/to/repo --remote origin
```

The push helper verifies the remote branch matches local HEAD before announcing it. Arbitrary terminal pushes/worktree setup are not automatically inferred. The helper exits quietly when the companion is absent.

## Local data and troubleshooting

Settings, cached Azure data, session answers and the event socket live in `~/Library/Application Support/DevFlow` (directory mode 0700; data and socket 0600). The relay scripts are installed there too. Nothing in this directory belongs in Git. No telemetry or model API calls are added by this fork.

If sign-in needs attention, use Settings to disconnect and connect again. Each Azure feed retains its previous data on a refresh failure; errors and the last successful refresh time remain visible. Polling slows down after failures. Closing the app shuts down its MCP child and socket.

To remove DevFlow hooks, quit the app and remove only commands referring to `Application Support/DevFlow/devflow-hook.py` from the two hook files. Dated `.devflow-backup-*` files can help compare the previous configuration; do not overwrite unrelated later changes.

## Verification

```sh
./scripts/test.sh
```

Tests cover concurrent sessions, answer persistence and replay, history import, hook merging/backups/stale previews, the real Unix relay and daemon, Azure parsing, build matching, independent refresh baselines, personal cross-project work-item scope, status/search combinations, cache migration, local-day pipeline filters (including DST), hover/close behavior and cache recovery. Native compilation uses Swift 6; interface checks include notch overview, Azure lists and session answers.

## Upstream and licensing

Source code retains the [MIT license](LICENSE). Original reused UI code remains under `NotchBuddy/Sources/App`; the native bridge/settings and build configuration are in `DevFlow`, and the local MCP/event bridge is in `bridge`.

Coucou separately reserves its name, Mochi character, artwork, icons and sounds in [LICENSE-ASSETS.md](LICENSE-ASSETS.md). This fork preserves the UI code and layout, uses the name DevFlow and source-specific system symbols, and does not redistribute those protected assets. There are no release uploads containing Coucou artwork.
