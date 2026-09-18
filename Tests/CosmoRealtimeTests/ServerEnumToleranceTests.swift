import Foundation
import Testing

@testable import CosmoRealtime

/// A server value this package does not name is data, not a failure.
///
/// The enums the server authors are the server's sets, not this SDK's. A
/// deployment newer than an installed package can send a value it has never
/// heard of, and the external-contract rule requires that tolerance ship
/// before the server may emit one. Without it a closed enum costs the whole
/// event, not just its field.
@Suite("Server enum tolerance")
struct ServerEnumToleranceTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test("an unrecognized error code arrives verbatim, with the event intact")
    func unknownErrorCode() throws {
        let event = try decode(
            ErrorEvent.self,
            #"{"type":"error","code":"quota_exhausted","message":"out of minutes","fatal":true}"#
        )
        #expect(event.code == .unknown("quota_exhausted"))
        #expect(event.code.rawValue == "quota_exhausted")
        // The point: the rest of the event survives too.
        #expect(event.message == "out of minutes")
        #expect(event.fatal == true)
    }

    @Test("a code this version names still decodes to its own case")
    func knownErrorCode() throws {
        let event = try decode(
            ErrorEvent.self,
            #"{"type":"error","code":"upstream_disconnect","message":"provider dropped"}"#
        )
        #expect(event.code == .upstreamDisconnect)
    }

    @Test("allCases lists the known codes, not the catch-all")
    func allCasesExcludesUnknown() {
        #expect(ErrorCode.allCases.count == 7)
        #expect(!ErrorCode.allCases.contains(.unknown("quota_exhausted")))
    }

    @Test("a known wire value never decodes into the catch-all")
    func knownValuesNeverBecomeUnknown() {
        // ``init(rawValue:)`` resolves against the known set first, so the
        // catch-all only ever holds a value this version really does not
        // name. Equality is the raw value's, so a hand-built
        // ``.unknown("auth_failed")`` compares equal to ``.authFailed`` —
        // one wire value, one meaning — but decoding never builds one.
        for known in ErrorCode.allCases {
            if case .unknown = ErrorCode(rawValue: known.rawValue) {
                Issue.record("\(known.rawValue) decoded into the catch-all")
            }
        }
    }

    @Test("an unknown code round-trips back to the wire unchanged")
    func unknownRoundTrips() throws {
        let event = try decode(
            ErrorEvent.self,
            #"{"type":"error","code":"quota_exhausted","message":"x"}"#
        )
        let reencoded = try JSONEncoder().encode(event)
        let asJSON = try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        #expect(asJSON?["code"] as? String == "quota_exhausted")
    }

    @Test("the status enums tolerate a value this version predates")
    func unknownStatuses() {
        // Each is the server's set. Before tolerance a @frozen enum threw on
        // decode, so one new server state failed the whole `getUsage` call —
        // including the counters the caller actually wanted.
        #expect(SessionStatus(rawValue: "cancelled") == .unknown("cancelled"))
        #expect(UsageStatus(rawValue: "estimating") == .unknown("estimating"))
        #expect(CredentialKind(rawValue: "service_account") == .unknown("service_account"))

        // The known values still resolve to their own cases.
        #expect(SessionStatus(rawValue: "completed") == .completed)
        #expect(UsageStatus(rawValue: "recorded") == .recorded)
        #expect(CredentialKind(rawValue: "api_key") == .apiKey)

        // And the catch-all stays out of the iterable set.
        #expect(SessionStatus.allCases.count == 3)
        #expect(UsageStatus.allCases.count == 3)
        #expect(CredentialKind.allCases.count == 2)
    }
}
