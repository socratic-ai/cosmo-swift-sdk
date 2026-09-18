import Foundation

/// Extract the protocol error code from a rejection body: the external
/// envelope (``{"error": {"code": "...", ...}}``), falling back to the
/// internal FastAPI shape (``{"detail": {"code": "...", ...}}``).
package func rejectionCode(inBody body: String) -> String? {
    struct Rejection: Decodable {
        struct Slugged: Decodable {
            let code: String?
        }
        let error: Slugged?
        let detail: Slugged?
    }
    guard let rejection = try? JSONDecoder().decode(Rejection.self, from: Data(body.utf8))
    else { return nil }
    return rejection.error?.code ?? rejection.detail?.code
}

/// Extract the server's ``(code, message)`` from a rejection body, mirroring
/// the reference SDKs' ``parseErrorDetail``: a typed ``code`` when the
/// envelope carries one, else the envelope's ``type``; a body that does not
/// parse falls back to a synthetic ``http_<status>``.
///
/// The fuller counterpart to ``rejectionCode(inBody:)``, which reads only the
/// typed ``code`` and so cannot name a rejection that carries a ``type``
/// alone — an under-scoped api key's ``api_error`` among them.
package func parseErrorDetail(status: Int, data: Data) -> (code: String, message: String) {
    let fallback = "http_\(status)"
    let text = String(String(data: data, encoding: .utf8)?.prefix(500) ?? "")
    guard
        let payload = try? JSONDecoder().decode(JSONValue.self, from: data),
        case .object(let object) = payload
    else {
        return (fallback, text)
    }

    if case .object(let error)? = object["error"] {
        if case .string(let code)? = error["code"], case .string(let message)? = error["message"] {
            return (code, message)
        }
        if case .object(let typed)? = error["message"], typed["code"] != nil {
            return (stringified(typed["code"]), stringified(typed["message"]))
        }
        var type = fallback
        if case .string(let value)? = error["type"], !value.isEmpty { type = value }
        if case .string(let message)? = error["message"] {
            return (type, message)
        }
        return (type, text)
    }

    if case .object(let detail)? = object["detail"], detail["code"] != nil {
        return (stringified(detail["code"]), stringified(detail["message"]))
    }
    if case .string(let detail)? = object["detail"] {
        return (fallback, detail)
    }
    return (fallback, text)
}

private func stringified(_ value: JSONValue?) -> String {
    switch value {
    case .string(let v): return v
    case .int(let v): return String(v)
    case .double(let v): return String(v)
    case .bool(let v): return String(v)
    case .null, .array, .object, .none: return ""
    }
}

/// The server's ``Retry-After`` in whole seconds, when it sent one as a delay,
/// never below zero.
///
/// The HTTP-date form is ignored: the SDK reports what the server asked for,
/// not a value derived from a clock it does not share — the same rule Python
/// and TypeScript apply. Both transports read the header through here, so
/// there is one place for this to be right.
package func retryAfterSeconds(header raw: String?) -> Int? {
    guard let raw, let seconds = Int(raw.trimmingCharacters(in: .whitespaces)) else {
        return nil
    }
    return max(0, seconds)
}
