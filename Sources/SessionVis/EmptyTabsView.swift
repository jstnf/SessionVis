import SwiftUI

/// What the window shows with no tab open.
struct EmptyTabsView: View {
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 12) {
            Text("Open a directory to begin")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Palette.text)
            Text("Each tab watches one directory's Claude Code sessions.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.textSecondary)
            Button("Open…") { workspace.presentOpenPanel(replacing: nil) }
                .keyboardShortcut(.defaultAction)
            if let message = workspace.launchMessage {
                Text(message)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.danger)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
