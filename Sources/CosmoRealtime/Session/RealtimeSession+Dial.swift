import Foundation

/// How far a dial got before it failed.
///
/// Closed: every one is thrown by this SDK, so it changes only when the SDK
/// does. It says what happened to the attempt, never why the server refused —
/// that is the server's own slug, an open set, on ``ApiError/serverCode``.
public enum DialErrorCode: String, Sendable, Equatable {
    /// The request did not produce a usable answer — a network failure or
    /// timeout, or a redirect, which is refused rather than followed so a
    /// credential is never re-sent to another origin.
    case requestFailed = "request_failed"
    /// The server refused. ``ApiError/serverCode`` carries its own slug for why.
    case requestRejected = "request_rejected"
    /// The server answered, but not with a body this SDK could parse.
    case invalidResponse = "invalid_response"
    /// The SDK refused to send the request — a malformed phone number, or a
    /// session that cannot be dialed. Nothing reached the server.
    case invalidRequest = "invalid_request"
}

/// Outcome of ``RealtimeSession/dial(phoneNumber:callerNumber:)``
/// (POST `session/{id}/dial`): the dial was queued. The call rings
/// asynchronously — observe progress via session events, not this value.
public struct DialResult: Codable, Hashable, Sendable {
    /// Handle for this dial, to correlate the call with server-side dial
    /// status.
    public var dialId: UUID
    init(dialId: UUID) {
        self.dialId = dialId
    }
    enum CodingKeys: String, CodingKey {
        case dialId = "dial_id"
    }
}

/// ``RealtimeSession/dial(phoneNumber:callerNumber:)`` failed.
public struct DialError: ApiError, LocalizedError, Sendable, Equatable {
    /// How far the attempt got. A closed set this SDK throws — switch on it.
    public let code: DialErrorCode
    /// Human-readable explanation, for logs and display.
    public let message: String
    /// The server's own rejection slug when it sent one — `phone_calls_disabled`,
    /// `minute_limit_exceeded`, `session_not_found`, … `nil` when no server
    /// verdict was parsed.
    public let serverCode: String?

    /// A dial failure with its cross-SDK code and message.
    public init(code: DialErrorCode, message: String, serverCode: String? = nil) {
        self.code = code
        self.message = message
        self.serverCode = serverCode
    }

    /// The code and message, for `LocalizedError` presentation.
    public var errorDescription: String? {
        message.isEmpty ? code.rawValue : "\(code.rawValue): \(message)"
    }
}

extension RealtimeSession {

    /// Place an outbound phone call into this running session.
    ///
    /// No start-time flag is needed — the server derives phone handling
    /// from the dialed leg itself. POSTs ``phoneNumber`` (and the
    /// optional ``callerNumber``) to the session's dial endpoint and returns
    /// a ``DialResult`` carrying the server-minted dial id. To end the
    /// call, call ``end()``, or grant the agent hang-up with
    /// ``AgentTool/endCallTool()``.
    ///
    /// Both numbers are validated as E.164 (``+`` followed by 8–15 digits)
    /// before the request. Throws ``DialError`` with code
    /// ``DialErrorCode/invalidRequest`` on a malformed number,
    /// ``SessionStateError`` outside an active session, and ``DialError``
    /// carrying the server's slug on ``ApiError/serverCode`` on a rejection.
    public func dial(phoneNumber: String, callerNumber: String? = nil) async throws -> DialResult {
        try _assertSendable()
        try validateE164(phoneNumber, field: "phone_number")
        if let callerNumber {
            try validateE164(callerNumber, field: "caller_number")
        }
        guard let client, let sessionId else {
            throw SessionStateError(code: .notConnected, message: "RealtimeSession is not connected.")
        }
        guard client.sessionTransport != .websocket else {
            throw DialError(
                code: .invalidRequest,
                message: "dial is not available on the local websocket transport"
            )
        }

        let request: URLRequest
        do {
            request = try await Self._makeDialRequest(
                client: client,
                sessionId: sessionId,
                phoneNumber: phoneNumber,
                callerNumber: callerNumber
            )
        } catch {
            throw DialError(code: .requestFailed, message: error.localizedDescription)
        }

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = client.requestTimeout
        configuration.timeoutIntervalForResource = client.requestTimeout
        let session = makeRESTSession(
            configuration: configuration,
            verifyTLS: client.verifyTLS,
            host: client.baseURL.host
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DialError(code: .requestFailed, message: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DialError(code: .invalidResponse, message: "dial: non-HTTP response")
        }
        switch http.statusCode {
        case 200..<300:
            do {
                return try JSONDecoder().decode(DialResult.self, from: data)
            } catch {
                throw DialError(
                    code: .invalidResponse,
                    message: "dial response decode failed: \(error.localizedDescription)"
                )
            }
        default:
            // Every rejection carries a typed ``{code, message}`` body — 422
            // schema errors and business rejections alike (400
            // caller_number_not_available, 403 minute_limit_exceeded, 409
            // ended/already-dialed). Surface the code for all of them so a
            // caller can tell "unavailable caller-ID" from "out of minutes",
            // matching the TypeScript and Python SDKs.
            let rejection = parseErrorDetail(status: http.statusCode, data: data)
            throw DialError(
                code: .requestRejected,
                message: rejection.message.isEmpty
                    ? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                    : rejection.message,
                serverCode: rejection.code
            )
        }
    }

    /// The dial request body — ``caller_number`` stays off the wire when nil.
    struct DialRequestBody: Encodable {
        let phoneNumber: String
        let callerNumber: String?
        enum CodingKeys: String, CodingKey {
            case phoneNumber = "phone_number"
            case callerNumber = "caller_number"
        }
    }

    /// Build the dial POST request. Split out so the wire serialization —
    /// endpoint path, bearer auth header, and the JSON body — is unit-testable
    /// without a network round-trip (the dial endpoint has no generated client
    /// enforcing its shape).
    static func _makeDialRequest(
        client: RealtimeClient,
        sessionId: String,
        phoneNumber: String,
        callerNumber: String?
    ) async throws -> URLRequest {
        var request = URLRequest(
            url: client.baseURL.appending(
                path: "api/v1/external/realtime/session/\(sessionId)/dial"
            )
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(try await client.bearerToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(sdkIdentityHeaderValue, forHTTPHeaderField: "X-Cosmo-SDK")
        request.httpBody = try JSONEncoder().encode(
            DialRequestBody(phoneNumber: phoneNumber, callerNumber: callerNumber)
        )
        return request
    }
}

/// Validate a phone number as E.164: ``+`` then 8–15 digits. Throws
/// ``SessionStateError`` naming ``field`` on a mismatch.
func validateE164(_ number: String, field: String) throws {
    let isValid: Bool = {
        guard number.hasPrefix("+") else { return false }
        let digits = number.dropFirst()
        return (8...15).contains(digits.count)
            && digits.allSatisfy { $0.isNumber && $0.isASCII }
    }()
    guard isValid else {
        throw DialError(code: .invalidRequest, message: 
            "\(field) must be E.164 (a '+' followed by 8–15 digits): \(number)"
        )
    }
}
