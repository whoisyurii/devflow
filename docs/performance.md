# Notch performance check — 2026-10-04

The original Coucou layout is retained. Fixes target UI-thread blocking, update frequency, redundant layout work, and inactive animation scheduling.

## Evidence

The built-in display reports a maximum of 120 frames per second. A 120 Hz frame has an 8.33 ms budget; a 30 Hz pointer hit-test timer does not determine SwiftUI's animation frame rate.

An app-only 45-second Time Profiler capture of the previously installed Debug build recorded two main-thread hangs (4,515 ms and 6,763 ms). During both, about 99.5% of the interval sampled a running main thread. The dominant stack was `Data` / `Collection.firstIndex(of:)`: each stdout chunk appended to a growing buffer and rescanned it from its beginning. Full snapshot JSON parsing, reserialization and decoding also ran on MainActor.

A second app-only 45-second capture after the fixes and optimized Release installation recorded **zero hangs** during live agent activity and notch interaction. These are observational app runs, not identical replay workloads or a display-FPS measurement. Xcode 26's SwiftUI trace failed internally (`Observable event missing transaction in trace`), so no claim of a sustained 120 fps is made.

Controlled synthetic tests used generated content only, never real session transcripts:

| Workload | Before | After |
|---|---:|---:|
| 3.11 MB message, 4 KB chunks, optimized Swift | 3,904 ms framing only | 16.3 ms framing + decode + delivery |
| Same message, 32 KB chunks, optimized Swift | 492 ms framing only | 16.3 ms framing + decode + delivery |
| Same message, 32 KB chunks, Debug Swift | 1,228 ms framing only | 31.5 ms framing + decode + delivery |
| 100-hook burst against 3.11 MB state | 100 snapshots / 311.76 MB | 1 snapshot / 3.12 MB |
| Hook-burst serialization CPU | 322.62 ms | 4.24 ms |
| Full answers retained in burst fixture | 600 | 600 |

The new stream processing runs on a serial background queue, and only decoded state is applied on MainActor. It scans each arriving byte once, preserves FIFO messages and split UTF-8, and suppresses identical snapshots. Process-exit cleanup waits for the stream to drain. Snapshot publication is bounded to one per 75 ms window; notices and explicit snapshot requests remain immediate. Unchanged history scans avoid publication and cache writes.

UI fixes separate screen geometry from data updates, avoid unchanged assignments and repeated window raising, synchronize shell/content/clipping animations, pause invisible ticker shimmers, retain parsed unchanged answers, cache date format styles, and derive card summaries once per snapshot. Daily builds now use Release; `CONFIGURATION=Debug ./scripts/build.sh` remains available.

## Validation

- Release app build and local signature verification passed.
- 42 Node tests, 4 Python tests and 70 Swift checks passed.
- Regression coverage includes bounded burst publication, immediate notices, full answer retention, persistence/restart, unchanged history, byte-split streams, message ordering and error recovery.
- Installed app checked with live agent notifications, session navigation, and list scrolling.

To repeat the CPU check, attach Instruments' **Time Profiler** to **DevFlow only** for 45 seconds while opening, closing, navigating and receiving agent updates. Compare main-thread hangs and call stacks; use an animation-capable capture to assess actual rendered frame pacing separately. Keep traces local because profiling can contain private application metadata.
