import Foundation

/// A request to the Cosmo backend failed.
///
/// The base every per-call error adopts — ``MintTokenError``,
/// ``TokenSourceError``, ``VerifyError``, ``UsageError``, ``DialError`` — so
/// `catch let error as ApiError` covers any backend call while catching a
/// specific one still says which call it was. Starting a session throws
/// ``SessionStartError`` instead, which carries the HTTP status a start
/// rejection turns on.
///
/// Each conformer carries its own closed `code`; ``serverCode`` is the open
/// half and lives here, because a rejection slug belongs to whichever backend
/// answered rather than to the call that asked.
public protocol ApiError: RealtimeError {
    /// Human-readable explanation, for logs and display. Restated from
    /// ``RealtimeError`` so the published surface reads the same as the
    /// sibling SDKs', where the base class carries it.
    var message: String { get }

    /// The server's own rejection slug when it sent one, or a synthetic
    /// `http_<status>`. An open set: log it, do not switch on it. `nil` when
    /// no server verdict was parsed.
    var serverCode: String? { get }
}
