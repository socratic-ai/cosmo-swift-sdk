import Foundation

/// Gemini Live prebuilt voice for ``VoiceSession.start(voiceName:)``.
/// Raw values are the literal strings
/// Gemini Live's ``PrebuiltVoiceConfig.voiceName`` expects — do not
/// rename without checking the server side.
///
/// Voice flows client → server; the server never echoes one back to the
/// SDK, so a closed enum without a forward-compat ``unknown`` case is fine.
public enum GeminiVoice: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case aoede = "Aoede"
    case charon = "Charon"
    case fenrir = "Fenrir"
    case kore = "Kore"
    case leda = "Leda"
    case orus = "Orus"
    case puck = "Puck"
    case zephyr = "Zephyr"

    public var id: String { rawValue }

    /// One-word personality descriptor for a Settings picker. Sourced from
    /// Google's Gemini Live voice docs; ``orus`` is shown as "Confident"
    /// instead of the docs' "Firm" so it doesn't collide with ``kore``.
    public var displayName: String {
        switch self {
        case .aoede:  return "Breezy"
        case .charon: return "Informative"
        case .fenrir: return "Excitable"
        case .kore:   return "Firm"
        case .leda:   return "Youthful"
        case .orus:   return "Confident"
        case .puck:   return "Upbeat"
        case .zephyr: return "Bright"
        }
    }
}
