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
            if model.listCollapsed {
                collapsedDots
            } else if model.mains.isEmpty {
                if !model.isLoading { emptyText }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.mains) { main in
                            SessionRow(agent: main, subagentCount: subagents(of: main).count,
                                       selected: model.selectedAgent == main.id) { model.select(main.id) }
                            ForEach(subagents(of: main)) { sub in
                                SubagentRow(agent: sub, selected: model.selectedAgent == sub.id) { model.select(sub.id) }
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
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5).fill(Palette.hue(agent.hueIndex)).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(Palette.status(agent.status)).frame(width: 8, height: 8)
                    Text(agent.title).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.text).lineLimit(1).truncationMode(.tail)
                }
                Text(statusLine).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.status(agent.status))
                if case .waiting(let preview) = agent.status {
                    Text(preview).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.textSecondary).lineLimit(2)
                }
            }
            .padding(.leading, 6)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5).padding(.trailing, 6)
        .background(selected ? Palette.rowHighlight : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
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
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Rectangle().fill(Palette.edge).frame(width: 1).padding(.leading, 12)
            Circle().fill(Palette.tint(agent.hueIndex)).frame(width: 6, height: 6)
            Text(agent.title).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.textSecondary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Text(agent.status.word).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.status(agent.status))
        }
        .padding(.vertical, 2).padding(.trailing, 6)
        .background(selected ? Palette.rowHighlight : .clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .opacity(agent.status.isEnded ? 0.4 : 1)
        .animation(.easeOut(duration: Constants.endedLinger), value: agent.status.isEnded)
    }
}
