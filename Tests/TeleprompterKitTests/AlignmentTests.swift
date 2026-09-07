import Foundation
import Testing
@testable import TeleprompterKit

private func event(_ text: String, _ aligner: ScriptAligner, start: Double = 0, end: Double = 1, final: Bool = false) -> SpeechEvent {
    SpeechEvent(start: start, end: end, text: text, isFinal: final, generation: aligner.generation)
}

@Test func originalRangesAndNormalization() {
    let text = "Hello, José! I'm recording 21 clear words."
    let script = Script(text)
    for token in script.tokens { #expect((text as NSString).substring(with: token.range) == token.text) }
    #expect(Script.normalize("I'm") == ["i", "am"])
    #expect(Script.normalize("21") == ["twenty", "one"])
    #expect(script.tokens.last?.sentence == 1)
}

@Test func revisionsReplaceAndAdvance() {
    var aligner = ScriptAligner(script: Script("Welcome to this useful demonstration of our new camera."))
    #expect(aligner.consume(event("welcome to this", aligner)).index == 2)
    #expect(aligner.consume(event("welcome to this useful demonstration", aligner, end: 2)).index == 4)
    #expect(aligner.consume(event("welcome to this useful demonstration", aligner, end: 2, final: true)).index == 4)
    #expect(aligner.consume(event("welcome to", aligner)).index == 4)
}

@Test func fillersAndNumbers() {
    var aligner = ScriptAligner(script: Script("I'm going to record 21 clear words today."))
    let result = aligner.consume(event("I am um going to record twenty one clear words", aligner, final: true))
    #expect(aligner.script.tokens[result.index].text == "words")
}

@Test func silenceAndTangentsHoldPosition() {
    var aligner = ScriptAligner(script: Script("Welcome to the camera demo. We will read this script together."))
    let initial = aligner.consume(event("welcome to the camera", aligner, final: true)).index
    #expect(aligner.consume(event("", aligner, start: 1, end: 2)).index == initial)
    #expect(aligner.consume(event("purple elephants dance on distant planets", aligner, start: 2, end: 4)).index == initial)
}

@Test func nearbySkipAndRestart() {
    var aligner = ScriptAligner(script: Script("Welcome to the first sentence. This middle thought can be skipped. Finally we finish the recording together."))
    _ = aligner.consume(event("welcome to the first sentence", aligner, final: true))
    let skipped = aligner.consume(event("finally we finish the recording", aligner, start: 1, end: 4, final: true))
    #expect(aligner.script.tokens[skipped.index].text == "recording")
    let restart = aligner.consume(event("welcome to the first sentence", aligner, start: 5, end: 9, final: true))
    #expect(restart.index == 4)
}

@Test func manualRepositionRejectsStaleAudio() {
    var aligner = ScriptAligner(script: Script("First we begin. Next we continue. Finally we finish."))
    let old = event("first we begin", aligner, final: true)
    aligner.reposition(to: 6)
    #expect(aligner.consume(old).index == 6)
}

@Test func distantPhraseDoesNotJump() {
    var aligner = ScriptAligner(script: Script("Begin the first topic. Second sentence here. Third sentence here. Fourth sentence here. Distant purple mountain expedition begins here."))
    #expect(aligner.consume(event("distant purple mountain expedition", aligner, final: true)).index == 0)
}

@Test func repeatedPhraseDoesNotJumpFar() {
    var aligner = ScriptAligner(script: Script("This is a repeated phrase. Another thought goes here. This is a repeated phrase."))
    #expect(aligner.consume(event("this is a repeated phrase", aligner, final: true)).index == 4)
}

@Test func emptyAndUnicodeScripts() {
    var empty = ScriptAligner(script: Script("🎥 — …"))
    #expect(empty.consume(event("hello world", empty)).index == 0)
    #expect(Script("Don’t stop, café friends.").tokens.first?.normalized == ["do", "not"])
}

@Test func resolutionBeforeFrameRate() {
    let low = RecordingProfile(id: "low", width: 1920, height: 1080, framesPerSecond: 60)
    let high = RecordingProfile(id: "high", width: 3840, height: 2160, framesPerSecond: 30)
    #expect(RecordingProfile.ranked([low, high]).first == high)
    #expect(high.bytesPerMinute > 0)
}

@Test func settingsRoundTrip() throws {
    let original = SavedDraft(text: "A private script.")
    let decoded = try JSONDecoder().decode(SavedDraft.self, from: JSONEncoder().encode(original))
    #expect(decoded.text == original.text)
    #expect(decoded.settings.mode == .speech)
}

@Test func smallWordingChangesRemainAligned() {
    var aligner = ScriptAligner(script: Script("Today we will explore a useful new approach to recording video."))
    let result = aligner.consume(event("today we explore a very useful new approach", aligner, final: true))
    #expect(aligner.script.tokens[result.index].text == "approach")
}

@Test func decimalNumberAndCaseNormalization() {
    #expect(Script.normalize("3.5") == ["three", "point", "five"])
    #expect(Script.normalize("JOSÉ") == ["jose"])
    #expect(Script.normalize("1,200") == ["one", "thousand", "two", "hundred"])
}

@Test func shortAmbiguousEvidenceDoesNotSkipSentence() {
    var aligner = ScriptAligner(script: Script("Start with a clear introduction today. Finish the other idea tomorrow."))
    #expect(aligner.consume(event("today", aligner)).index == 0)
}

@Test func sameHypothesisCannotConfirmBackwardJump() {
    var aligner = ScriptAligner(script: Script("One clear opening phrase starts us. Another thoughtful sentence goes here."))
    aligner.reposition(to: 10)
    let partial = event("one clear opening", aligner)
    let first = aligner.consume(partial)
    let duplicate = aligner.consume(partial)
    #expect(first.index == 10)
    #expect(duplicate.index == 10)
}

@Test func invalidAudioIntervalsAreRejected() {
    var aligner = ScriptAligner(script: Script("Welcome to this example."))
    #expect(aligner.consume(event("welcome to this", aligner, start: .nan)).index == 0)
    #expect(aligner.consume(event("welcome to this", aligner, start: 4, end: 2)).index == 0)
}

@Test func longScriptMatchingIsLocal() {
    let paragraph = "We can make a useful recording today. "
    var aligner = ScriptAligner(script: Script(String(repeating: paragraph, count: 2000)))
    let anchor = 7000
    aligner.reposition(to: anchor)
    let result = aligner.consume(event("we can make a useful recording", aligner, final: true))
    #expect(abs(result.index - anchor) <= 16)
}

@Test func unavailableRecordingFolderFailsPreflight() {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    let profile = RecordingProfile(id: "test", width: 1920, height: 1080, framesPerSecond: 30)
    #expect(throws: (any Error).self) { try CaptureService.checkDisk(folder, profile: profile) }
}

@Test func invalidMediaDoesNotPassInspection() async throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("invalid-\(UUID()).mp4")
    try Data("This is not video".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    await #expect(throws: (any Error).self) { try await MovieRecorder.inspect(url) }
}

@Test func compactReaderPreservesWordMapping() {
    let script = Script("Hello, José!\n\n\nI'm recording 21 words.\n\nNext paragraph.")
    let prompt = PromptText(script: script)
    #expect(!prompt.text.contains("\n"))
    for token in script.tokens {
        #expect((prompt.text as NSString).substring(with: prompt.tokenRanges[token.id]) == token.text)
    }
    #expect(script.text.contains("\n\n"))
}
