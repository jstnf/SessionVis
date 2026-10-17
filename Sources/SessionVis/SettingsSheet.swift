import SwiftUI
import AppKit
import SessionVisCore

/// The settings sheet: the selected tab's directory and rules, the optional hook snippet and how to install it.
struct SettingsSheet: View {
    let workspace: Workspace

    var body: some View {
        Form {
            Section("Directory") {
                if let model = workspace.selected {
                    LabeledContent("Watching", value: model.directory ?? "—")
                    LabeledContent("Claude projects", value: workspace.projectsRoot.path)
                    LabeledContent("Worktrees") {
                        if model.worktrees.isEmpty {
                            Text("none")
                        } else {
                            VStack(alignment: .trailing, spacing: 2) {
                                ForEach(model.worktrees, id: \.path) { wt in
                                    Text("\(wt.name) · \(wt.path)").textSelection(.enabled)
                                }
                            }
                        }
                    }
                } else {
                    Text("No tab selected").foregroundStyle(.secondary)
                }
            }
            if let model = workspace.selected {
                HiddenFilesSection(model: model).id(model.id)
            }
            Section("Hook (optional)") {
                Text("Add this entry to the `hooks` array of each of these events in ~/.claude/settings.json: \(HookSnippet.events.joined(separator: ", ")). It reports permission prompts and session lifecycle exactly; the app works without it.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("The spool holds raw hook payloads (prompts, tool inputs and outputs) only while SessionVis runs, under ~/Library/Application Support/SessionVis/hooks. Every tab reads the same spool; each payload goes to the tabs whose directory it belongs to.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(alignment: .top) {
                    Text(HookSnippet.json)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(HookSnippet.json, forType: .string)
                    }
                }
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    hookStatus(now: ctx.date)
                }
                LabeledContent("In settings.json", value: workspace.hookInstalled ? "command present" : "not found")
            }
            Section("Diagnostics") {
                if let model = workspace.selected {
                    LabeledContent("Sessions tracked", value: "\(model.mains.count) (+\(model.subagentCount) subagents)")
                    LabeledContent("Tree files", value: "\(model.treeFileCount)\(model.hiddenFileCount > 0 ? " (\(model.hiddenFileCount) hidden)" : "")\(model.treeTruncated ? " (truncated)" : "")")
                    LabeledContent("Skipped transcript lines", value: "\(model.snapshot.skippedLines)")
                } else {
                    Text("No tab selected").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 620)
    }

    @ViewBuilder
    private func hookStatus(now: Date) -> some View {
        if let seen = workspace.hookEventsSeenAt {
            let ago = max(0, Int(now.timeIntervalSince(seen)))
            Label("Receiving hook events · last \(ago) s ago", systemImage: "dot.radiowaves.left.and.right")
                .foregroundStyle(Palette.status(.idle(preview: nil)))
        } else {
            Label("No hook events received", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        }
    }
}
