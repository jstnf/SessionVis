import SwiftUI
import SessionVisCore

/// Settings section: the hidden-file rules for the watched directory, a field to add one, and suggested suffixes.
struct HiddenFilesSection: View {
    let model: AppModel
    @State private var draft = ""
    @State private var message: String?

    var body: some View {
        Section("Hidden files") {
            Text("A name pattern such as *.md or Generated hides matching files and directories at any depth. A pattern with a slash starts at the repository root, and ** spans directories. Rules apply to this directory only.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(model.filter.rules) { rule in
                HStack {
                    Toggle(rule.pattern, isOn: Binding(get: { rule.isEnabled }, set: { model.setRuleEnabled($0, for: rule.pattern) }))
                        .toggleStyle(.checkbox).labelsHidden()
                    Text(rule.pattern).font(.system(.body, design: .monospaced))
                    Spacer()
                    Button { model.removeRule(rule.pattern) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Remove this rule").accessibilityLabel("Remove rule")
                }
            }
            HStack {
                TextField("Pattern", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(add)
                    .onChange(of: draft) { message = nil }
                Button("Add", action: add)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(Palette.danger)
            }
            if !model.suggestions.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(model.suggestions) { s in
                        Button("\(s.pattern) · \(s.count)") { _ = model.addRule(s.pattern) }
                            .buttonStyle(.bordered).controlSize(.small)
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
            }
        }
        .onAppear { model.refreshSuggestions() }
    }

    private func add() {
        switch model.addRule(draft) {
        case nil: draft = ""; message = nil
        case .invalid?: message = "Not a valid pattern."
        case .duplicate?: message = "That pattern is already a rule."
        }
    }
}

/// Lays children out left to right and wraps to a new row when the width runs out.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal: proposal, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(proposal: proposal, subviews: subviews)
        for (i, origin) in rows.origins.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (origins: [CGPoint], width: CGFloat, height: CGFloat) {
        let maxWidth = proposal.width ?? .infinity
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            width = max(width, x - spacing)
        }
        return (origins, width, y + rowHeight)
    }
}
