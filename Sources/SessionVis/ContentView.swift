import SwiftUI
import SessionVisCore

struct ContentView: View {
    let model: AppModel

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            SceneView(model: model)
            InputCaptureView(onScroll: model.handleScroll,
                             onMagnify: model.handleMagnify,
                             onMove: model.handleMove,
                             onClick: model.handleClick)
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
            if let message = model.errorMessage {
                VStack {
                    Spacer()
                    Text(message)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.text)
                        .padding(10)
                        .background(Color(hex: 0xF0605A).opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: 0xF0605A).opacity(0.6), lineWidth: 1))
                        .padding(.bottom, 16)
                }
            }
        }
        .navigationTitle(model.windowTitle)
        .navigationSubtitle(model.windowSubtitle)
    }
}
