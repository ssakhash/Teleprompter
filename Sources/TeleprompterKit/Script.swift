import Foundation
import NaturalLanguage

public struct ScriptToken: Sendable, Equatable, Identifiable {
    public let id: Int
    public let text: String
    public let range: NSRange
    public let sentence: Int
    public let normalized: [String]
}

public struct Script: Sendable {
    public let text: String
    public let tokens: [ScriptToken]

    public init(_ text: String) {
        self.text = text
        let sentences = NLTokenizer(unit: .sentence)
        sentences.string = text
        sentences.setLanguage(.english)
        var result: [ScriptToken] = []
        var sentenceID = 0
        sentences.enumerateTokens(in: text.startIndex..<text.endIndex) { sentenceRange, _ in
            // Keep decimal/grouped numbers and contractions together, with stable UTF-16 offsets.
            let substring = String(text[sentenceRange])
            let regex = try! NSRegularExpression(pattern: #"[\p{L}\p{M}]+(?:['’][\p{L}\p{M}]+)*|\d+(?:[,\.]\d+)*"#)
            let base = NSRange(sentenceRange, in: text).location
            for match in regex.matches(in: substring, range: NSRange(substring.startIndex..., in: substring)) {
                let word = (substring as NSString).substring(with: match.range)
                result.append(ScriptToken(id: result.count, text: word,
                    range: NSRange(location: base + match.range.location, length: match.range.length),
                    sentence: sentenceID, normalized: Self.normalize(word)))
            }
            sentenceID += 1
            return true
        }
        tokens = result
    }

    public static func normalize(_ word: String) -> [String] {
        let value = word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
            .replacingOccurrences(of: "’", with: "'")
        let contractions: [String: [String]] = [
            "i'm": ["i", "am"], "it's": ["it", "is"], "that's": ["that", "is"],
            "don't": ["do", "not"], "doesn't": ["does", "not"], "didn't": ["did", "not"],
            "can't": ["can", "not"], "cannot": ["can", "not"], "won't": ["will", "not"],
            "let's": ["let", "us"], "isn't": ["is", "not"], "aren't": ["are", "not"],
            "wasn't": ["was", "not"], "weren't": ["were", "not"], "i've": ["i", "have"],
            "we've": ["we", "have"], "you've": ["you", "have"], "they've": ["they", "have"],
            "we're": ["we", "are"], "you're": ["you", "are"], "they're": ["they", "are"],
            "i'll": ["i", "will"], "we'll": ["we", "will"], "you'll": ["you", "will"]
        ]
        if let expansion = contractions[value] { return expansion }
        let numeric = value.replacingOccurrences(of: ",", with: "")
        if let number = Decimal(string: numeric, locale: Locale(identifier: "en_US_POSIX")),
           numeric.first?.isNumber == true, numeric.count <= 15 {
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.numberStyle = .spellOut
            if let spoken = formatter.string(from: NSDecimalNumber(decimal: number)) {
                return spoken.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty && $0 != "and" }
            }
        }
        return [value]
    }

    public func sentenceStart(relativeTo index: Int, offset: Int) -> Int {
        guard !tokens.isEmpty else { return 0 }
        let current = tokens[min(max(0, index), tokens.count - 1)].sentence
        let target = max(0, current + offset)
        return tokens.firstIndex(where: { $0.sentence >= target }) ?? (tokens.count - 1)
    }
}

/// Collapses paragraph whitespace in the compact reader without changing editor content
/// or the aligner's source offsets. Token IDs retain an exact mapping into displayed text.
public struct PromptText: Sendable {
    public let text: String
    public let tokenRanges: [NSRange]
    public init(script: Script) {
        let source = script.text as NSString
        var text = ""
        var ranges: [NSRange] = []
        var previousEnd = 0
        for token in script.tokens {
            let separator = source.substring(with: NSRange(location: previousEnd, length: token.range.location - previousEnd))
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            text += separator
            let start = (text as NSString).length
            text += token.text
            ranges.append(NSRange(location: start, length: (token.text as NSString).length))
            previousEnd = NSMaxRange(token.range)
        }
        text += source.substring(from: previousEnd).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        self.text = text; tokenRanges = ranges
    }
}
