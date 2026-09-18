import Foundation
import OpenAPIRuntime

/// The backend's ISO-8601 timestamps, which carry fractional seconds or not
/// depending on the value FastAPI is serializing. Both spellings parse.
enum RealtimeISO8601 {
    private static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(from raw: String) -> Date? {
        withFractionalSeconds.date(from: raw) ?? plain.date(from: raw)
    }

    static func string(from date: Date) -> String {
        plain.string(from: date)
    }
}

/// Widens the generated client's date handling to both spellings above. The
/// runtime's stock transcoder accepts only the fractionless one, so a mint or
/// session-start response whose timestamp carried fractional seconds failed
/// to decode.
struct RealtimeDateTranscoder: DateTranscoder {
    func encode(_ date: Date) throws -> String {
        RealtimeISO8601.string(from: date)
    }

    func decode(_ dateString: String) throws -> Date {
        guard let date = RealtimeISO8601.date(from: dateString) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Expected an ISO-8601 date: \(dateString)")
            )
        }
        return date
    }
}
