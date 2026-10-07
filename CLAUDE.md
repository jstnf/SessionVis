# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

SessionVis is a native macOS app (Swift package, macOS 15, Swift 6 strict concurrency) that tails Claude Code transcripts under `~/.claude/projects/` for one directory and draws them as a gource-style radial file graph: each session is an orb that fires beams at the files it reads and edits, subagents sit inside their parent's halo, and a floating list mirrors iTerm's session-status panel. The README covers run commands, gestures, privacy and known gaps.

## Commands

```sh
swift build                                   # debug build, must stay at 0 warnings
swift test                                    # whole suite (Swift Testing)
swift test --filter SessionStoreTests         # one suite
swift test --filter SessionStoreTests/subagentEndsOnParentResultOrOwnTurnEndAndIsRemovedAfterLinger   # one test
swift run SessionVis --dir /path/to/repo                                        # live against a repo
swift run SessionVis --replay <transcript.jsonl> --speed 20 --dir <repo>        # replay one transcript
scripts/bundle-app.sh && open dist/SessionVis.app --args --dir <repo>           # release .app bundle
scripts/make-icon.sh                          # regenerate Assets/AppIcon.icns via the IconGen target
```

The directory must be given with `--dir`. A bare path argument makes AppKit treat it as a document to open and no window appears.

## Architecture

Three targets. `SessionVisCore` is pure Foundation/CoreGraphics (plus CoreServices for FSEvents) and holds everything testable; `SessionVis` is the SwiftUI/AppKit shell; `IconGen` draws the Dock icon with CoreGraphics. All tunables (durations, radii, limits) live in `SessionVisCore/Constants.swift`; do not scatter new magic numbers.

Data flows one way:

1. **Discovery** (`Discovery/`): `SessionDiscovery` finds `<uuid>.jsonl` transcripts and `<uuid>/subagents/agent-<id>.jsonl` + `.meta.json` under the project folder. `PathFolder` folds `.claude/worktrees/<name>/...` paths back onto the main tree. A transcript belongs to the directory based on its first `cwd` record; membership is tri-state (unknown until a cwd is seen) so just-created transcripts are not rejected forever.
2. **Transcript layer** (`Transcript/`): `TranscriptTailer` reads new bytes; `TranscriptParser` turns each JSONL record into `TranscriptEvent`s (user prompt, tool use/result, assistant text, turn ended, interrupted, title, relocated, worktree, task notification). Assistant records are split per content block with `stop_reason` only on the last one.
3. **Sources** (`Live/LiveSource.swift`, `Replay/ReplaySource.swift`) emit `SourceEvent`s (session/subagent appeared, line, hook, diagnostics, initial load complete). Replay rebases timestamps to the store clock.
4. **Store** (`Model/SessionStore.swift`, an actor) applies events to `AgentRecord`s, each with a `StatusMachine` (idle/working/waiting/ended with timestamp precedence: a status applies only if its timestamp is >= `statusAt`, which starts at `.distantPast` so history drives status at launch). It records file `Touch`es (which carry the toucher's hue and title) and publishes `StoreSnapshot`s, throttled to `snapshotInterval`.
5. **Simulation** (`Sim/Simulation.swift`, a `Sendable` value type) consumes snapshots and `TreeDelta`s: avatars with eased positions, beams, heat (3 s glow), lingering tint (fades over `tintDuration`), particles, halos (convex hull of a main orb and its subagents), dying/born node animations, a camera that auto-fits until the user pans or zooms. Hit testing uses layout positions; drawing uses eased `renderPositions`.
6. **Tree** (`Tree/`): `FileTreeScanner` seeds the whole repo (git-tracked files when possible, capped at `maxTreeFiles`), `RadialLayout` places it, `RepoWatcher` (FSEvents) produces `TreeDelta`s (added/removed/moved by unique-name pairing, with a full snapshot attached so the simulation can reconcile files it inserted from touches).
7. **App** (`Sources/SessionVis/`): `AppModel` (main actor, `@Observable`) owns the source, store and a `SimulationBox`; `SceneView` steps the simulation inside `TimelineView(.animation)` and `SceneRenderer` draws into a `Canvas`; `InputCaptureView` is an NSView forwarding scroll/pinch/hover/click; `OverlayListView` is the floating session list; `TooltipView` follows the hover point.

Optional hooks: a shell snippet (shown in Settings, `Hooks/HookSnippet.swift`) writes Claude Code hook payloads into `~/Library/Application Support/SessionVis/hooks/`, but only while the app's marker file exists. `HookSpoolReader` feeds them in as `.hook` events for exact "waiting on permission" states. The app works without hooks.

## Agent lifecycle rules worth knowing before touching the store

These span `SessionStore`, `StatusMachine` and the parser, and were each learned from real transcripts:

- Ended agents are **retired**, never deleted. Resumed subagents keep writing to the same transcript, and a later line un-retires the record with its original title, hue and parent, reviving the parent chain too.
- A subagent ends on its parent's `tool_result` for the spawning `Agent` call, on its own `end_turn` with no pending tools, on a `SubagentHandback` tool call, on a `[Request interrupted by user]` record, on the parent's `<task-notification>` (a user record or a `queue-operation` enqueue record), or on a `SubagentStop` hook.
- Ends the agent caused itself (hand-back, turn end, interruption, task notification) are **sticky**: only a new user prompt in its transcript or a `UserPromptSubmit` hook revives it. Ends caused by the parent stay revivable, because for background subagents the parent's `tool_result` arrives at launch ("Async agent launched") and the child's next line must bring it back.
- Lines older than an end never revive a record but still count for touches and parentage, since at launch a parent's whole file is read before its subagents' files.
- Main sessions age to `ended` after `activeWindow` without activity; subagents are never aged, they end only through the rules above.

## Verifying visually

Unit tests cover the core; the rendering can only be checked by launching the app. Launch the built binary detached (outside any sandbox), find its window with the CGWindow list, and capture it with `screencapture -x -o -l<windowID>`. Subagents cannot see the display, so the controlling session does this itself. When adding temporary diagnostics to a detached launch, write to stderr: stdout is block-buffered and lost if the process is killed.

The window is a full-size content view. The `Canvas`, `InputCaptureView` and `TooltipView` must all stay inside the safe-area frame (no `.ignoresSafeArea()` on them, only on the background colour), or hover coordinates drift by the title-bar height.
