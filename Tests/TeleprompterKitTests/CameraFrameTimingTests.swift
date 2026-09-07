import CoreMedia
import Testing
@testable import TeleprompterKit

@Test func macBookThirtyFPSBoundaryPreservesReportedRational() throws {
    // Observed on the user's MacBook Pro Camera, including the camera's native timescale.
    let reported = CMTime(value: 1_000_000, timescale: 30_000_000)
    let bounds = FrameDurationBounds(shortest: reported, longest: CMTime(value: 1_000_000, timescale: 15_000_000))
    let oldRounded = CMTime(seconds: 1 / 30.0, preferredTimescale: 1_000_000_000)
    #expect(!bounds.contains(oldRounded))
    #expect(CMTimeCompare(oldRounded, reported) < 0)
    let selected = try #require(CameraFrameTiming.options(in: [bounds]).first)
    #expect(selected.duration.value == reported.value)
    #expect(selected.duration.timescale == reported.timescale)
    #expect(bounds.contains(selected.duration))
    #expect(selected.framesPerSecond == 30)
}

@Test func fixedSixtyFPSDoesNotRoundBeyondEitherEndpoint() throws {
    let exact = CMTime(value: 1, timescale: 60)
    let bounds = FrameDurationBounds(shortest: exact, longest: exact)
    let rounded = CMTime(seconds: 1 / 60.0, preferredTimescale: 1_000_000_000)
    #expect(!bounds.contains(rounded))
    let options = CameraFrameTiming.options(in: [bounds])
    #expect(options.count == 1)
    #expect(CMTimeCompare(try #require(options.first).duration, exact) == 0)
}

@Test func fractionalFrameRatesPreserveNativeTiming() throws {
    for ticks: Int64 in [1001, 1_001_000] {
        let scale: Int32 = ticks == 1001 ? 30_000 : 30_000_000
        let exact = CMTime(value: ticks, timescale: scale)
        let bounds = FrameDurationBounds(shortest: exact, longest: exact)
        let selected = try #require(CameraFrameTiming.options(in: [bounds]).first)
        #expect(selected.duration.value == ticks)
        #expect(selected.duration.timescale == scale)
        #expect(abs(selected.framesPerSecond - 30_000.0 / 1001) < 1e-9)
    }
}

@Test func conventionalRatesStayInsideTheAdvertisedRange() {
    let bounds = FrameDurationBounds(shortest: CMTime(value: 1, timescale: 60), longest: CMTime(value: 1, timescale: 15))
    let options = CameraFrameTiming.options(in: [bounds])
    #expect(options.map(\.framesPerSecond) == [60, 30, 24])
    #expect(options.allSatisfy { bounds.contains($0.duration) })
}

@Test func disjointRangesDoNotInventAnUnsupportedRate() {
    let ranges = [FrameDurationBounds(shortest: CMTime(value: 1, timescale: 60), longest: CMTime(value: 1, timescale: 50)),
                  FrameDurationBounds(shortest: CMTime(value: 1, timescale: 25), longest: CMTime(value: 1, timescale: 20))]
    let options = CameraFrameTiming.options(in: ranges)
    #expect(options.map(\.framesPerSecond) == [60, 24])
}

@Test func invalidCameraTimingRangesProduceNoProfiles() {
    let normal = CMTime(value: 1, timescale: 30)
    let invalid = [FrameDurationBounds(shortest: .invalid, longest: normal),
                   FrameDurationBounds(shortest: .zero, longest: normal),
                   FrameDurationBounds(shortest: .positiveInfinity, longest: .positiveInfinity),
                   FrameDurationBounds(shortest: CMTime(value: 1, timescale: 15), longest: normal)]
    #expect(CameraFrameTiming.options(in: invalid).isEmpty)
}
