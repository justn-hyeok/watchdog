# Watchdog Agent Guide

- `project.yml` is the Xcode project source of truth; regenerate with `xcodegen generate` after target or file-layout changes.
- Preserve the default-safe behavior: never add automatic `SIGKILL`, never control system/other-user processes, and require confirmation for destructive actions.
- Every signal path must consume a fresh, single-use authorization bound to the exact action, process identity, and observation generation. Never restore snapshot-only controller overloads.
- Stale or failed sampling remains display-only and must disable suspend, resume, terminate, and force quit.
- Keep sampling and child-process work off the main actor. UI state mutations remain on `ProcessMonitor`'s main-actor boundary.
- Publish raw samples before optional working-directory enrichment. Keep resolver concurrency, lookup budget, deadlines, positive/negative caches, and generation-safe merging bounded.
- Use monotonic time for sustained thresholds and reset evidence after sampling failures or excessive observation gaps.
- Add deterministic unit tests for parsing, lineage classification, sustained-threshold logic, authorization replay, identity mismatch, stale gating, ignore/undo, resolver timeout/cancellation, and settings normalization.
- UI tests use the synthetic `WatchdogPreview` fixture and must never send real process signals.
- Before handoff, regenerate the project, run Watchdog unit tests and WatchdogPreview UI tests, build Debug and Release, and perform a launch/process-presence smoke check.
- A distributable-release claim additionally requires Developer ID/hardened-runtime inspection, accepted notarization, stapling, post-staple Gatekeeper assessment, and retained long-run resource evidence. Never fabricate or weaken credentialed gates when release credentials are unavailable.
