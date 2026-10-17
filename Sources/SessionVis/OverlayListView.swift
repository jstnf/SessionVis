import AppKit
import SwiftUI
import SessionVisCore

/// The floating session list. Floats top-left; rows stay in first-seen order.
struct OverlayListView: View {
    let model: AppModel
    var availableHeight: CGFloat = 600
    @State private var contentHeight: CGFloat = 0

    private var maxListHeight: CGFloat { max(40, availableHeight - 24 - 16 - 30) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let message = model.terminalMessage, !model.listCollapsed {
                Text(message)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
            }
            if model.listCollapsed {
                collapsedDots
            } else if model.mains.isEmpty {
                if !model.isLoading { emptyText }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.mains) { main in
                            SessionRow(agent: main, subagentCount: subagents(of: main).count,
                                       selected: model.selectedAgent == main.id,
                                       canOpenTerminal: model.canOpenTerminal(main),
                                       onTap: { model.select(main.id) },
                                       onOpenTerminal: { model.openTerminal(for: main.id) })
                            ForEach(subagents(of: main)) { sub in
                                SubagentRow(agent: sub, selected: model.selectedAgent == sub.id,
                                            canOpenTerminal: model.canOpenTerminal(sub),
                                            onTap: { model.select(sub.id) },
                                            onOpenTerminal: { model.openTerminal(for: sub.id) })
                            }
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .frame(height: min(contentHeight, maxListHeight))
            }
        }
        .padding(8)
        .frame(width: 260)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.edge, lineWidth: 1))
        .animation(.easeInOut(duration: 0.2), value: model.listCollapsed)
    }

    private func subagents(of main: AgentSnapshot) -> [AgentSnapshot] {
        model.snapshot.agents.filter { $0.parent == main.id }
    }

    private var header: some View {
        HStack {
            Text(model.isLoading ? "Sessions · loading…" : "Sessions · \(model.mains.count)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.text)
            Spacer()
            Button { model.listCollapsed.toggle() } label: {
                Image(systemName: model.listCollapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
            }
            .buttonStyle(.plain)
            .help(model.listCollapsed ? "Show session list (⌘L)" : "Collapse session list (⌘L)")
        }
        .padding(.bottom, model.listCollapsed ? 0 : 6)
    }

    private var collapsedDots: some View {
        HStack(spacing: 6) {
            ForEach(model.mains) { m in
                Circle().fill(Palette.status(m.status)).frame(width: 8, height: 8)
                    .help(m.title)
            }
        }
        .padding(.top, 6)
        .contentShape(Rectangle())
        .onTapGesture { model.listCollapsed = false }
    }

    private var emptyText: some View {
        Text("No live sessions for \(model.directory ?? "this directory"). Sessions appear here when a Claude Code session runs in this directory or one of its worktrees.")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SessionRow: View {
    let agent: AgentSnapshot
    let subagentCount: Int
    let selected: Bool
    let canOpenTerminal: Bool
    let onTap: () -> Void
    let onOpenTerminal: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5).fill(Palette.hue(agent.hueIndex)).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(Palette.status(agent.status)).frame(width: 8, height: 8)
                    Text(agent.title).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.text).lineLimit(1).truncationMode(.tail)
                    if selected { followGlyph }
                }
                Text(statusLine).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.status(agent.status))
                if let c = agent.context {
                    Text(c.line).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.contextText(fill: c.fill))
                }
                if case .working = agent.status, let cmd = agent.lastCommandLabel {
                    Text("$ \(cmd)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.textSecondary).lineLimit(1).truncationMode(.tail)
                }
                if let m = agent.lastMilestone {
                    Text(m.line).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.text).lineLimit(1).truncationMode(.tail)
                }
                if case .waiting(let preview) = agent.status {
                    Text(preview).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.textSecondary).lineLimit(2)
                }
            }
            .padding(.leading, 6)
            Spacer(minLength: 0)
            if canOpenTerminal && hovering {
                Button(action: onOpenTerminal) {
                    Image(systemName: "apple.terminal")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Open terminal")
                .accessibilityLabel("Open terminal")
            }
        }
        .padding(.vertical, 5).padding(.trailing, 6)
        .background(selected ? Palette.rowHighlight : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                if !selected { onTap() }   // the first click toggled; a double-click leaves the row selected
                if canOpenTerminal { onOpenTerminal() }
            } else { onTap() }
        }
        .opacity(agent.status.isEnded ? 0.4 : 1)
        .animation(.easeOut(duration: Constants.endedLinger), value: agent.status.isEnded)
    }

    private var statusLine: String {
        subagentCount > 0 ? "\(agent.status.word) · \(subagentCount) subagent\(subagentCount == 1 ? "" : "s")" : agent.status.word
    }
}

private struct SubagentRow: View {
    let agent: AgentSnapshot
    let selected: Bool
    let canOpenTerminal: Bool
    let onTap: () -> Void
    let onOpenTerminal: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Rectangle().fill(Palette.edge).frame(width: 1).padding(.leading, 12)
            Circle().fill(Palette.tint(agent.hueIndex)).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(agent.title).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.textSecondary).lineLimit(1).truncationMode(.tail)
                    if selected { followGlyph }
                }
                if let c = agent.context {
                    Text(c.line).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.contextText(fill: c.fill)).lineLimit(1)
                }
                if let milestone = agent.lastMilestone {
                    Text(milestone.line).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.textSecondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 4)
            Text(agent.status.word).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.status(agent.status)).lineLimit(1)
        }
        .padding(.vertical, 2).padding(.trailing, 6)
        .background(selected ? Palette.rowHighlight : .clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture {
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                if !selected { onTap() }   // the first click toggled; a double-click leaves the row selected
                if canOpenTerminal { onOpenTerminal() }
            } else { onTap() }
        }
        .opacity(agent.status.isEnded ? 0.4 : 1)
        .animation(.easeOut(duration: Constants.endedLinger), value: agent.status.isEnded)
    }
}

/// Marks the row of the agent the camera is following.
private var followGlyph: some View {
    Image(systemName: "scope")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(Palette.text)
        .help("Following · Esc stops")
}
