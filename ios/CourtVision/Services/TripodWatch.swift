import CoreMotion
import Foundation

/// Debounced "the camera physically moved" decision from gyro magnitude:
/// one event per spike, a cooldown between events, noise never fires.
struct BumpDetector {
    /// Rotation rate (rad/s) that means the tripod was touched, not sensor
    /// noise. ponytail: single threshold; calibrate on device if gyms differ.
    var threshold: Double = 0.15
    /// Seconds after an event before a new spike counts as a new event.
    var cooldown: Double = 2.0
    private var lastEventAt: Double = -.infinity

    mutating func feed(rate: Double, at t: Double) -> Bool {
        guard rate >= threshold, t - lastEventAt >= cooldown else { return false }
        lastEventAt = t
        return true
    }
}

/// Gyro watcher for the fixed-camera contract: the tripod must not move.
/// Fires `onBump` (main queue) when it does — the engine invalidates the
/// rims and court fit and the UI asks for a re-tap. No gyro (Mac Catalyst,
/// simulator) → inert.
final class TripodWatch {
    private let manager = CMMotionManager()
    private var detector = BumpDetector()

    func start(onBump: @escaping () -> Void) {
        guard manager.isGyroAvailable else { return }
        manager.gyroUpdateInterval = 0.1
        manager.startGyroUpdates(to: .main) { [weak self] data, _ in
            guard let self, let r = data?.rotationRate else { return }
            let magnitude = (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()
            if self.detector.feed(rate: magnitude, at: data!.timestamp) { onBump() }
        }
    }

    func stop() { manager.stopGyroUpdates() }
}
