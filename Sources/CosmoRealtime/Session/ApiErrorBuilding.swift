import CosmoRealtimeAPI
import Foundation
import OpenAPIRuntime

/// Builds the three failures every backend call can produce, so the
/// generated-client error mapping is written once. Separate from ``ApiError``,
/// which is what a caller catches: this is the construction side, and only the
/// per-call types that go through ``RealtimeClient/_run(as:_:)`` adopt it.
protocol ApiErrorBuilding: ApiError {
    static func rejected(code: String?, detail: String) -> Self
    static func transport(message: String) -> Self
    static func invalidResponse(message: String) -> Self
}

extension RealtimeClient {
    /// Run one generated call, splitting success-body decode failures from
    /// genuine transport failures (see ``_isSuccessBodyDecodeFailure``).
    func _run<Output, Failure: ApiErrorBuilding>(
        as _: Failure.Type,
        _ call: () async throws -> Output
    ) async throws -> Output {
        do {
            return try await call()
        } catch {
            if Self._isSuccessBodyDecodeFailure(error) {
                throw Failure.invalidResponse(message: error.localizedDescription)
            }
            throw Failure.transport(message: error.localizedDescription)
        }
    }

    static func _undocumented<Failure: ApiErrorBuilding>(
        as _: Failure.Type,
        _ statusCode: Int,
        _ payload: OpenAPIRuntime.UndocumentedPayload
    ) async -> Failure {
        let body = await _collectBody(payload)
        let detail = body.isEmpty ? "HTTP \(statusCode)" : "HTTP \(statusCode): \(body)"
        return .rejected(code: rejectionCode(inBody: body), detail: detail)
    }

    /// Map a documented auth-layer 401. Its body is ``{"detail": "..."}`` —
    /// never the error envelope — so there is no rejection code to parse.
    static func _unauthorized<Failure: ApiErrorBuilding>(
        as _: Failure.Type,
        _ detail: String?
    ) -> Failure {
        .rejected(code: nil, detail: detail ?? "HTTP 401")
    }

    static func _rejected<Failure: ApiErrorBuilding>(
        as _: Failure.Type,
        _ envelope: Components.Schemas.ErrorEnvelope?
    ) -> Failure {
        guard let envelope else {
            return .rejected(code: nil, detail: "Unprocessable content")
        }
        return .rejected(code: envelope.error.code, detail: envelope.error.message)
    }
}
