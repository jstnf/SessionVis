import SwiftUI
import SessionVisCore

/// Steps the simulation and draws it every frame.
struct SceneView: View {
    let model: RepoSession

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas(opaque: true, rendersAsynchronously: false) { ctx, size in
                model.box.setViewSize(size)
                model.box.step(to: timeline.date)
                SceneRenderer.draw(model.box.simulation, hover: model.hover, cache: model.box.cache, into: &ctx, size: size)
            }
        }
    }
}
