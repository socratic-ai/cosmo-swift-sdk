import Foundation
import os

/// Why a ``TokenSource`` could not produce a token.
///
/// Closed: every one is raised by this SDK. The token endpoint's own
/// rejection slug is open and rides on ``TokenSourceError/serverCode``.
public enum TokenSourceErrorCode: String, Sendable, Equatable {
    /// The token endpoint did not produce a usable answer — it could not be
    /// reached, or it answered with a redirect, which is refused rather than
    /// followed.
    case requestFailed = "request_failed"
    /// The endpoint refused. ``TokenSourceError/serverCode`` carries its own
    /// slug for why.
    case requestRejected = "request_rejected"
    /// The endpoint answered without a usable token.
    case invalidResponse = "invalid_response"
    /// A custom fetcher returned an empty JWT. An error the closure itself
    /// throws propagates unchanged rather than becoming this code.
    case fetcherFailed = "fetcher_failed"
}

/// A ``TokenSource`` could not produce a token.
///
/// Raised while the SDK obtains a credential for itself, which happens
/// beneath every authenticated call — ``RealtimeClient/verify()``,
/// ``RealtimeClient/mintToken(_:ttlSeconds:)``, session start,
/// dial and usage reads all resolve the source first, and it re-resolves on
/// expiry and after a 401. So this surfaces from whichever call needed a
/// token, not from one operation.
///
/// ``code`` names what this SDK saw; ``serverCode`` carries the token
/// endpoint's own slug when ``code`` is
/// ``TokenSourceErrorCode/requestRejected``.
public struct TokenSourceError: ApiError, LocalizedError, Equatable {
    /// How far the fetch got. A closed set this SDK raises — switch on it.
    public let code: TokenSourceErrorCode
    /// Human-readable explanation, for logs and display.
    public let message: String
    /// The token endpoint's own rejection slug when it sent one. An open set:
    /// log it, do not switch on it.
    public let serverCode: String?

    /// Creates a token-source error.
    public init(code: TokenSourceErrorCode, message: String, serverCode: String? = nil) {
        self.code = code
        self.message = message
        self.serverCode = serverCode
    }

    /// The message, for `LocalizedError` presentation.
    /// The message, for `LocalizedError` presentation.
    /// The message, for `LocalizedError` presentation.
    public var errorDescription: String? { message }
}

/// A credential that fetches — and keeps fresh — a minted end-user token.
///
/// A shipped app must not hold an API key, and a static minted JWT expires
/// after 24 hours. A ``TokenSource`` closes the gap: it knows how to fetch a
/// fresh ``MintedToken`` from the developer's own backend, caches it in
/// memory, and re-fetches when the cached token nears expiry — so a client
/// built with ``RealtimeClient/init(tokenSource:baseURL:connectTimeout:requestTimeout:verifyTLS:transport:)``
/// stays valid for the life of the process with no refresh code in the app.
///
/// The session asks the source for a JWT whenever a request needs auth; the
/// source reuses its cached token while comfortably within its lifetime and
/// re-fetches otherwise. A session start rejected with HTTP 401 drops the
/// cache, so the next start fetches fresh.
///
/// Two constructors:
///
/// - ``endpoint(_:headers:)`` — POST a token endpoint that returns
///   ``{ jwt, expires_at }`` (the shape mint responses already have; any
///   backend that forwards ``POST auth/token`` qualifies).
/// - ``custom(_:)`` — any async function returning a ``MintedToken`` — full
///   control over transport and auth.
public final class TokenSource: Sendable {

    static let log = Logger(subsystem: CosmoRealtimeLog.subsystem, category: "token-source")

    /// Re-fetch this long before ``MintedToken/expiresAt`` so an in-flight
    /// session start never races the expiry boundary. Matches the cross-SDK
    /// contract (``token-source-vectors.json``).
    static let refreshSkew: TimeInterval = 60

    private let store: Store

    init(
        fetchToken: @escaping @Sendable () async throws -> MintedToken,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = Store(fetchToken: fetchToken, now: now)
    }

    /// A source that POSTs ``url`` (empty JSON body) and reads
    /// ``{ jwt, expires_at }`` from the response — the wire shape of
    /// ``POST /api/v1/external/auth/token`` and of the token-server
    /// template (``expiresAt``, the serialized ``MintedToken`` spelling,
    /// is accepted too). ``headers`` carry the app's own auth (its
    /// session cookie, a bearer, a shared secret). Rejections surface as
    /// ``TokenSourceError`` carrying the server's error slug on
    /// ``TokenSourceError/serverCode`` when the body parses, else a
    /// synthetic ``http_<status>``. Throws for a plain-http ``url`` to a
    /// non-loopback host — auth headers and JWTs must not cross the network
    /// in the clear. Redirects are refused for the same reason: the
    /// exchange never leaves ``url``.
    public static func endpoint(_ url: URL, headers: [String: String] = [:]) throws -> TokenSource {
        try _assertSupportedEndpointURL(url)
        return TokenSource(fetchToken: { try await _postTokenEndpoint(url: url, headers: headers) })
    }

    /// Like ``endpoint(_:headers:)`` with the headers resolved per fetch —
    /// for a rotating credential (a fresh session cookie or bearer each
    /// request). The closure runs before every token POST; an error it
    /// throws surfaces from whichever call needed the token, and nothing
    /// is sent.
    public static func endpoint(
        _ url: URL,
        headers: @escaping @Sendable () async throws -> [String: String]
    ) throws -> TokenSource {
        try _assertSupportedEndpointURL(url)
        return TokenSource(
            fetchToken: { try await _postTokenEndpoint(url: url, headers: headers()) }
        )
    }

    private static func _assertSupportedEndpointURL(_ url: URL) throws {
        guard _isSupportedEndpointURL(url) else {
            // Refused before any request, so this is a credential the SDK will
            // not send rather than a request that failed — the same code the
            // sibling SDKs report for it.
            throw CredentialsError(
                code: .insecureBaseURL,
                message: "TokenSource.endpoint must use https (http is allowed only for "
                    + "localhost): \(url.absoluteString)"
            )
        }
    }

    /// Only ``https``, or ``http`` specifically to a loopback host — any
    /// other scheme is refused even on localhost, per the cross-SDK contract.
    static func _isSupportedEndpointURL(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return RealtimeSession.isLoopbackHost(url.host)
        default: return false
        }
    }

    /// A source backed by ``fetchToken`` — called whenever a fresh token is
    /// needed, returning the ``MintedToken`` to use. A token with an empty
    /// ``MintedToken/jwt`` raises ``TokenSourceError``.
    public static func custom(
        _ fetchToken: @escaping @Sendable () async throws -> MintedToken
    ) -> TokenSource {
        TokenSource(fetchToken: {
            let minted = try await fetchToken()
            guard !minted.jwt.isEmpty else {
                throw TokenSourceError(
                    code: .fetcherFailed,
                    message: "TokenSource.custom fetcher must return a non-empty jwt."
                )
            }
            return minted
        })
    }

    /// The JWT to send right now: cached while it has more than the refresh
    /// skew left, else one shared re-fetch (concurrent callers await the
    /// same fetch). A failed fetch caches nothing.
    func jwt() async throws -> String {
        try await store.jwt()
    }

    /// Drop the cached token so the next ``jwt()`` re-fetches.
    func invalidate() async {
        await store.invalidate()
    }

    /// Cache + single-flight state, isolated so ``TokenSource`` itself can
    /// stay a plain ``Sendable`` class.
    private actor Store {
        private let fetchToken: @Sendable () async throws -> MintedToken
        private let now: @Sendable () -> Date
        private var cached: MintedToken?
        private var inflight: Task<MintedToken, Error>?

        init(
            fetchToken: @escaping @Sendable () async throws -> MintedToken,
            now: @escaping @Sendable () -> Date
        ) {
            self.fetchToken = fetchToken
            self.now = now
        }

        func jwt() async throws -> String {
            if let cached, cached.expiresAt.timeIntervalSince(now()) > TokenSource.refreshSkew {
                return cached.jwt
            }
            if let inflight {
                return try await inflight.value.jwt
            }
            let fetch = fetchToken
            let task = Task { try await fetch() }
            inflight = task
            defer { inflight = nil }
            let minted = try await task.value
            cached = minted
            return minted.jwt
        }

        func invalidate() {
            cached = nil
        }
    }

    // MARK: Endpoint wire

    /// Build the token POST request. Split out so the wire serialization —
    /// method, headers, and the empty JSON body — is unit-testable without a
    /// network round-trip.
    static func _makeEndpointRequest(url: URL, headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        return request
    }

    private static func _postTokenEndpoint(
        url: URL, headers: [String: String]
    ) async throws -> MintedToken {
        let request = _makeEndpointRequest(url: url, headers: headers)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(
                for: request, delegate: RedirectRefusingDelegate()
            )
        } catch {
            throw TokenSourceError(
                code: .requestFailed,
                message: "token endpoint request failed: \(error.localizedDescription)"
            )
        }
        guard let http = response as? HTTPURLResponse else {
            throw TokenSourceError(
                code: .invalidResponse, message: "token endpoint: non-HTTP response"
            )
        }
        return try _decodeEndpointResponse(
            status: http.statusCode,
            data: data,
            location: http.value(forHTTPHeaderField: "Location")
        )
    }

    /// Refuses HTTP redirects on the token exchange. URLSession would
    /// otherwise follow a 30x silently — re-sending the auth headers (and
    /// receiving the JWT) wherever it points, including a plain-http
    /// downgrade that construction-time https validation cannot see.
    /// Task-scoped: no other URLSession behavior in the SDK changes.
    final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    /// Map one endpoint response onto a ``MintedToken`` or a
    /// ``TokenSourceError``: a 30x (delivered un-followed by
    /// ``RedirectRefusingDelegate``) is a refused request; a 2xx body that is
    /// not JSON or is missing ``jwt`` / ``expires_at`` is an invalid
    /// response; any other non-2xx is a rejection keeping the server's error
    /// slug when the body parses (else a synthetic ``http_<status>``).
    static func _decodeEndpointResponse(
        status: Int, data: Data, location: String? = nil
    ) throws -> MintedToken {
        if (300..<400).contains(status) {
            let target = location.map { " → \($0)" } ?? ""
            throw TokenSourceError(
                code: .requestFailed,
                message: "Token endpoint redirected (HTTP \(status)\(target)); redirects are "
                    + "refused so the exchange cannot leave the configured origin."
            )
        }
        guard (200..<300).contains(status) else {
            let (code, message) = parseErrorDetail(status: status, data: data)
            log.warning(
                "token source rejected status=\(status, privacy: .public) code=\(code, privacy: .public)"
            )
            throw TokenSourceError(code: .requestRejected, message: message, serverCode: code)
        }
        guard
            let decoded = try? JSONDecoder().decode(EndpointResponse.self, from: data),
            !decoded.jwt.isEmpty,
            let expiresAt = parseExpiresAt(decoded.expiresAt)
        else {
            throw TokenSourceError(
                code: .invalidResponse,
                message: "Token endpoint response missing jwt / expires_at."
            )
        }
        return MintedToken(jwt: decoded.jwt, expiresAt: expiresAt)
    }

    private struct EndpointResponse: Decodable {
        let jwt: String
        let expiresAt: String

        enum CodingKeys: String, CodingKey {
            case jwt
            case expiresAt = "expires_at"
            case expiresAtAlias = "expiresAt"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            jwt = try container.decode(String.self, forKey: .jwt)
            // ``expires_at`` is the wire shape (a forwarded mint response);
            // ``expiresAt`` is a serialized SDK ``MintedToken`` — a backend
            // returning its mint result as-is emits this spelling.
            if let canonical = try container.decodeIfPresent(String.self, forKey: .expiresAt) {
                expiresAt = canonical
            } else {
                expiresAt = try container.decode(String.self, forKey: .expiresAtAlias)
            }
        }
    }

    private static func parseExpiresAt(_ raw: String) -> Date? {
        RealtimeISO8601.date(from: raw)
    }
}
