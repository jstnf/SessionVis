import Foundation

/// Owns every agent's state.
public actor SessionStore {
    struct AgentRecord {
        let id: AgentID
        let sessionId: String
        var kind: AgentKind
        var aiTitle: String?
        var firstPrompt: String?
        var machine: StatusMachine
        var hueIndex: Int
        var branch: String?
        var worktree: String?
        var cwd: String?
        let firstSeen: Date
        var endedAt: Date?
        var retired = false
        var touchCount = 0
        var metaToolUseId: String?
        /// Ended by its own hand-back/turn end or by a task notification: only a resume (new user prompt) revives it.
        var stickyEnd = false

        var title: String {
            if case .subagent(_, let description, _, _) = kind { return description }
            if let aiTitle, !aiTitle.isEmpty { return aiTitle }
            if let firstPrompt { return SessionStore.truncateOnWord(firstPrompt, max: 60) }
            return String(sessionId.prefix(8))
        }
    }

    private let folder: PathFolder
    private let clock: @Sendable () -> Date
    private var agents: [AgentID: AgentRecord] = [:]
    private var toolUseOwner: [String: AgentID] = [:]        // tool_use id → agent that issued it
    private var subagentByToolUseId: [String: AgentID] = [:]  // meta.toolUseId → subagent
    private var touches: [Touch] = []
    private var nextSeq: UInt64 = 1
    private var nextHue = 0
    private var hookEventsSeenAt: Date?
    private var skippedLines = 0

    public init(folder: PathFolder, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.folder = folder
        self.clock = clock
    }

    // MARK: - Apply

    public func apply(_ event: SourceEvent) {
        switch event {
        case .sessionAppeared(let sid, _):
            _ = ensureMain(sid)
        case .subagentAppeared(let sid, let aid, let meta):
            ensureSubagent(sessionId: sid, agentId: aid, meta: meta)
        case .line(let sid, let aid, let line):
            applyLine(sessionId: sid, agentId: aid, line: line)
        case .hook(let hook):
            applyHook(hook)
        case .diagnostics(let skipped):
            skippedLines = skipped
        case .initialLoadComplete:
            break
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

    private func ensureSubagent(sessionId: String, agentId: String, meta: SubagentMeta?, at t: Date? = nil) {
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
            agents[id] = existing
        } else {
            let now = clock()
            agents[id] = AgentRecord(id: id, sessionId: sessionId, kind: kind, machine: StatusMachine(at: .distantPast),
                                     hueIndex: agents[parent]?.hueIndex ?? 0, firstSeen: now, metaToolUseId: meta?.toolUseId)
        }
        if let tid = meta?.toolUseId { subagentByToolUseId[tid] = id }
    }

    private func applyLine(sessionId: String, agentId: String?, line: TranscriptLine) {
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
        case .toolUse(let toolId, let name, let filePath, _, _):
            toolUseOwner[toolId] = id
            if let child = subagentByToolUseId[toolId], var childRec = agents[child], child != id {
                if case .subagent(_, let d, let at, let m) = childRec.kind {
                    childRec.kind = .subagent(parent: id, description: d, agentType: at, model: m)
                    childRec.hueIndex = rec.hueIndex
                    agents[child] = childRec
                }
            }
            if let kind = TouchKind.forTool(name), let filePath {
                let absolute = filePath.hasPrefix("/") ? filePath : (rec.cwd ?? folder.root) + "/" + filePath
                if let folded = folder.fold(absolute), !folded.path.isRoot {
                    touches.append(Touch(seq: nextSeq, agent: id, path: folded.path, worktree: folded.worktree, kind: kind, at: t, hueIndex: rec.hueIndex, agentTitle: rec.title))
                    nextSeq += 1
                    rec.touchCount += 1
                    if touches.count > Constants.recentTouchLimit { touches.removeFirst(touches.count - Constants.recentTouchLimit) }
                }
            }
        case .toolResult(let toolId):
            if let child = subagentByToolUseId[toolId] { endAgent(child, at: t) }
        case .assistantText, .turnEnded, .interrupted, .taskNotification:
            break
        }

        if active { rec.machine.apply(line.event, at: t) }
        agents[id] = rec
        if case .taskNotification(let taskId, _) = line.event, AgentID(taskId) != id, agents[AgentID(taskId)] != nil {
            endAgent(AgentID(taskId), at: t, sticky: true)
        }
        guard active, case .subagent = rec.kind else { return }
        if line.event == .turnEnded, rec.machine.pending.isEmpty { endAgent(id, at: t, sticky: true) }
        if case .toolUse(_, let name, _, _, _) = line.event, name == "SubagentHandback" { endAgent(id, at: t, sticky: true) }
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

    /// `sticky`: the agent finished by itself (own turn end, hand-back, interruption or task notification); only a resume revives it.
    private func endAgent(_ id: AgentID, at t: Date, sticky: Bool = false) {
        guard var rec = agents[id] else { return }
        if rec.endedAt != nil || rec.retired {
            if sticky, !rec.stickyEnd { rec.stickyEnd = true; rec.machine.end(at: t); agents[id] = rec }
            return
        }
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
        runAging()
        let list = agents.values
            .filter { !$0.retired }
            .sorted { ($0.firstSeen, $0.id.raw) < ($1.firstSeen, $1.id.raw) }
            .map { r in
                AgentSnapshot(id: r.id, kind: r.kind, title: r.title, status: r.machine.status, hueIndex: r.hueIndex,
                              branch: r.branch, worktree: r.worktree, firstSeen: r.firstSeen,
                              lastActivity: r.machine.lastActivity, endedAt: r.endedAt, touchCount: r.touchCount)
            }
        return StoreSnapshot(agents: list, recentTouches: touches, hookEventsSeenAt: hookEventsSeenAt, skippedLines: skippedLines)
    }

    // MARK: - Helpers

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
}
