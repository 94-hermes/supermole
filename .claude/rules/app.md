---
paths:
  - "app/**"
  - "scripts/build_installer_dmg.sh"
  - "scripts/check_app_localization.py"
---

# Supermole.app (`app/`)

A one-window SwiftUI front end, in English and French, for people who never open Terminal. It ships in `Installer-Supermole.dmg`; installing `mo` and the dmg itself are covered in `.claude/rules/install-update.md`.

- **The app drives the installed `mo`; it never re-implements it.** Every scan, list and deletion is a `mo` command run by `MoleRunner` (`app/Sources/SupermoleCore/MoleRunner.swift`), so the safety rules of the CLI (protected paths, Trash by default, operation logs) apply unchanged. A section needs a machine-readable mode? Add it to `mo` with its own Bats tests, then read it from the app.
  - Runs get `NO_COLOR=1`, `TERM=dumb`, a PATH that also holds `~/.local/bin` and Homebrew (a GUI app inherits neither), stdin from `/dev/null`, and never `MOLE_DELETE_MODE`. `mo` refuses root, so the app never elevates a whole `mo` run.
  - Nothing is deleted without a preview first and an explicit click on a button naming the action.
- **Read-only sections use the JSON `mo` already has:** `status --watch --interval 2s` (one object per line; stopping the stream terminates `mo`), `analyze --json [path]` (flag before path; a partial scan exits 0, so read `scan_status`), `history --json --limit N`, and the explain answers `mo analyze` saves in `~/.cache/mole/explain/answers.json`.
- **macOS 26 is the app's floor**, for Liquid Glass (`glassEffect`, `GlassEffectContainer`, `.glass` / `.glassProminent` buttons); `mo` itself stays on macOS 12. Owner decision 2026-10-30: no fallback look for older systems. The build checks each slice against 26.0 (`INSTALLER_MIN_MACOS` in `scripts/build_installer_dmg.sh`).
- **Design.** Four spaces in the sidebar (Home, Clean up, Apps, Disk space); History is the inspector and Settings the standard Settings window. Cards are `GlassCard` over `AmbientBackground` (a brand-colored `MeshGradient` the glass refracts); charts are Swift Charts or the shared `RingGauge` / `Sparkline` / `StorageDonut`. A layout that switches on width measures a container its choice cannot resize (the scroll view): measuring the content it rearranges looped AppKit's constraint pass and aborted the app.
- **Localization.** The Swift sources are written in English and their text is the key. `app/Resources/fr.lproj/Localizable.strings` translates every key; `scripts/check_app_localization.py` compares it with the list the compiler emits (`-emit-localized-strings`) and fails the dmg build on a missing or stale key. Words that come from `mo` itself (overview places, health ratings and issues, battery condition) go through `MoleTerms` and the `MoleTerms.strings` tables, keyed `<context>.<term>`, and fall back to `mo`'s English. Show them with `Text(verbatim:)`: a folder name with `%` must not be read as a format.
- **Tests.** `SupermoleCore` holds everything that is not a view and is covered by `swift test` (run by step 3 of `scripts/test.sh`). Fixtures are written by hand: never commit real `mo` output, which carries the machine name and the user's file names.
