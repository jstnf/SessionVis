import SwiftUI
import AppKit
import SessionVisCore

/// The settings sheet: the optional hook snippet and how to install it.
struct SettingsSheet: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("Directory") {
                LabeledContent("Watching", value: model.directory ?? "—")
                LabeledContent("Claude projects", value: model.projectsRoot.path)
            }
            Section("Hook (optional)") {
                Text("Add this entry to the `hooks` array of each of these events in ~/.claude/settings.json: \(HookSnippet.events.joined(separator: ", ")). It reports permission prompts and session lifecycle exactly; the app works without it.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("The spool holds raw hook payloads (prompts, tool inputs and outputs) only while SessionVis runs, under ~/Library/Application Support/SessionVis/hooks.")
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
                LabeledContent("In settings.json", value: model.hookInstalled ? "command present" : "not found")
            }
            Section("Diagnostics") {
                LabeledContent("Sessions tracked", value: "\(model.mains.count) (+\(model.subagentCount) subagents)")
                LabeledContent("Tree files", value: "\(model.treeFileCount)\(model.treeTruncated ? " (truncated)" : "")")
                LabeledContent("Skipped transcript lines", value: "\(model.snapshot.skippedLines)")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 480)
    }

    @ViewBuilder
    private func hookStatus(now: Date) -> some View {
        if let seen = model.snapshot.hookEventsSeenAt {
            let ago = max(0, Int(now.timeIntervalSince(seen)))
            Label("Receiving hook events · last \(ago) s ago", systemImage: "dot.radiowaves.left.and.right")
                .foregroundStyle(Palette.status(.idle(preview: nil)))
        } else {
            Label("No hook events received", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        }
    }
}
