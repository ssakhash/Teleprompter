import AVFoundation
import Foundation
import Testing
@testable import TeleprompterKit

@Test func firstFrameFailureSurvivesFinalization() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let writer = try MovieRecorder(folder: folder, profile: .init(id: "test", width: 1280, height: 720, framesPerSecond: 30))
    var pixel: CVPixelBuffer?
    #expect(CVPixelBufferCreate(kCFAllocatorDefault, 640, 480, kCVPixelFormatType_32BGRA, nil, &pixel) == noErr)
    let image = try #require(pixel)
    var format: CMVideoFormatDescription?
    #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &format) == noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var buffer: CMSampleBuffer?
    #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
        formatDescription: try #require(format), sampleTiming: &timing, sampleBufferOut: &buffer) == noErr)
    var original: String?
    do { try writer.append(try #require(buffer), isVideo: true); Issue.record("Mismatched dimensions were accepted") }
    catch { original = error.localizedDescription }
    #expect(original?.contains("640 × 480") == true)
    #expect(original?.contains("1280 × 720") == true)
    do { _ = try await writer.finish(); Issue.record("A failed first frame produced a completed take") }
    catch { #expect(error.localizedDescription == original) }
    #expect(!FileManager.default.fileExists(atPath: writer.temporaryURL.path))
}
