import Foundation

public struct CaptureDeviceInfo: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let isContinuity: Bool
    public init(id: String, name: String, isContinuity: Bool = false) {
        self.id = id; self.name = name; self.isContinuity = isContinuity
    }
}

public struct RecordingProfile: Sendable, Identifiable, Hashable, Codable {
    public let id: String
    public let width: Int
    public let height: Int
    public let framesPerSecond: Double
    public let bitrate: Int
    public init(id: String, width: Int, height: Int, framesPerSecond: Double, bitrate: Int? = nil) {
        self.id = id; self.width = width; self.height = height; self.framesPerSecond = framesPerSecond
        self.bitrate = bitrate ?? Int(Double(width) * Double(height) * framesPerSecond * 0.18)
    }
    public var label: String { "\(width) × \(height) · \(framesPerSecond.formatted(.number.precision(.fractionLength(0...2)))) fps" }
    public var bytesPerMinute: Int64 { Int64((bitrate + 192_000) / 8 * 60) }
    public static func ranked(_ profiles: [Self]) -> [Self] {
        profiles.sorted {
            let left = Int64($0.width) * Int64($0.height), right = Int64($1.width) * Int64($1.height)
            if left != right { return left > right }
            if $0.framesPerSecond != $1.framesPerSecond { return $0.framesPerSecond > $1.framesPerSecond }
            return $0.id < $1.id
        }
    }
}

public enum PrompterMode: String, Codable, CaseIterable, Sendable {
    case speech = "Follow voice", timed = "Fixed speed", manual = "Manual"
}

public struct UserSettings: Codable, Sendable {
    public var fontSize = 28.0
    public var panelWidth = 560.0
    public var opacity = 0.94
    public var lineSpacing = 8.0
    public var wordsPerMinute = 140.0
    public var mode = PrompterMode.speech
    public var cameraID = ""
    public var microphoneID = ""
    public var profileID = ""
    public var shortcutKeyCodes: [String: UInt32] = ["record": 15, "pause": 35, "previous": 123, "next": 124]
    public init() {}
    public func sanitized() -> Self {
        var copy = self
        copy.fontSize = min(48, max(20, fontSize))
        copy.panelWidth = min(900, max(380, panelWidth))
        copy.opacity = min(1, max(0.45, opacity))
        copy.lineSpacing = min(20, max(2, lineSpacing))
        copy.wordsPerMinute = min(300, max(30, wordsPerMinute))
        return copy
    }
}

public struct SavedDraft: Codable, Sendable {
    public var version = 1
    public var text: String
    public var settings: UserSettings
    public init(text: String = "", settings: UserSettings = .init()) { self.text = text; self.settings = settings }
}

public enum TeleprompterError: LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let text): text } }
}
