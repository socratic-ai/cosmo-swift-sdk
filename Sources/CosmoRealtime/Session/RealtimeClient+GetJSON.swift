import Foundation
import HTTPTypes
import OpenAPIRuntime

extension RealtimeClient {
    /// Fetch a JSON body and decode it with the SDK's own type.
    ///
    /// The generated client decodes into `Components.Schemas` first, and those
    /// are `@frozen` raw-value enums: a status or credential kind the server
    /// added after this package shipped throws there, before anything the SDK
    /// wrote sees it, and the whole response is lost over one field the caller
    /// may never read. The SDK's own types decode the same body and carry an
    /// unrecognized value as `unknown`, so the two endpoints whose payloads
    /// carry a server-authored enum read the body themselves.
    ///
    /// The request still goes through the client's own transport, so timeouts,
    /// TLS policy and any injected transport apply exactly as they do to a
    /// generated call — only the decoding is ours. The headers are set here
    /// because middlewares belong to the generated `Client`: these two calls
    /// run none, so they carry what `BearerAuthMiddleware` would have added —
    /// the bearer token and the SDK identity every Cosmo REST call is
    /// attributable by.
    func _getDecodingOurselves<Value: Decodable, Failure: ApiErrorBuilding>(
        path: String,
        as _: Value.Type,
        failure _: Failure.Type
    ) async throws -> Value {
        var fields = HTTPFields()
        do {
            fields[.authorization] = "Bearer \(try await bearerToken())"
        } catch {
            throw Failure.transport(message: error.localizedDescription)
        }
        fields[BearerAuthMiddleware.sdkHeaderField] = sdkIdentityHeaderValue
        let request = HTTPRequest(method: .get, scheme: nil, authority: nil, path: path, headerFields: fields)

        let response: HTTPResponse
        let responseBody: HTTPBody?
        do {
            (response, responseBody) = try await transport.send(
                request,
                body: nil as HTTPBody?,
                baseURL: baseURL,
                operationID: "getDecodingOurselves"
            )
        } catch {
            throw Failure.transport(message: error.localizedDescription)
        }

        let data: Data
        do {
            if let responseBody {
                data = try await Data(collecting: responseBody, upTo: 1 << 20)
            } else {
                data = Data()
            }
        } catch {
            throw Failure.invalidResponse(message: error.localizedDescription)
        }

        guard (200..<300).contains(response.status.code) else {
            // A 401 carries ``{"detail": "..."}`` rather than the error
            // envelope, so it has no rejection code to read.
            if response.status.code == 401 {
                throw Self._unauthorized(
                    as: Failure.self,
                    try? JSONDecoder().decode(_AuthDetail.self, from: data).detail
                )
            }
            if let envelope = try? JSONDecoder().decode(_ErrorEnvelope.self, from: data) {
                throw Failure.rejected(code: envelope.error.code, detail: envelope.error.message)
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            let detail = body.isEmpty
                ? "HTTP \(response.status.code)"
                : "HTTP \(response.status.code): \(body)"
            throw Failure.rejected(code: rejectionCode(inBody: body), detail: detail)
        }

        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw Failure.invalidResponse(message: error.localizedDescription)
        }
    }
}

/// The auth layer's 401 body.
private struct _AuthDetail: Decodable {
    let detail: String?
}

/// The error envelope every typed rejection carries.
private struct _ErrorEnvelope: Decodable {
    struct Body: Decodable {
        let code: String?
        let message: String
    }
    let error: Body
}
