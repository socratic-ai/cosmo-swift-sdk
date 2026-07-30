import Foundation

/// The client-tool RPC reply contract: the `{ok, result, error}` envelope and
/// the transport's ceiling on its serialized size. Public so a tool pack can
/// bound its replies against the values the transport enforces instead of
/// copying them.
public enum ClientToolReply {
    /// Ceiling on one serialized reply envelope. The transport truncates
    /// error text to fit and fails an oversized success result closed as an
    /// error reply.
    public static let maxBytes = 15 * 1024

    /// The `{ok, result, error}` envelope, serialized to JSON. Does not
    /// itself enforce ``maxBytes``: callers that can produce large results
    /// must bound the payload first.
    public static func envelope(
        ok: Bool, result: [String: JSONValue]? = nil, error: String? = nil
    ) -> String {
        guard let data = try? JSONEncoder().encode(object(ok: ok, result: result, error: error))
        else {
            return #"{"ok":false,"result":null,"error":"reply encode failed"}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// A reply string returned through the string-based RPC dispatcher
    /// (``ClientToolRPCHandler``) is decoded and re-wrapped as the `result`
    /// of a fresh `{ok: true}` envelope, and the transport enforces
    /// ``maxBytes`` on that outer form. The serialized size of that outer
    /// envelope for a reply built from these parts — bound dispatcher
    /// replies against this, not against the inner envelope's own size.
    public static func rewrappedSize(
        ok: Bool, result: [String: JSONValue]? = nil, error: String? = nil
    ) -> Int {
        envelope(ok: true, result: object(ok: ok, result: result, error: error)).utf8.count
    }

    private static func object(
        ok: Bool, result: [String: JSONValue]?, error: String?
    ) -> [String: JSONValue] {
        [
            "ok": .bool(ok),
            "result": result.map(JSONValue.object) ?? .null,
            "error": error.map(JSONValue.string) ?? .null,
        ]
    }
}
