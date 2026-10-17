import Foundation

extension Simulation {
    /// Advances the scene through the time it went unstepped (a hidden tab keeps ingesting touches), so the effects
    /// that piled up at age zero expire instead of bursting out together on reveal. Capped at `catchUpMaxDuration`;
    /// tints expire by wall clock and are not affected.
    public mutating func catchUp(hiddenFor: TimeInterval, now: Date) {
        var remaining = min(hiddenFor, Constants.catchUpMaxDuration)
        while remaining > 0 {
            let dt = min(Constants.catchUpStep, remaining)
            update(dt: dt, now: now)
            remaining -= dt
        }
    }
}
