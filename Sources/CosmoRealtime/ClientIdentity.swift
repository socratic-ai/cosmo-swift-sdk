import Foundation

/// The header names carrying the calling client's identity. Defined here and
/// nowhere else: both the ``URLRequest`` applier below and
/// ``ClientIdentityMiddleware`` (for generated requests) read these.
enum ClientHeaderName {
    static let client = "X-Cosmo-Client"
    static let version = "X-Cosmo-Client-Version"
    static let build = "X-Cosmo-Client-Build"
}

/// Identifies the app calling the Cosmo backend, so the backend can tell a
/// three-week-old build from today's.
///
/// Build is carried separately from marketing version because it is the
/// monotonic ordering key — the release script's `BUILD`, Sparkle's
/// `<sparkle:version>` — while marketing version is display only.
///
/// Self-asserted and trivially spoofable: telemetry and compatibility hints
/// only, never an authentication or authorisation signal.
public struct ClientIdentity: Sendable, Equatable {
    public let client: String
    public let marketingVersion: String
    public let build: String

    public init(client: String, marketingVersion: String, build: String) {
        self.client = client
        self.marketingVersion = marketingVersion
        self.build = build
    }

    var headerFields: [(name: String, value: String)] {
        [
            (ClientHeaderName.client, client),
            (ClientHeaderName.version, marketingVersion),
            (ClientHeaderName.build, build),
        ]
    }

    public func apply(to request: inout URLRequest) {
        for field in headerFields {
            request.setValue(field.value, forHTTPHeaderField: field.name)
        }
    }
}
