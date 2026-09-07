import Testing
import Foundation
@testable import TeleprompterKit

private let profile = RecordingProfile(id: "fixture", width: 1552, height: 1552, framesPerSecond: 30)

@Test func runningSessionWithoutSamplesIsNotReady() {
    let state = CaptureStreamReadiness()
    #expect(throws: (any Error).self) { try state.validate(profile: profile, at: 1) }
}

@Test func stableFramesAndFreshAudioAreRequired() throws {
    var state = CaptureStreamReadiness()
    state.noteVideo(width: 1552, height: 1552, at: 1)
    state.noteAudio(at: 1)
    #expect(throws: (any Error).self) { try state.validate(profile: profile, at: 1) }
    state.noteVideo(width: 1552, height: 1552, at: 1.03)
    state.noteVideo(width: 1552, height: 1552, at: 1.06)
    try state.validate(profile: profile, at: 1.1)
    #expect(throws: (any Error).self) { try state.validate(profile: profile, at: 4) }
}

@Test func deliveredDimensionsMustMatchSelectedProfile() {
    var state = CaptureStreamReadiness()
    for _ in 0..<3 { state.noteVideo(width: 1280, height: 720, at: 1) }
    state.noteAudio(at: 1)
    do { try state.validate(profile: profile, at: 1); Issue.record("A mismatched output was declared ready") }
    catch { #expect(error.localizedDescription.contains("1280 × 720")) }
}

@Test func formatChangeRequiresNewStableFrames() throws {
    var state = CaptureStreamReadiness()
    for _ in 0..<3 { state.noteVideo(width: 1280, height: 720, at: 1) }
    state.noteVideo(width: 1552, height: 1552, at: 1.1)
    state.noteAudio(at: 1.1)
    #expect(throws: (any Error).self) { try state.validate(profile: profile, at: 1.1) }
    for _ in 0..<2 { state.noteVideo(width: 1552, height: 1552, at: 1.2) }
    try state.validate(profile: profile, at: 1.2)
}

@Test func freshVideoDoesNotHideMissingOrStaleAudio() {
    var state = CaptureStreamReadiness()
    for _ in 0..<3 { state.noteVideo(width: 1552, height: 1552, at: 10) }
    #expect(throws: (any Error).self) { try state.validate(profile: profile, at: 10) }
    state.noteAudio(at: 1)
    #expect(throws: (any Error).self) { try state.validate(profile: profile, at: 10) }
}
