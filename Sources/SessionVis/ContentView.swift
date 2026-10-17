import SwiftUI
import SessionVisCore

/// The window: the selected tab's scene, or the empty prompt. The background alone ignores the safe area.
struct ContentView: View {
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            TabStripView(workspace: workspace)
            if let session = workspace.selected {
                SessionView(model: session, workspace: workspace)
                    .id(session.id)
            } else if workspace.selectedEntry != nil {
                ProgressView("Opening…")
                    .controlSize(.small)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyTabsView(workspace: workspace)
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle(workspace.selected?.windowTitle ?? "SessionVis")
        .navigationSubtitle(workspace.selected?.windowSubtitle ?? (workspace.selectedEntry == nil ? "Open a directory to begin" : ""))
        .focusedSceneValue(\.mainWorkspace, workspace)
    }
}
