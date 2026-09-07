import Foundation

/// Tracks delivered samples, rather than treating a running session or preview as
/// proof that the recording outputs are usable. Confined to the capture queue.
public struct CaptureStreamReadiness: Sendable {
    public private(set) var lastVideoArrival = -Double.infinity
    public private(set) var lastAudioArrival = -Double.infinity
    public private(set) var width = 0
    public private(set) var height = 0
    private var stableFrames = 0

    public init() {}
    public mutating func noteVideo(width: Int, height: Int, at time: Double) {
        guard width > 0, height > 0, time.isFinite else { return }
        stableFrames = self.width == width && self.height == height ? min(3, stableFrames + 1) : 1
        self.width = width; self.height = height; lastVideoArrival = time
    }
    public mutating func noteAudio(at time: Double) { if time.isFinite { lastAudioArrival = time } }

    public func validate(profile: RecordingProfile, at now: Double) throws {
        guard now.isFinite, now >= lastVideoArrival, now - lastVideoArrival < 2, stableFrames >= 3 else {
            throw TeleprompterError.message("The camera is not delivering stable video frames yet. Wait a moment or prepare the camera again.")
        }
        guard width == profile.width, height == profile.height else {
            throw TeleprompterError.message("The camera is delivering \(width) × \(height), while the selected profile requires \(profile.width) × \(profile.height). Prepare the camera again or select another supported profile.")
        }
        guard now >= lastAudioArrival, now - lastAudioArrival < 2 else {
            throw TeleprompterError.message("The microphone is not delivering audio. Check the selected microphone and prepare the camera again.")
        }
    }
}
