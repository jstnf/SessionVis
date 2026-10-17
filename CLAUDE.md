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

1. **Discovery** (`Discovery/`): `SessionDiscovery` finds `<uuid>.jsonl` transcripts and `<uuid>/subagents/agent-<id>.jsonl` + `.meta.json` under the project folder. `WorktreeLister` asks `git worktree list --porcelain` for every checkout of the repository (falling back to the directories under `.claude/worktrees` when git cannot be run) and `PathFolder`, built from that registry, folds any path inside any checkout back onto the main tree, tagged with the worktree's name; `rootPath(of:)` answers where an origin's files live. Every holder of a folder (store, live source, watcher, simulation) has `setFolder(_:)`, and the app swaps it when a vnode watcher on `<git common dir>/worktrees` fires. A transcript belongs to the directory based on its first `cwd` record; membership is tri-state (unknown until a cwd is seen) so just-created transcripts are not rejected forever.
2. **Transcript layer** (`Transcript/`): `TranscriptTailer` reads new bytes; `TranscriptParser` turns each JSONL record into `TranscriptEvent`s (user prompt, tool use/result, assistant text, turn ended, interrupted, title, relocated, worktree, task notification). Assistant records are split per content block with `stop_reason` only on the last one.
3. **Sources** (`Live/LiveSource.swift`, `Replay/ReplaySource.swift`) emit `SourceEvent`s (session/subagent appeared, line, hook, diagnostics, initial load complete, and `diskChanges`, which the app sends from the watcher's deltas rather than a source). Replay rebases timestamps to the store clock.
4. **Store** (`Model/SessionStore.swift`, an actor) applies events to `AgentRecord`s, each with a `StatusMachine` (idle/working/waiting/ended with timestamp precedence: a status applies only if its timestamp is >= `statusAt`, which starts at `.distantPast` so history drives status at launch). It records file `Touch`es (which carry the toucher's hue and title). It also records Bash calls as `CommandEvent`s classified by `CommandClassifier` (a chain with several git milestones becomes one event per milestone, in order), filling commit hashes from the matching tool result. Bash commands also go through `ShellTouchParser`, a fixed verb grammar whose operands and redirections become touches; a shell or search read is kept only if its target exists on disk. The watcher's disk changes arrive as `diskChanges` events that the store credits, after a settling delay and once the initial load is in, to the one agent with a running command. It publishes `StoreSnapshot`s, throttled to `snapshotInterval`.
5. **Simulation** (`Sim/Simulation.swift`, a `Sendable` value type) consumes snapshots and `TreeDelta`s: avatars with eased positions, beams, heat (3 s glow), lingering tint on touched files and on every edge from the root down to them (both fade over `tintDuration`; a shared edge takes the newest toucher's hue), particles, halos (convex hull of a main orb and its subagents), dying/born node animations, ghost files (origin set without main) drawn as rings that land when main gains them, command pulses, commit ripples and badges, a camera that auto-fits until the user pans or zooms, or follows one agent (`followTarget(for:)` frames the agent's main, its halo and recent touches at a zoom clamped to `followMinZoom…followMaxZoom`; centre and zoom ease at separate rates; `stopFollowing` holds the camera). A `FileFilter` of gitignore-like `GlobPattern`s (`Filter/`) is applied here, not upstream: files it hides are kept out of the tree with their origins in `hidden`, `setFilter` moves them in and out without a rescan, watcher deltas are split into a hidden side and a visible remainder, and a file touch on a hidden path is consumed (sequence advanced, nothing drawn, no pull on the orb). Hit testing uses layout positions; drawing uses eased `renderPositions`.
6. **Tree** (`Tree/`): `FileTreeScanner` seeds the whole repo (git-tracked files when possible, capped at `maxTreeFiles` distinct paths across checkouts) once for the main checkout and once per registered worktree (main's listing skips checkouts nested inside the root), tagging each file with its origins; `RadialLayout` places it; `RepoWatcher` (FSEvents, one stream over the root plus every worktree root outside it, recreated when the registry changes) emits one `TreeDelta` per origin that changed (added/removed/moved by unique-name pairing, with a full snapshot attached so the simulation can reconcile files it inserted from touches; deltas also carry `changed` paths (rewritten files, mapped from FSEvents' real paths back onto the watched directory) and a timestamp).
7. **App** (`Sources/SessionVis/`): `AppModel` (main actor, `@Observable`) owns the source, store and a `SimulationBox`; `SceneView` steps the simulation inside `TimelineView(.animation)` and `SceneRenderer` draws into a `Canvas`; `InputCaptureView` is an NSView forwarding scroll/pinch/hover/click and, as first responder, `keyDown` translated into a `KeyCommand` (`Input/KeyCommand.swift` maps key code and modifiers; a new shortcut is a new case and one mapping line, never a view change); `OverlayListView` is the floating session list; `TooltipView` follows the hover point. `FileFilterStore` keeps the hidden-file rules per directory in UserDefaults and `HiddenFilesSection` is their Settings UI. `AppModel+Terminal.swift` brings a session's terminal tab to the front through the core `Terminal/` folder: `TerminalLocator` is pure parsing of Claude Code's `~/.claude/sessions/<pid>.json`, `ps` output and AppleScript results, and `TerminalOpener` validates the pid with `ps` (alive, on a tty, started when the file says) and sends one find-and-select AppleScript per running terminal app, iTerm2 before Terminal; the app only decides which apps are running.

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
