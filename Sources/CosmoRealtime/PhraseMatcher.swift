import Foundation

/// Matches a fixed spoken phrase against a speech-recognition transcript.
///
/// Both the phrase and the transcript are tokenized to lowercase
/// alphanumeric words; a match is the phrase appearing as a contiguous
/// run of tokens. A `debounce` interval suppresses repeat matches caused
/// by the recognizer re-reporting the same cumulative partial result.
///
/// Reused for two roles in this package:
///   * **Local wake-word detection**: matched against ``SFSpeechRecognizer``
///     partials by ``AppleSpeechWakeWordDetector``.
///   * **Server-side sleep-phrase detection**: matched against
///     ``ServerEvent/transcript`` partials in ``VoiceSessionModel``. The
///     backend never emits ``isFinal=true`` for user-role transcripts, so
///     the matcher fires on partials and the debounce prevents repeated
///     hits on the same utterance.
public struct PhraseMatcher: Sendable {
    private let phraseTokens: [String]
    private let debounce: TimeInterval
    private var lastMatchAt: Date = .distantPast

    public init(phrase: String, debounce: TimeInterval = 2.0) {
        self.phraseTokens = Self.tokenize(phrase)
        self.debounce = debounce
    }

    /// Returns `true` once when `transcript` contains the phrase, then
    /// stays quiet for `debounce` seconds before it can fire again.
    /// An empty configured phrase always returns `false`, which lets
    /// callers disable a matcher slot (e.g. wake-only mode).
    public mutating func check(transcript: String, now: Date = Date()) -> Bool {
        guard !phraseTokens.isEmpty else { return false }
        if now.timeIntervalSince(lastMatchAt) < debounce { return false }
        let tokens = Self.tokenize(transcript)
        guard tokens.count >= phraseTokens.count else { return false }
        for start in 0...(tokens.count - phraseTokens.count) {
            if Array(tokens[start..<(start + phraseTokens.count)]) == phraseTokens {
                lastMatchAt = now
                return true
            }
        }
        return false
    }

    private static func tokenize(_ s: String) -> [String] {
        s.lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
    }
}
