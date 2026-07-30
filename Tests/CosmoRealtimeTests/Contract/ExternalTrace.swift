import Foundation
@testable import CosmoRealtime

// MARK: - Trace models
//
// Swift loader for the language-neutral external-protocol contract
// traces. Format spec: ``sdks/cosmo-realtime/contract/README.md``
// (machine schema: ``contract/trace.schema.json``); the Python and
// TypeScript runners under ``sdks/cosmo-realtime/{python,typescript}``
// load the same files.

struct ExternalTrace: Decodable, Sendable {
    let name: String
    let description: String
    let steps: [Step]
    let expectEvents: [EventMatcher]?
    let expectSent: [EventMatcher]?
    let expect: Expect?

    enum Step: Decodable, Sendable {
        case start(config: [String: JSONValue])
        case serverFrames([Frame])
        case clientSend(message: [String: JSONValue])
        case end

        private enum CodingKeys: String, CodingKey {
            case type, config, frames, message
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            switch type {
            case "start":
                self = .start(config: try c.decode([String: JSONValue].self, forKey: .config))
            case "server_frames":
                self = .serverFrames(try c.decode([Frame].self, forKey: .frames))
            case "client_send":
                self = .clientSend(message: try c.decode([String: JSONValue].self, forKey: .message))
            case "end":
                self = .end
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: c,
                    debugDescription: "Unknown step type: \(type)"
                )
            }
        }
    }

    /// One raw server frame: a JSON object (serialized and injected as
    /// one frame) or a verbatim string (the malformed-frame cases).
    enum Frame: Decodable, Sendable {
        case object([String: JSONValue])
        case raw(String)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let raw = try? c.decode(String.self) {
                self = .raw(raw)
                return
            }
            self = .object(try c.decode([String: JSONValue].self))
        }

        var wireData: Data {
            switch self {
            case .raw(let text):
                return Data(text.utf8)
            case .object(let fields):
                // Hand-built object of Codable JSONValues — encoding
                // cannot realistically fail.
                return (try? JSONEncoder().encode(fields)) ?? Data()
            }
        }
    }

    struct EventMatcher: Decodable, Sendable {
        let type: String
        let match: [String: JSONValue]?
    }

    struct Expect: Decodable, Sendable {
        let states: [String]?
        let streamFinished: Bool?
        let thrown: String?
        let thrownDetailContains: String?
        let lastEventType: String?
    }
}

// MARK: - Loader

enum ExternalTraceLoader {
    /// All ``*.json`` traces under ``contract/external-traces/``,
    /// sorted by filename. Throws on malformed traces and on a
    /// name/filename mismatch so a bad fixture fails loudly.
    static func loadAll() throws -> [ExternalTrace] {
        let dir = tracesDirectory()
        let urls = try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let decoder = JSONDecoder()
        return try urls.map { url in
            let trace = try decoder.decode(ExternalTrace.self, from: try Data(contentsOf: url))
            let stem = url.deletingPathExtension().lastPathComponent
            guard trace.name == stem else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [
                    NSLocalizedDescriptionKey: "trace name \(trace.name) != filename \(stem)"
                ])
            }
            return trace
        }
    }

    /// ``sdks/cosmo-realtime/contract/external-traces/``, derived from
    /// this source file's path (``…/swift/Tests/CosmoRealtimeTests/Contract/ExternalTrace.swift``).
    private static func tracesDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Contract/
            .deletingLastPathComponent()  // CosmoRealtimeTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // swift/
            .deletingLastPathComponent()  // cosmo-realtime/
            .appendingPathComponent("contract/external-traces", isDirectory: true)
    }
}
