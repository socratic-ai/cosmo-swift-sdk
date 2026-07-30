import Foundation

public enum VerifyTLS: Sendable, Equatable {
    /// Verify for remote hosts, skip for loopback (self-signed local dev). Default.
    case auto
    /// Always verify, including loopback.
    case enabled
    /// Never verify, for any host. A deliberate escape hatch — it weakens trust
    /// for remote hosts too, not just loopback.
    case disabled

    public func resolve(forHost host: String) -> Bool {
        switch self {
        case .enabled:  return true
        case .disabled: return false
        case .auto:     return !LocalHost.isLocal(host)
        }
    }
}

public struct ClientOptions: Sendable {
    public var origin: String
    public var verifyTLS: VerifyTLS
    public var openTimeout: TimeInterval
    public var pingInterval: TimeInterval
    public var wsURLOverride: URL?

    /// Identifies the calling app to the backend. Nil (the default) sends no
    /// client headers, so third-party embedders are unaffected.
    public var clientIdentity: ClientIdentity?

    public init(
        origin: String = "https://localhost:3000",
        verifyTLS: VerifyTLS = .auto,
        openTimeout: TimeInterval = 8,
        pingInterval: TimeInterval = 20,
        wsURLOverride: URL? = nil,
        clientIdentity: ClientIdentity? = nil
    ) {
        self.origin = origin
        self.verifyTLS = verifyTLS
        self.openTimeout = openTimeout
        self.pingInterval = pingInterval
        self.wsURLOverride = wsURLOverride
        self.clientIdentity = clientIdentity
    }
}
