import Testing

@testable import CosmoRealtime

/// `RealtimeError` carries `message`, so a caller that catches the family
/// without narrowing to a concrete type still has something to log. Reading it
/// through `any RealtimeError` is the point — narrowing first would test each
/// type's own property rather than the protocol requirement.
@Suite struct RealtimeErrorTests {

    private func message(of error: any RealtimeError) -> String { error.message }

    @Test func structuredErrorsReportTheirMessage() {
        #expect(
            message(of: MintTokenError(code: .missingApiKey, message: "no key")) == "no key"
        )
        #expect(
            message(of: AudioUnavailableError(message: "no input device"))
                == "no input device"
        )
        #expect(
            message(of: ToolDefinitionError(code: .forbiddenKey, message: "$ref is not allowed"))
                == "$ref is not allowed"
        )
    }

    @Test("one catch covers any backend call")
    func everyBackendCallErrorIsAnApiError() {
        // The headline of the ApiError base. Reading through `any ApiError`
        // is the point — narrowing first would test each type's own members.
        let calls: [any ApiError] = [
            MintTokenError(code: .missingApiKey, message: "no key"),
            TokenSourceError(code: .fetcherFailed, message: "callable threw"),
            VerifyError(code: .requestFailed, message: "socket closed"),
            UsageError(code: .invalidRequest, message: "no usage surface"),
            DialError(code: .invalidRequest, message: "bad number"),
        ]
        for error in calls {
            #expect(error.serverCode == nil)
            #expect(!error.message.isEmpty)
        }
    }

    @Test func caseCarryingErrorsReportTheirMessage() {
        #expect(message(of: CredentialsError(code: .expired, message: "key expired")) == "key expired")
        // The server's prose alone. Python and TypeScript put the same value
        // on ``message`` for this response and compose the code into the
        // rendered form instead, which is what ``errorDescription`` does here.
        #expect(
            message(of: UsageError.rejected(code: "not_found", detail: "no such session"))
                == "no such session"
        )
        #expect(
            message(of: SessionStartError(code: .readyTimeout, message: "ready timeout"))
                == "ready timeout"
        )
    }

    @Test("message is the prose; errorDescription may compose")
    func presentationComposesWhereMessageDoesNot() {
        // ``message`` is the value the sibling SDKs put on their own
        // ``message``, so a cross-SDK caller reads the same string.
        // ``errorDescription`` is free to add the code and the origin, which is
        // what those SDKs render from ``str(e)`` / the thrown Error.
        let usage = UsageError.transport(message: "socket closed")
        #expect(usage.message == "socket closed")
        #expect(usage.errorDescription == "request_failed: socket closed")

        let verify = VerifyError.rejected(code: "unauthorized", detail: "bad key")
        #expect(verify.message == "bad key")
        #expect(verify.errorDescription == "request_rejected: bad key")
        #expect(verify.serverCode == "unauthorized")

        // Where nothing is composed the two agree.
        let credentials = CredentialsError(code: .fileInvalid, message: "not TOML")
        #expect(credentials.errorDescription == credentials.message)

        let mint = MintTokenError(code: .requestFailed, message: "timed out")
        #expect(mint.errorDescription == mint.message)
    }
}
