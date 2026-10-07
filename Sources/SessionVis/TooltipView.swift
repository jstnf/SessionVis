import SwiftUI

struct TooltipView: View {
    let model: AppModel
    @State private var size: CGSize = .zero

    var body: some View {
        let lines = model.tooltipLines()
        if let p = model.hoverPoint, !lines.isEmpty {
            GeometryReader { geo in
                let x = size == .zero ? p.x + 14 : max(8, min(p.x + 14, geo.size.width - size.width - 8))
                let y = size == .zero ? p.y + 18 : max(8, min(p.y + 18, geo.size.height - size.height - 8))
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .font(.system(size: i == 0 ? 11 : 10, design: .monospaced))
                            .foregroundStyle(i == 0 ? Palette.text : Palette.textSecondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.edge, lineWidth: 1))
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                .position(x: x + size.width / 2, y: y + size.height / 2)
            }
            .allowsHitTesting(false)
        }
    }
}
