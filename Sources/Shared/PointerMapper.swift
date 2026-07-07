import Foundation

public enum PointerDirection: String, CaseIterable, Equatable, Sendable {
    case up
    case down
    case left
    case right
}

public struct PointerMapper: Equatable, Sendable {
    public static let defaultStep = 48.0
    public static let minimumSensitivity = 0.25
    public static let maximumSensitivity = 3.0
    public static let scrollGain = 5.0

    public let sensitivity: Double

    public init(sensitivity: Double) {
        self.sensitivity = min(
            Self.maximumSensitivity,
            max(Self.minimumSensitivity, sensitivity)
        )
    }

    public func dragDelta(dx: Double, dy: Double) -> PointerDelta {
        PointerDelta(dx: dx * sensitivity, dy: dy * sensitivity)
    }

    /// Pointer delta with an Apple-trackpad-like acceleration curve: slow
    /// finger movement is slightly damped for precision, fast movement is
    /// amplified so the pointer crosses the screen without repeated swipes.
    public func acceleratedDragDelta(dx: Double, dy: Double) -> PointerDelta {
        let speed = (dx * dx + dy * dy).squareRoot()
        let factor = Self.accelerationFactor(forSpeed: speed)
        return PointerDelta(dx: dx * sensitivity * factor, dy: dy * sensitivity * factor)
    }

    /// Smoothstep gain curve over the per-event movement magnitude (points
    /// per gesture event). Continuous and monotonically non-decreasing.
    public static func accelerationFactor(forSpeed speed: Double) -> Double {
        let minFactor = 0.72
        let maxFactor = 1.9
        let slowSpeed = 1.2
        let fastSpeed = 16.0

        guard speed > slowSpeed else {
            return minFactor
        }
        guard speed < fastSpeed else {
            return maxFactor
        }

        let progress = (speed - slowSpeed) / (fastSpeed - slowSpeed)
        let smoothed = progress * progress * (3 - 2 * progress)
        return minFactor + (maxFactor - minFactor) * smoothed
    }

    public func scrollDelta(dx: Double, dy: Double) -> PointerDelta {
        PointerDelta(
            dx: dx * sensitivity * Self.scrollGain,
            dy: dy * sensitivity * Self.scrollGain
        )
    }

    public func testButtonDelta(_ direction: PointerDirection) -> PointerDelta {
        let amount = Self.defaultStep * sensitivity

        switch direction {
        case .up:
            return PointerDelta(dx: 0, dy: -amount)
        case .down:
            return PointerDelta(dx: 0, dy: amount)
        case .left:
            return PointerDelta(dx: -amount, dy: 0)
        case .right:
            return PointerDelta(dx: amount, dy: 0)
        }
    }
}
