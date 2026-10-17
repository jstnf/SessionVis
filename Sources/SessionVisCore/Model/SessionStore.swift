import Foundation

/// Owns every agent's state.
public actor SessionStore {
    struct UsageContribution: Equatable {
        let messageID: String
        let input: Int
        let output: Int
    }

    struct AgentRecord {
        let id: AgentID
        let sessionId: String
        var kind: AgentKind
        var aiTitle: String?
        var firstPrompt: String?
        var machine: StatusMachine
        var hueIndex: Int
        /// Supplied by the source: the rank of the subagent's transcript among its session's; mains stay 0.
        var ordinal = 0
        /// Derived from `ordinal` and the immediate parent's shade; mains stay 0.
        var shade = 0
        var branch: String?
        var worktree: String?
        var cwd: String?
        let firstSeen: Date
        var endedAt: Date?
        var retired = false
        var touchCount = 0
        var lastCommandLabel: String?
        var lastMilestone: Milestone?
        var metaToolUseId: String?
        /// Ended by its own hand-back/turn end or by a task notification: only a resume (new user prompt) revives it.
        var stickyEnd = false
        var model: String?
        /// Latest context size (input + cache read + cache create of the newest record, or a compaction's post size) and its timestamp.
        var contextTokens: Int?
        var contextAt = Date.distantPast
        var window: Int?
        var inputTotal = 0
        var outputTotal = 0
        /// The last usage record's contribution: a repeat of its id replaces it rather than adding again.
        var lastUsage: UsageContribution?

        var title: String {
            if case .subagent(_, let description, _, _) = kind { return description }
            if let aiTitle, !aiTitle.isEmpty { return aiTitle }
            if let firstPrompt { return SessionStore.truncateOnWord(firstPrompt, max: 60) }
            return String(sessionId.prefix(8))
        }
    }

    private(set) var folder: PathFolder
    private let clock: @Sendable () -> Date
    private var agents: [AgentID: AgentRecord] = [:]
    private var toolUseOwner: [String: AgentID] = [:]        // tool_use id → agent that issued it
    private var subagentByToolUseId: [String: AgentID] = [:]  // meta.toolUseId → subagent
    private var touches: [Touch] = []
    /// Newest file-scope touch per path, unbounded by the touch ring and pruned to the focus window when published.
    private var lastFileTouch: [RepoPath: Date] = [:]
    private var nextSeq: UInt64 = 1
    private var commands: [CommandEvent] = []
    private var nextCommandSeq: UInt64 = 1
    private var pendingCommits: [String: UInt64] = [:]   // tool_use id of a `git commit` → command seq
    private var pendingDiskChanges: [DiskChange] = []
    /// Bash calls without a result yet, per agent: tool_use id → start. Closed by the result, the agent's turn end,
    /// interruption or end, since no tool runs past those.
    private var openCommands: [AgentID: [String: Date]] = [:]
    /// The latest time each agent's command closed.
    private var recentCommandCompletions: [AgentID: Date] = [:]
    /// Edit/Write/NotebookEdit calls without a result yet: tool_use id → path. Their file may land on disk any time until the result.
    private var openFileWrites: [String: RepoPath] = [:]
    /// When a file tool's write to each path finished, kept for `touchDedupeWindow`.
    private var recentFileWriteCompletions: [RepoPath: Date] = [:]
    /// Disk changes count only once the initial load is in, so history commands are never taken as running.
    private var loaded = false
    private var nextHue = 0
    private var hookEventsSeenAt: Date?
    private var skippedLines = 0

    public init(folder: PathFolder, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.folder = folder
        self.clock = clock
    }

    /// Swaps the registry. Records whose cwd is inside a now-registered checkout get its name, so a session tracked
    /// before its worktree was registered is labelled; a record's existing label is never cleared here.
    public func setFolder(_ folder: PathFolder) {
        self.folder = folder
        for (id, var rec) in agents {
            guard let cwd = rec.cwd, let name = folder.worktreeName(ofCwd: cwd) else { continue }
            rec.worktree = name
            agents[id] = rec
        }
    }

    // MARK: - Apply

    public func apply(_ event: SourceEvent) {
        switch event {
        case .sessionAppeared(let sid, _):
            _ = ensureMain(sid)
        case .subagentAppeared(let sid, let aid, let meta, let ordinal):
            ensureSubagent(sessionId: sid, agentId: aid, meta: meta, ordinal: ordinal)
        case .subagentOrdinal(_, let aid, let ordinal):
            let id = AgentID(aid)
            if var rec = agents[id], rec.ordinal != ordinal, ordinal > 0 {
                rec.ordinal = ordinal
                agents[id] = rec
                refreshShade(of: id, force: true)
            }
        case .line(let sid, let aid, let line):
            applyLine(sessionId: sid, agentId: aid, line: line)
        case .hook(let hook):
            applyHook(hook)
        case .diagnostics(let skipped):
            skippedLines = skipped
        case .diskChanges(let change):
            guard loaded, change.paths.count <= Constants.diskAttributionPathLimit else { return }   // bulk operations are not edits
            pendingDiskChanges.append(change)
        case .initialLoadComplete:
            loaded = true
        }
    }

    /// Applies a hook event to status. PreToolUse for AskUserQuestion is ignored so it cannot override the transcript's `waiting`.
    func applyHook(_ hook: HookEvent) {
        hookEventsSeenAt = hook.receivedAt
        guard let cwd = hook.cwd, folder.isMemberCwd(cwd) else { return }
        let t = hook.receivedAt
        let mainId = AgentID(hook.sessionId)

        switch hook.name {
        case "SessionStart":
            let id = ensureMain(hook.sessionId, at: t)
            agents[id]?.machine.touch(at: t)
        case "SessionEnd":
            if agents[mainId] != nil { endAgent(mainId, at: t) }
        case "UserPromptSubmit", "PreToolUse", "PostToolUse":
            if hook.name == "PreToolUse", hook.toolName == "AskUserQuestion" { return }
            let target: AgentID
            if let aid = hook.agentId {
                if agents[AgentID(aid)] == nil { ensureSubagent(sessionId: hook.sessionId, agentId: aid, meta: nil, at: t) }
                target = AgentID(aid)
                guard unretire(target, at: t, resume: hook.name == "UserPromptSubmit") else { return }
            } else {
                target = ensureMain(hook.sessionId, at: t)
            }
            agents[target]?.machine.touch(at: t)
            agents[target]?.machine.set(.working, at: t)
        case "Notification":
            guard let type = hook.notificationType, HookEvent.waitingNotificationTypes.contains(type) else { return }
            _ = ensureMain(hook.sessionId, at: t)
            agents[mainId]?.machine.touch(at: t)
            agents[mainId]?.machine.set(.waiting(preview: hook.message ?? type), at: t)
        case "PermissionRequest":
            _ = ensureMain(hook.sessionId, at: t)
            agents[mainId]?.machine.touch(at: t)
            agents[mainId]?.machine.set(.waiting(preview: "Permission: \(hook.toolName ?? "tool")"), at: t)
        case "Stop":
            unretire(mainId, at: t)
            guard var rec = agents[mainId] else { return }
            rec.machine.setLastAssistantText(hook.lastAssistantMessage)
            rec.machine.touch(at: t)
            rec.machine.set(.idle(preview: StatusMachine.firstLine(rec.machine.lastAssistantText)), at: t)
            agents[mainId] = rec
        case "SubagentStop":
            guard let aid = hook.agentId, agents[AgentID(aid)] != nil else { return }
            agents[AgentID(aid)]?.machine.setLastAssistantText(hook.lastAssistantMessage)
            endAgent(AgentID(aid), at: t)
        default:
            break
        }
    }

    /// `t` is the triggering event's time (nil: the store clock), used to decide whether an ended record resumes.
    private func ensureMain(_ sessionId: String, at t: Date? = nil) -> AgentID {
        let id = AgentID(sessionId)
        unretire(id, at: t ?? clock())
        if agents[id] == nil {
            let now = clock()
            agents[id] = AgentRecord(id: id, sessionId: sessionId, kind: .main, machine: StatusMachine(at: .distantPast),
                                     hueIndex: nextHue % HuePalette.count, firstSeen: now)
            nextHue += 1
        }
        return id
    }

    private func ensureSubagent(sessionId: String, agentId: String, meta: SubagentMeta?, ordinal: Int = 0, at t: Date? = nil) {
        let mainId = ensureMain(sessionId, at: t)
        let id = AgentID(agentId)
        let parent = meta?.toolUseId.flatMap { toolUseOwner[$0] } ?? mainId
        let kind = AgentKind.subagent(parent: parent, description: meta?.description ?? "subagent",
                                      agentType: meta?.agentType, model: meta?.model)
        unretire(id, at: t ?? clock())
        if var existing = agents[id] {
            existing.kind = kind
            existing.hueIndex = agents[parent]?.hueIndex ?? existing.hueIndex
            existing.metaToolUseId = meta?.toolUseId ?? existing.metaToolUseId
            if ordinal > 0 { existing.ordinal = ordinal }
            agents[id] = existing
            refreshShade(of: id)
        } else {
            let now = clock()
            // Without a source ordinal (a record first seen from a line or hook) take the next one after its siblings.
            let resolved = ordinal > 0 ? ordinal : nextOrdinal(under: lineageRoot(of: parent))
            agents[id] = AgentRecord(id: id, sessionId: sessionId, kind: kind, machine: StatusMachine(at: .distantPast),
                                     hueIndex: agents[parent]?.hueIndex ?? 0, ordinal: resolved, firstSeen: now, metaToolUseId: meta?.toolUseId)
            refreshShade(of: id)
        }
        if let tid = meta?.toolUseId { subagentByToolUseId[tid] = id }
    }

    private func applyLine(sessionId: String, agentId: String?, line: TranscriptLine) {
        // Compaction records and untimed usage records are bookkeeping only: they reach an existing record's context and
        // totals, and never create, revive or age one.
        switch line.event {
        case .compacted(_, let post):
            let key = AgentID(agentId ?? sessionId)
            if var rec = agents[key], let stamp = line.timestamp, stamp >= rec.contextAt {
                rec.contextTokens = min(max(post, 0), Constants.tokenCountCap)
                rec.contextAt = stamp
                agents[key] = rec
            }
            return
        case .usage(let messageID, let model, let input, let output, let cacheRead, let cacheCreate) where line.timestamp == nil:
            let key = AgentID(agentId ?? sessionId)
            if var rec = agents[key] {
                applyUsage(messageID: messageID, model: model, counts: (input, output, cacheRead, cacheCreate), at: nil, to: &rec)
                agents[key] = rec
            }
            return
        default:
            break
        }
        let id: AgentID
        let t = line.timestamp ?? clock()
        if let agentId {
            if agents[AgentID(agentId)] == nil { ensureSubagent(sessionId: sessionId, agentId: agentId, meta: nil, at: t) }
            id = AgentID(agentId)
        } else {
            id = ensureMain(sessionId, at: t)
        }
        var resume = false
        if case .userPrompt = line.event { resume = true }
        let active = unretire(id, at: t, resume: resume)
        guard var rec = agents[id] else { return }
        if let cwd = line.cwd { rec.cwd = cwd; rec.worktree = folder.worktreeName(ofCwd: cwd) ?? rec.worktree }
        if let b = line.gitBranch { rec.branch = b }

        switch line.event {
        case .title(let title):
            if case .main = rec.kind { rec.aiTitle = title }
        case .relocated(let cwd):
            rec.cwd = cwd
            rec.worktree = folder.worktreeName(ofCwd: cwd)
        case .worktree(let name, let branch, _):
            rec.worktree = name
            rec.branch = branch
        case .userPrompt(let text):
            if rec.firstPrompt == nil { rec.firstPrompt = text }
        case .toolUse(let toolId, let name, let filePath, let description, _, let command):
            toolUseOwner[toolId] = id
            if let child = subagentByToolUseId[toolId], var childRec = agents[child], child != id {
                if case .subagent(_, let d, let at, let m) = childRec.kind {
                    childRec.kind = .subagent(parent: id, description: d, agentType: at, model: m)
                    childRec.hueIndex = rec.hueIndex
                    agents[child] = childRec
                    refreshShade(of: child)
                }
            }
            if let kind = TouchKind.forTool(name) {
                let search = TouchKind.isSearchTool(name)
                let base = rec.cwd ?? folder.root
                let mustExist = search && kind == .read
                if let filePath {
                    let absolute = filePath.hasPrefix("/") ? filePath : base + "/" + filePath
                    let folded = recordFolded(absolute: absolute, kind: kind, scope: search ? .directory : .file, source: .tool(name), at: t, for: &rec, mustExist: mustExist)
                    if kind == .write, let folded { openFileWrites[toolId] = folded.path }
                } else if search {
                    recordFolded(absolute: base, kind: kind, scope: .directory, source: .tool(name), at: t, for: &rec, mustExist: mustExist)
                }
            }
            if name == "Bash", let command {
                openCommands[id, default: [:]][toolId] = t
                for st in ShellTouchParser.touches(in: command, cwd: rec.cwd ?? folder.root) {
                    recordFolded(absolute: st.path, kind: st.kind, scope: st.scope, source: .shell(st.verb), at: t, for: &rec, mustExist: st.kind == .read)
                }
                // A chain with several git milestones records each one, in order; otherwise the whole command is one event.
                let milestones = CommandClassifier.milestoneSegments(command)
                let parts = milestones.count > 1 ? milestones : [command]
                for (i, part) in parts.enumerated() {
                    let cls = CommandClassifier.classify(part)
                    let event = CommandEvent(seq: nextCommandSeq, agent: id, toolUseId: toolId, at: t, commandClass: cls,
                                             label: CommandClassifier.label(command: part, description: i == 0 ? description : nil),
                                             command: part, hueIndex: rec.hueIndex)
                    if cls == .git(.commit) { pendingCommits[toolId] = event.seq }
                    nextCommandSeq += 1
                    commands.append(event)
                    rec.lastCommandLabel = event.label
                    if let m = event.milestone { rec.lastMilestone = m }
                }
                if commands.count > Constants.recentCommandLimit { commands.removeFirst(commands.count - Constants.recentCommandLimit) }
            }
        case .toolResult(let toolId, let text):
            if let child = subagentByToolUseId[toolId] { endAgent(child, at: t) }
            for i in commands.indices where commands[i].toolUseId == toolId { commands[i].completedAt = t }
            closeCommand(toolId, of: toolUseOwner[toolId] ?? id, at: t)
            if let path = openFileWrites.removeValue(forKey: toolId) {
                recentFileWriteCompletions = recentFileWriteCompletions.filter { t.timeIntervalSince($0.value) <= Constants.touchDedupeWindow }
                recentFileWriteCompletions[path] = t
            }
            if let seq = pendingCommits.removeValue(forKey: toolId), let info = text.flatMap(CommandClassifier.parseCommit) {
                if let i = commands.firstIndex(where: { $0.seq == seq }) { commands[i].commit = info }
                if rec.lastMilestone == .commit(nil) { rec.lastMilestone = .commit(info) }
            }
        case .turnEnded, .interrupted:
            closeCommands(of: id, at: t)
        case .usage(let messageID, let model, let input, let output, let cacheRead, let cacheCreate):
            applyUsage(messageID: messageID, model: model, counts: (input, output, cacheRead, cacheCreate), at: line.timestamp, to: &rec)
        case .compacted:
            break
        case .assistantText, .taskNotification:
            break
        }

        if active { rec.machine.apply(line.event, at: t) }
        agents[id] = rec
        if case .taskNotification(let taskId, _) = line.event, AgentID(taskId) != id, agents[AgentID(taskId)] != nil {
            endAgent(AgentID(taskId), at: t, sticky: true)
        }
        guard active, case .subagent = rec.kind else { return }
        if line.event == .turnEnded, rec.machine.pending.isEmpty { endAgent(id, at: t, sticky: true) }
        if case .toolUse(_, let name, _, _, _, _) = line.event, name == "SubagentHandback" { endAgent(id, at: t, sticky: true) }
        if line.event == .interrupted { endAgent(id, at: t, sticky: true) }
    }

    /// An event at `t` for an ended (lingering or retired) record brings it back with its identity
    /// (kind, hue, firstSeen, touchCount) intact — unless the event is older than the end, as when a
    /// subagent's history is read after its parent's result ended it, or the end is sticky and the event
    /// is not a resume. Returns whether the record is active afterwards.
    /// Reviving a parent chain also clears a sticky end on parent subagents: a subagent that handed back
    /// while its own child still runs comes back as idle.
    @discardableResult
    private func unretire(_ id: AgentID, at t: Date, resume: Bool = false) -> Bool {
        guard var rec = agents[id] else { return false }
        if rec.retired || rec.endedAt != nil || rec.machine.status == .ended {
            guard t >= rec.machine.statusAt, resume || !rec.stickyEnd else { return false }
            rec.retired = false
            rec.endedAt = nil
            rec.stickyEnd = false
            if rec.machine.status == .ended { rec.machine.set(.idle(preview: nil), at: t) }
            agents[id] = rec
        }
        // An active subagent needs its parent chain (and main session) on screen.
        var parent = rec.parentId
        var depth = 0
        while let pid = parent, depth < 16, var p = agents[pid] {
            if p.retired || p.endedAt != nil || p.machine.status == .ended {
                guard t >= p.machine.statusAt else { break }
                let now = clock()
                p.retired = false
                p.endedAt = nil
                p.stickyEnd = false
                p.machine.touch(at: now)
                _ = p.machine.set(.idle(preview: nil), at: now)   // not .ended, so aging/cascade don't re-end the chain
                agents[pid] = p
            }
            parent = p.parentId
            depth += 1
        }
        return true
    }

    /// One past the highest ordinal held by a subagent under `root`.
    private func nextOrdinal(under root: AgentID) -> Int {
        (agents.values.filter { $0.parentId != nil && lineageRoot(of: $0.id) == root }.map(\.ordinal).max() ?? 0) + 1
    }

    /// Recomputes `id`'s shade from its ordinal and its immediate parent's shade, then its children's, so the result
    /// depends only on the final tree.
    private func refreshShade(of id: AgentID, depth: Int = 0, force: Bool = false) {
        guard depth < Constants.maxAgentDepth, var rec = agents[id], let parent = rec.parentId else { return }
        let parentShade = agents[parent]?.parentId != nil ? agents[parent]?.shade ?? 0 : 0
        let shade = HuePalette.shade(forOrdinal: rec.ordinal, avoiding: parentShade)
        guard force || shade != rec.shade else { return }
        rec.shade = shade
        agents[id] = rec
        for (childId, child) in agents where child.parentId == id { refreshShade(of: childId, depth: depth + 1) }
    }

    /// The main session at the top of `id`'s parent chain (`id` itself when it has no parent).
    private func lineageRoot(of id: AgentID) -> AgentID {
        var current = id, depth = 0
        while depth < Constants.maxAgentDepth, let parent = agents[current]?.parentId { current = parent; depth += 1 }
        return current
    }

    private func closeCommand(_ toolId: String, of agent: AgentID, at t: Date) {
        guard openCommands[agent]?.removeValue(forKey: toolId) != nil else { return }
        recentCommandCompletions[agent] = max(recentCommandCompletions[agent] ?? t, t)
    }

    private func closeCommands(of agent: AgentID, at t: Date) {
        guard let open = openCommands.removeValue(forKey: agent), !open.isEmpty else { return }
        recentCommandCompletions[agent] = max(recentCommandCompletions[agent] ?? t, t)
    }

    /// `sticky`: the agent finished by itself (own turn end, hand-back, interruption or task notification); only a resume revives it.
    private func endAgent(_ id: AgentID, at t: Date, sticky: Bool = false) {
        guard var rec = agents[id] else { return }
        if rec.endedAt != nil || rec.retired {
            if sticky, !rec.stickyEnd { rec.stickyEnd = true; rec.machine.end(at: t); agents[id] = rec }
            return
        }
        closeCommands(of: id, at: t)
        rec.machine.end(at: t)
        rec.endedAt = clock()   // linger is measured on the store clock, not transcript time
        rec.stickyEnd = sticky
        agents[id] = rec
        for (childId, child) in agents where child.parentId == id { endAgent(childId, at: t) }
    }

    // MARK: - Aging and snapshots

    public func runAging() {
        let now = clock()
        for (id, var rec) in agents where rec.endedAt == nil {
            guard case .main = rec.kind else { continue }
            guard rec.machine.lastActivity != .distantPast else { continue }   // no events yet: nothing to age from
            rec.machine.age(now: now, window: Constants.activeWindow)
            if rec.machine.status == .ended {
                agents[id] = rec
                endAgent(id, at: now)
            }
        }
        for (id, var rec) in agents where !rec.retired {
            if let endedAt = rec.endedAt, now.timeIntervalSince(endedAt) > Constants.endedLinger {
                rec.retired = true
                agents[id] = rec
            }
        }
    }

    public func snapshot() -> StoreSnapshot {
        resolveDiskChanges(now: clock())
        runAging()
        let list = agents.values
            .filter { !$0.retired }
            .sorted { ($0.firstSeen, $0.id.raw) < ($1.firstSeen, $1.id.raw) }
            .map { r in
                AgentSnapshot(id: r.id, kind: r.kind, title: r.title, status: r.machine.status, hueIndex: r.hueIndex,
                              branch: r.branch, worktree: r.worktree, firstSeen: r.firstSeen,
                              lastActivity: r.machine.lastActivity, endedAt: r.endedAt, touchCount: r.touchCount,
                              lastCommandLabel: r.lastCommandLabel, lastMilestone: r.lastMilestone,
                              model: r.model ?? r.metaModel,
                              context: r.contextTokens.map { ContextUsage(tokens: TokenFormat.quantise($0), window: r.window) },
                              tokens: r.lastUsage == nil ? nil : TokenTotals(input: TokenFormat.quantise(r.inputTotal), output: TokenFormat.quantise(r.outputTotal)), shade: r.shade)
            }
        let now = clock()
        lastFileTouch = lastFileTouch.filter { now.timeIntervalSince($0.value) <= Constants.focusActiveWindow }
        return StoreSnapshot(agents: list, recentTouches: touches, recentCommands: commands, hookEventsSeenAt: hookEventsSeenAt, skippedLines: skippedLines, activeFiles: lastFileTouch)
    }

    // MARK: - Helpers

    /// Totals count each message id once (a response split across records repeats the id, and the last repeat carries the full
    /// output count); the context size, model and window follow the newest record by timestamp, like status. A record without a
    /// timestamp only feeds the totals. A record without a model keeps the previous one.
    private func applyUsage(messageID: String, model: String?, counts: (input: Int, output: Int, cacheRead: Int, cacheCreate: Int),
                            at stamp: Date?, to rec: inout AgentRecord) {
        let cap = Constants.tokenCountCap
        func clamp(_ n: Int) -> Int { min(max(n, 0), cap) }
        let input = clamp(counts.input) + clamp(counts.cacheRead) + clamp(counts.cacheCreate)
        let output = clamp(counts.output)
        if let last = rec.lastUsage, last.messageID == messageID {
            rec.inputTotal = max(0, rec.inputTotal - last.input)
            rec.outputTotal = max(0, rec.outputTotal - last.output)
        }
        rec.inputTotal = Self.saturatingAdd(rec.inputTotal, input)
        rec.outputTotal = Self.saturatingAdd(rec.outputTotal, output)
        rec.lastUsage = UsageContribution(messageID: messageID, input: input, output: output)
        guard let stamp, stamp >= rec.contextAt else { return }
        rec.contextTokens = input
        rec.contextAt = stamp
        var base = rec.window
        if let model, model != rec.model || base == nil {
            rec.model = model
            base = ContextWindow.lookup(model: model)
        }
        rec.window = base.map { ContextWindow.fitting(observed: input, base: $0) }
    }

    private static func saturatingAdd(_ a: Int, _ b: Int) -> Int {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? Int.max : sum
    }

    /// Credits settled disk changes to the one agent whose command was running at the time.
    private func resolveDiskChanges(now: Date) {
        let ready = pendingDiskChanges.filter { now.timeIntervalSince($0.at) >= Constants.diskAttributionDelay }
        guard !ready.isEmpty else { return }
        pendingDiskChanges.removeAll { now.timeIntervalSince($0.at) >= Constants.diskAttributionDelay }
        for change in ready {
            let t = change.at
            var candidates = Set<AgentID>()
            for (agent, open) in openCommands where open.values.contains(where: { $0 <= t.addingTimeInterval(Constants.diskAttributionSlack) }) {
                candidates.insert(agent)
            }
            for (agent, done) in recentCommandCompletions where done >= t.addingTimeInterval(-Constants.diskAttributionSlack) {
                candidates.insert(agent)
            }
            candidates = candidates.filter { id in
                guard let rec = agents[id] else { return false }
                return rec.endedAt == nil && !rec.retired && rec.machine.status != .ended
            }
            guard candidates.count == 1, let agent = candidates.first, var rec = agents[agent] else { continue }
            let worktree: String? = { if case .worktree(let n) = change.origin { return n } else { return nil } }()
            for path in change.paths {
                let echoed = touches.contains { $0.path == path && abs($0.at.timeIntervalSince(t)) <= Constants.touchDedupeWindow }
                    || openFileWrites.values.contains(path)
                    || recentFileWriteCompletions[path].map { abs($0.timeIntervalSince(t)) <= Constants.touchDedupeWindow } ?? false
                if echoed { continue }
                record(path: path, worktree: worktree, kind: .write, scope: .file, source: .disk, at: t, for: &rec)
            }
            agents[agent] = rec
        }
    }

    /// Appends a touch for `rec`, bumps its count and trims the ring.
    private func record(path: RepoPath, worktree: String?, kind: TouchKind, scope: TouchScope, source: TouchSource, at t: Date, for rec: inout AgentRecord) {
        touches.append(Touch(seq: nextSeq, agent: rec.id, path: path, worktree: worktree, kind: kind, scope: scope, source: source,
                             at: t, hueIndex: rec.hueIndex, shade: rec.shade, agentTitle: rec.title))
        nextSeq += 1
        rec.touchCount += 1
        if scope == .file { lastFileTouch[path] = max(lastFileTouch[path] ?? .distantPast, t) }
        if touches.count > Constants.recentTouchLimit { touches.removeFirst(touches.count - Constants.recentTouchLimit) }
    }

    /// Folds an absolute path and records it. The root is kept only for directory touches. `mustExist`: drop the touch
    /// unless the path is on disk under its checkout, so a read of a missing file (`cat a.toml 2>/dev/null`) adds no node.
    @discardableResult
    private func recordFolded(absolute: String, kind: TouchKind, scope: TouchScope, source: TouchSource, at t: Date,
                              for rec: inout AgentRecord, mustExist: Bool = false) -> FoldedPath? {
        guard let folded = folder.fold(absolute) else { return nil }
        if folded.path.isRoot, scope == .file { return nil }
        if mustExist, !existsOnDisk(folded, scope: scope) { return nil }
        record(path: folded.path, worktree: folded.worktree, kind: kind, scope: scope, source: source, at: t, for: &rec)
        return folded
    }

    /// A file-scope touch needs a file; a directory-scope one accepts a directory or a file (a search of one file).
    private func existsOnDisk(_ folded: FoldedPath, scope: TouchScope) -> Bool {
        let origin: Origin = folded.worktree.map { .worktree($0) } ?? .main
        let root = folder.rootPath(of: origin)
        let full = folded.path.isRoot ? root : root + "/" + folded.path.string
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory) else { return false }
        return scope == .directory || !isDirectory.boolValue
    }

    /// Cuts at `max` characters, backing up to the previous space unless the cut already lands on a word boundary.
    static func truncateOnWord(_ s: String, max: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard flat.count > max else { return flat }
        let cut = flat.prefix(max)
        if flat[flat.index(flat.startIndex, offsetBy: max)] == " " { return String(cut) }
        if let space = cut.lastIndex(of: " ") { return String(cut[..<space]) }
        return String(cut)
    }
}

extension SessionStore.AgentRecord {
    var parentId: AgentID? { if case .subagent(let p, _, _, _) = kind { return p } else { return nil } }
    var metaModel: String? { if case .subagent(_, _, _, let m) = kind { return m } else { return nil } }
}
