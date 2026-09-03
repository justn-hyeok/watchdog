# Watchdog Agent Guide

## Installation and release contract

- Read `INSTALL.md` before installing, updating, removing, packaging, or validating Watchdog. It is the canonical human-and-agent installation guide.
- The current official beta is `v0.1.0-beta.3` from `https://github.com/stacking-money-forever/watchdog/releases/tag/v0.1.0-beta.3`.
- For an ordinary agent install from this checkout, run `./scripts/install.sh`. It installs into `~/Applications` by default, verifies the pinned SHA-256 and code signature, and requests a graceful `SIGTERM` only for the exact installed Watchdog process during an update.
- Never use `sudo`, automatic `SIGKILL`, global Gatekeeper disabling, `xattr` quarantine removal, unsigned mirrors, or unverified release files as installation shortcuts.
- Do not silently change the release tag, download URL, or checksum in only one place. Keep `INSTALL.md`, `README.md`, `scripts/install.sh`, and GitHub release assets synchronized.
- For a non-launching automation install, use `./scripts/install.sh --no-launch`. Only use `--install-dir /Applications` when the caller already has write access; never invent privilege escalation.
- Verify an installed app with `codesign --verify --deep --strict --verbose=2`, bundle identifier `dev.justn.watchdog`, version output, launch, and exact process presence. Do not claim Gatekeeper-ready public distribution without Developer ID notarization and stapling.
- The project intentionally follows a no-paid-Apple-distribution policy. Public releases remain clearly labeled unnotarized betas unless that policy explicitly changes; Developer ID notarization is not a release blocker.
- The public beta uses Apple Development signing and Apple’s per-app approval flow: Finder **Open**, or System Settings → Privacy & Security → **Open Anyway**. This is not equivalent to Developer ID notarization.

## Engineering contract

- `project.yml` is the Xcode project source of truth; regenerate with `xcodegen generate` after target or file-layout changes.
- Preserve the default-safe behavior: never add automatic `SIGKILL`, never control system/other-user processes, and require confirmation for destructive actions.
- Every signal path must consume a fresh, single-use authorization bound to the exact action, process identity, and observation generation. Never restore snapshot-only controller overloads.
- Stale or failed sampling remains display-only and must disable suspend, resume, terminate, and force quit.
- Keep sampling and child-process work off the main actor. UI state mutations remain on `ProcessMonitor`'s main-actor boundary.
- Publish raw samples before optional working-directory enrichment. Keep resolver concurrency, lookup budget, deadlines, positive/negative caches, and generation-safe merging bounded.
- Use monotonic time for sustained thresholds and reset evidence after sampling failures or excessive observation gaps.
- Add deterministic unit tests for parsing, lineage classification, sustained-threshold logic, authorization replay, identity mismatch, stale gating, ignore/undo, resolver timeout/cancellation, and settings normalization.
- UI tests launch the shipping `Watchdog` target with DEBUG-only synthetic fixtures and must never send real process signals.
- Before handoff, regenerate the project, run the Watchdog scheme's unit and shipping-target UI tests, build Debug and Release, and perform a launch/process-presence smoke check.
- A notarized-distribution claim additionally requires Developer ID/hardened-runtime inspection, accepted notarization, stapling, post-staple Gatekeeper assessment, and retained long-run resource evidence. Never fabricate or weaken credentialed gates when release credentials are unavailable.
