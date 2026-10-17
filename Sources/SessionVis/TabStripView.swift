import SwiftUI
import SessionVisCore

/// The row of tabs above the scene: one per watched directory, with its activity badge and a close button on hover.
struct TabStripView: View {
    let workspace: Workspace

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(workspace.tabs.entries) { entry in
                    TabButton(entry: entry, session: workspace.sessions[entry.id], selected: entry.id == workspace.tabs.selectedID,
                              onSelect: { workspace.select(entry.id) }, onClose: { workspace.closeTab(entry.id) })
                }
                Button { workspace.presentOpenPanel(replacing: nil) } label: {
                    Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, 8)
                .help("New tab (⌘T)")
                .accessibilityLabel("New tab")
            }
            .padding(.horizontal, 6)
        }
        .frame(height: Constants.tabStripHeight)
        .background(Palette.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.edge).frame(height: 1) }
    }
}

private struct TabButton: View {
    let entry: TabEntry
    let session: RepoSession?
    let selected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Palette.hue(entry.hueIndex)).frame(width: 6, height: 6)
            Text(entry.isReplay ? "\(entry.name) · replay" : entry.name)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(selected ? Palette.text : Palette.textSecondary)
                .lineLimit(1)
            if session?.directoryMissing == true {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.status(.working))
                    .help("Directory not found")
            } else if let activity = session?.activity, !activity.isQuiet {
                ActivityBadge(activity: activity)
            }
            Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.textSecondary)
                .opacity(hovering ? 1 : 0)
                .help("Close tab (⌘W)")
                .accessibilityLabel("Close tab")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(selected ? Palette.rowHighlight : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .help(entry.directory)
    }
}

/// Working count in the working colour; waiting count in the waiting colour, pulsing.
private struct ActivityBadge: View {
    let activity: TabActivity

    var body: some View {
        HStack(spacing: 4) {
            if activity.working > 0 {
                Text("\(activity.working)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.status(.working))
            }
            if activity.waiting > 0 {
                TimelineView(.animation(minimumInterval: Constants.tabBadgePulseInterval)) { ctx in
                    let phase = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Constants.tabBadgePulsePeriod) / Constants.tabBadgePulsePeriod
                    Text("\(activity.waiting)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Palette.status(.waiting(preview: "")).opacity(Constants.tabBadgePulseFloor + Constants.tabBadgePulseDepth * abs(sin(phase * .pi))))
                }
            }
        }
    }
}
