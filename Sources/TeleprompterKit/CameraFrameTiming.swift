import AVFoundation
import CoreMedia

/// Frame durations are exact rational numbers, not rounded reciprocals of Double FPS.
/// A rounded duration just below a camera's lower bound causes an Obj-C exception.
public struct FrameDurationBounds: Sendable {
    public let shortest: CMTime
    public let longest: CMTime

    public init(shortest: CMTime, longest: CMTime) {
        self.shortest = shortest; self.longest = longest
    }

    public init(_ range: AVFrameRateRange) {
        self.init(shortest: range.minFrameDuration, longest: range.maxFrameDuration)
    }

    public var isValid: Bool {
        Self.isPositiveDuration(shortest) && Self.isPositiveDuration(longest) && CMTimeCompare(shortest, longest) <= 0
    }

    public func contains(_ duration: CMTime) -> Bool {
        isValid && Self.isPositiveDuration(duration) &&
            CMTimeCompare(duration, shortest) >= 0 && CMTimeCompare(duration, longest) <= 0
    }

    private static func isPositiveDuration(_ time: CMTime) -> Bool {
        time.isNumeric && time.timescale > 0 && time.value > 0 && time.epoch == 0
    }
}

public struct CameraFrameTiming: Sendable {
    public let duration: CMTime
    public var framesPerSecond: Double { 1 / duration.seconds }

    /// Maximum advertised rate plus conventional lower choices, using exact durations
    /// and exact range membership. Never round an out-of-range value back into a range.
    public static func options(in ranges: [FrameDurationBounds]) -> [Self] {
        let valid = ranges.filter(\.isValid)
        guard let fastest = valid.map(\.shortest).min(by: { CMTimeCompare($0, $1) < 0 }) else { return [] }
        let choices = [fastest] + [60, 30, 24].map { CMTime(value: 1, timescale: Int32($0)) }
        var result: [Self] = []
        for duration in choices where valid.contains(where: { $0.contains(duration) }) {
            guard !result.contains(where: { CMTimeCompare($0.duration, duration) == 0 }) else { continue }
            result.append(Self(duration: duration))
        }
        return result.sorted { CMTimeCompare($0.duration, $1.duration) < 0 }
    }
}
