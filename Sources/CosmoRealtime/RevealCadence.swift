import Foundation

/// Per-word reveal cadence for the streaming assistant caption, keyed by the
/// Gemini voice that's speaking. The caption is paced word-by-word (see
/// ``TranscriptRevealer``) because the model generates the transcript several
/// times faster than the TTS audio plays it — rendering each wire delta the
/// instant it arrives races the caption ahead of the voice.
///
/// The cadence is a cosmetic, fixed-per-voice *guess*: neither provider exposes
/// per-word audio timestamps, so we can't sync the caption to the actual
/// playout. Different prebuilt voices speak at noticeably different rates, so a
/// single global cadence over- or under-shoots depending on the voice; this
/// table nudges the interval per voice to keep the caption tracking the audio.
///
/// This lives entirely inside the SDK — the voice already travels client→server
/// in the session config, so there's no new wire field. It may later key on
/// ``(voice, speakingStyle)`` once speaking-style lands on the hot path; the
/// real fix is pacing to audio-playout progress, of which this is the cheap
/// intermediate.
enum RevealCadence {

    /// Fallback cadence when a voice has no tuned entry. Reads a touch faster
    /// than an average speaker so the caption never trails the voice.
    static let defaultPerWord: Duration = .milliseconds(240)

    /// Minimum delay between revealed words for `voice`. Larger = slower
    /// caption. Values are hand-tuned by ear against each voice's speaking rate;
    /// unlisted voices fall back to ``defaultPerWord``.
    static func perWord(for voice: GeminiVoice) -> Duration {
        switch voice {
        // Informative/measured — speaks slower, so reveal slower to match.
        case .charon: return .milliseconds(280)
        // Upbeat/brisk — speaks faster, so reveal faster to keep pace.
        case .puck: return .milliseconds(220)
        default: return defaultPerWord
        }
    }
}
