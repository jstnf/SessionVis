import SwiftUI
import SessionVisCore

/// One tab's scene: canvas, input capture, tooltip, session list and the message banner.
struct SessionView: View {
    let model: RepoSession
    let workspace: Workspace

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            SceneView(model: model)
            InputCaptureView(onScroll: model.handleScroll,
                             onMagnify: model.handleMagnify,
                             onMove: model.handleMove,
                             onClick: model.handleClick,
                             onKey: model.handleKey)
            TooltipView(model: model)
            GeometryReader { geo in
                VStack {
                    HStack {
                        OverlayListView(model: model, availableHeight: geo.size.height)
                        Spacer()
                    }
                    Spacer()
                }
                .padding(12)
            }
            if let message = model.errorMessage ?? workspace.launchMessage {
                VStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Text(message)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.text)
                        if model.directoryMissing {
                            HStack {
                                Button("Choose New Folder…") { workspace.presentOpenPanel(replacing: model.id) }
                                Button("Remove Tab") { workspace.closeTab(model.id) }
                            }
                        }
                    }
                    .padding(10)
                    .background(Palette.danger.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.danger.opacity(0.6), lineWidth: 1))
                    .padding(.bottom, 16)
                }
            }
        }
    }
}
