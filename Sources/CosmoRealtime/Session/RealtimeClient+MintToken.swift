import CosmoRealtimeAPI
import Foundation
import OpenAPIRuntime

extension RealtimeClient {
    /// Mint a short-lived per-user JWT for `externalUserId` (POST auth/token).
    /// Run this server-side with an api-key credential — a workspace API key
    /// never belongs in a shipped app. Hand the returned
    /// ``MintedToken/jwt`` to the end user's device, which constructs
    /// ``RealtimeClient/init(token:baseURL:connectTimeout:requestTimeout:verifyTLS:)``
    /// and starts a session. Idempotent per
    /// `(workspace, externalUserId)` — the same external user maps to the same
    /// auto-provisioned project on repeat calls. `ttlSeconds` (60–86400)
    /// shortens the 24-hour default lifetime.
    ///
    /// Throws ``MintTokenError`` if the client holds no api key, the server
    /// rejects the request, the transport fails, or the response body cannot
    /// be decoded.
    public func mintToken(
        _ externalUserId: String, ttlSeconds: Int? = nil
    ) async throws -> MintedToken {
        guard _hasApiKey else {
            throw MintTokenError(
                code: .missingApiKey,
                message: "mintToken requires an api-key credential; this client holds a "
                    + "minted user token, which cannot mint."
            )
        }
        let output: CosmoRealtimeAPI.Operations.MintProjectToken.Output
        do {
            output = try await _mint(externalUserId: externalUserId, ttlSeconds: ttlSeconds)
        } catch {
            throw MintTokenError(
                code: RealtimeClient._isSuccessBodyDecodeFailure(error)
                    ? .invalidResponse : .requestFailed,
                message: error.localizedDescription
            )
        }
        switch output {
        case .ok(let ok):
            let response = try ok.body.json
            guard !response.jwt.isEmpty else {
                throw MintTokenError(
                    code: .invalidResponse,
                    message: "Mint-token response missing jwt / expires_at."
                )
            }
            return MintedToken(
                jwt: response.jwt,
                expiresAt: response.expiresAt,
                tokenId: response.tokenId
            )
        case .unauthorized(let err):
            // The auth layer's body is ``{"detail": "..."}`` — never the
            // error envelope — so there is no server slug to lift.
            throw Self._rejection(
                message: (try? err.body.json.detail) ?? "HTTP 401", status: 401, serverCode: nil
            )
        case .unprocessableContent(let err):
            throw Self._envelopeRejection(try? err.body.json)
        case .undocumented(let statusCode, let payload):
            if (300..<400).contains(statusCode) {
                // Delivered un-followed by the REST session's delegate. The
                // exchange never reached the mint endpoint, so it failed
                // rather than being rejected — the classification the other
                // SDKs give it.
                throw MintTokenError(
                    code: .requestFailed,
                    message: "Mint-token endpoint redirected (HTTP \(statusCode)); redirects "
                        + "are refused so the credential cannot leave the configured origin."
                )
            }
            let body = await RealtimeClient._collectBody(payload)
            if body.isEmpty {
                throw Self._rejection(
                    message: "HTTP \(statusCode)", status: statusCode, serverCode: nil
                )
            }
            // The full envelope parser, not ``rejectionCode(inBody:)``: an
            // under-scoped key's 403 carries ``type: api_error`` and no
            // ``code``, and the reference SDKs surface that type as the slug.
            let (code, message) = parseErrorDetail(status: statusCode, data: Data(body.utf8))
            throw MintTokenError(
                code: .requestRejected, message: message, serverCode: code
            )
        }
    }

    private static func _envelopeRejection(
        _ envelope: CosmoRealtimeAPI.Components.Schemas.ErrorEnvelope?
    ) -> MintTokenError {
        guard let envelope else {
            return _rejection(message: "Unprocessable content", status: 422, serverCode: nil)
        }
        // A validation rejection carries no ``code``; its ``type`` is the
        // slug the reference SDKs surface for it.
        return _rejection(
            message: envelope.error.message,
            status: 422,
            serverCode: envelope.error.code ?? envelope.error._type
        )
    }

    /// A server refusal. ``serverCode`` is the server's own slug when the
    /// rejection carried one, else the ``http_<status>`` synthetic the other
    /// SDKs fall back to — so a caller always has something to branch on.
    private static func _rejection(
        message: String, status: Int, serverCode: String?
    ) -> MintTokenError {
        MintTokenError(
            code: .requestRejected,
            message: message,
            serverCode: serverCode ?? "http_\(status)"
        )
    }

    /// The single generated mint call. Isolated so an operationId cleanup that
    /// renames the method is a one-line change.
    private func _mint(
        externalUserId: String, ttlSeconds: Int?
    ) async throws -> CosmoRealtimeAPI.Operations.MintProjectToken.Output {
        try await _apiClient().mintProjectToken(
            body: .json(.init(externalUserId: externalUserId, ttlSeconds: ttlSeconds))
        )
    }
}
