import Foundation

public struct SpeechEvent: Sendable {
    public let start: Double
    public let end: Double
    public let text: String
    public let isFinal: Bool
    public let generation: UUID
    public init(start: Double, end: Double, text: String, isFinal: Bool, generation: UUID) {
        self.start = start; self.end = end; self.text = text
        self.isFinal = isFinal; self.generation = generation
    }
}

public enum TrackingStatus: String, Sendable {
    case listening = "Listening", following = "Following your voice", waiting = "Waiting for a match"
    case paused = "Prompter paused", finished = "End of script"
}

public struct TrackingUpdate: Sendable {
    public let index: Int
    public let confirmedIndex: Int
    public let confidence: Double
    public let status: TrackingStatus
}

/// A bounded, local sequence matcher. ASR hypotheses replace intervals, never append duplicates.
public struct ScriptAligner: Sendable {
    public private(set) var script: Script
    public private(set) var index = 0
    public private(set) var confirmedIndex = 0
    public private(set) var generation = UUID()
    private var segments: [SpeechEvent] = []
    private var pendingJump: Int?
    private var pendingCount = 0
    private var lastEvidence = ""
    private var latestFinalEnd: Double = -.infinity
    private static let fillers: Set<String> = ["um", "uh", "erm", "hmm"]

    public init(script: Script) { self.script = script }

    @discardableResult public mutating func reposition(to value: Int) -> UUID {
        index = min(max(0, value), max(0, script.tokens.count - 1))
        confirmedIndex = index
        generation = UUID()
        segments.removeAll(); pendingJump = nil; pendingCount = 0
        lastEvidence = ""; latestFinalEnd = -.infinity
        return generation
    }

    public mutating func consume(_ event: SpeechEvent) -> TrackingUpdate {
        guard event.generation == generation, !script.tokens.isEmpty,
              event.start.isFinite, event.end.isFinite, event.end >= event.start else { return update(.waiting) }
        // Reject late revisions of already-finalized audio; newer generations reject pre-seek results.
        guard event.end > latestFinalEnd + 0.0001 else { return update(.waiting) }
        segments.removeAll { $0.start < event.end && $0.end > event.start || abs($0.start - event.start) < 0.001 }
        segments.append(event)
        segments.sort { $0.start < $1.start }
        segments = Array(segments.suffix(8))
        if event.isFinal { latestFinalEnd = max(latestFinalEnd, event.end) }
        // Limit both history duration and token count, avoiding tangents accumulating unbounded work.
        let recent = segments.filter { event.end - $0.end <= 8 }.map(\.text).joined(separator: " ")
        let spoken = Array(Script(recent).tokens.flatMap(\.normalized).filter { !Self.fillers.contains($0) }.suffix(16))
        guard !spoken.isEmpty else { return update(.waiting) }
        let sentence = script.tokens[index].sentence
        let local = script.tokens.filter { $0.sentence >= sentence - 2 && $0.sentence <= sentence + 3 }
            .filter { abs($0.id - index) <= 180 }
        let units = local.flatMap { token in token.normalized.map { ($0, token.id) } }
        guard !units.isEmpty else { return update(.waiting) }

        // Semi-global edit alignment: free prefix in the script, inexpensive fillers/omissions,
        // and strong reward for exact matches. Evaluate suffixes to reacquire after a tangent.
        struct Candidate { var token: Int; var score: Double; var matches: Int; var confidence: Double }
        var candidates: [Candidate] = []
        for suffixLength in Set([min(5, spoken.count), min(10, spoken.count), spoken.count]) {
            let query = Array(spoken.suffix(suffixLength))
            let n = units.count
            var scores = Array(repeating: 0.0, count: n + 1)
            var counts = Array(repeating: 0, count: n + 1)
            for (row, word) in query.enumerated() {
                var next = Array(repeating: 0.0, count: n + 1)
                var matched = Array(repeating: 0, count: n + 1)
                next[0] = -Double(row + 1) * 1.1
                for column in 1...n {
                    let equal = word == units[column - 1].0
                    let choices = [(scores[column - 1] + (equal ? 2.5 : -1.6), counts[column - 1] + (equal ? 1 : 0)),
                                   (scores[column] - 1.1, counts[column]),
                                   (next[column - 1] - 1.0, matched[column - 1])]
                    let best = choices.max { $0.0 < $1.0 }!
                    next[column] = best.0; matched[column] = best.1
                }
                scores = next; counts = matched
            }
            for column in 1...n where units[column - 1].0 == query.last {
                let confidence = Double(counts[column]) / Double(query.count)
                guard counts[column] >= min(3, query.count), confidence >= 0.65 else { continue }
                let token = units[column - 1].1
                let proximity = min(0.9, Double(abs(token - index)) * 0.012)
                candidates.append(Candidate(token: token, score: scores[column] / Double(query.count) - proximity,
                                            matches: counts[column], confidence: confidence))
            }
        }
        let ranked = candidates.sorted { $0.score > $1.score }
        guard let best = ranked.first else { return update(.waiting) }
        let isJump = best.token < index || best.token > index + 7
        if best.matches < 3 && abs(best.token - index) > 2 { return update(.waiting) }
        if let competitor = ranked.first(where: { abs($0.token - best.token) > 3 }),
           best.score - competitor.score < 0.12, isJump { return update(.waiting) }
        if isJump {
            guard best.matches >= 3 else { return update(.waiting) }
            let evidence = spoken.joined(separator: " ")
            if let pendingJump, abs(pendingJump - best.token) <= 5 {
                if evidence != lastEvidence { pendingCount += 1 }
            } else { pendingCount = 1 }
            pendingJump = best.token; lastEvidence = evidence
            // A final, distinctive phrase or two evolving hypotheses confirms a jump.
            guard pendingCount >= 2 || (event.isFinal && best.matches >= 4 && best.confidence >= 0.8) else {
                return update(.waiting)
            }
        } else { pendingJump = nil; pendingCount = 0 }
        index = best.token
        if event.isFinal || isJump { confirmedIndex = index }
        return update(index == script.tokens.count - 1 ? .finished : .following, confidence: best.confidence)
    }

    private func update(_ status: TrackingStatus, confidence: Double = 0) -> TrackingUpdate {
        TrackingUpdate(index: index, confirmedIndex: confirmedIndex, confidence: confidence, status: status)
    }
}
