# Personal work-item filters

Keep the existing Coucou card and capsule treatment. Work items belong only to the authenticated developer (or their configured My email identity). Keep All and Created today, remove shared/colleague/sprint/due views and their settings, and combine the date choice with the actual Azure status and title/ID search. Preserve the existing open-work scope: Closed, Done and Removed are excluded. The colleague identity continues to scope the separate PR view.

Use local filtering over the existing bounded personal queries. Show matching counts and a clear action. Status persists across app restarts; search persists while the app runs. A one-time cache migration clears old shared work-item data before the first personal refresh. Native UI checks and focused regression tests cover identity scope, status/search combinations and migration.
