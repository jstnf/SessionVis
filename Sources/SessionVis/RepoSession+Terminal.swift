import AppKit
import SessionVisCore

extension RepoSession {
    /// A main session, or a subagent of one (it opens its parent's terminal). An ended session still qualifies: an
    /// idle one may still be open in a tab, and a dead process is reported as not found. Replay sessions have no process.
    func canOpenTerminal(_ agent: AgentSnapshot) -> Bool {
        !isReplay && mainSession(of: agent) != nil
    }

    var canOpenSelectedTerminal: Bool {
        guard let id = selectedAgent, let agent = snapshot.agents.first(where: { $0.id == id }) else { return false }
        return canOpenTerminal(agent)
    }

    /// Brings the terminal tab running the agent's main session to the front. One attempt at a time, held until the
    /// attempt has finished even if the directory was closed meanwhile; a failure is shown under the session list, and
    /// starting or succeeding clears any earlier message.
    func openTerminal(for id: AgentID) {
        guard terminalTask == nil,
              let agent = snapshot.agents.first(where: { $0.id == id }),
              let main = mainSession(of: agent), canOpenTerminal(agent) else { return }
        let sessionId = main.id.raw
        let running = Self.runningTerminals()
        clearTerminalMessage()
        terminalTask = Task(priority: .userInitiated) { [weak self] in
            let outcome = await TerminalOpener.open(sessionId: sessionId, running: running)
            guard let self else { return }
            self.terminalTask = nil
            guard !Task.isCancelled else { return }
            switch outcome {
            case .failed(let failure): self.showTerminalMessage(failure.message)
            case .opened, .cancelled: self.clearTerminalMessage()
            }
        }
    }

    /// The terminal apps running right now, iTerm2 before Terminal. An app that is not running is never scripted.
    static func runningTerminals() -> [TerminalApp] {
        TerminalApp.allCases.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleIdentifier).isEmpty }
    }

    func clearTerminalMessage() {
        terminalMessageTask?.cancel(); terminalMessageTask = nil
        terminalMessage = nil
    }

    func showTerminalMessage(_ message: String) {
        terminalMessage = message
        terminalMessageTask?.cancel()
        terminalMessageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Constants.terminalMessageDuration))
            guard !Task.isCancelled else { return }
            self?.terminalMessage = nil
        }
    }

    private func mainSession(of agent: AgentSnapshot) -> AgentSnapshot? {
        guard let parent = agent.parent else { return agent }
        return snapshot.agents.first { $0.id == parent }
    }
}
