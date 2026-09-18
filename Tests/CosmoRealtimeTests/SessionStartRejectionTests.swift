import Testing

@testable import CosmoRealtime

/// Session-start rejection bodies carry a machine-readable ``code`` the
/// transport must surface (``version_mismatch`` routing and typed
/// session-start errors depend on it).
@Suite struct SessionStartRejectionTests {

    @Test("external envelope code is extracted")
    func externalEnvelopeCode() {
        let body = """
            {"error": {"type": "api_error", "code": "invalid_tool_config", \
            "message": "Tool 'escalate' references queue X which does not exist."}}
            """
        #expect(rejectionCode(inBody: body) == "invalid_tool_config")
    }

    @Test("external envelope without a code yields nil")
    func externalEnvelopeWithoutCode() {
        let body = """
            {"error": {"type": "validation_error", "message": "Invalid request parameters"}}
            """
        #expect(rejectionCode(inBody: body) == nil)
    }

    @Test("internal detail shape still parses")
    func internalDetailShape() {
        let body = #"{"detail": {"code": "version_mismatch", "message": "upgrade"}}"#
        #expect(rejectionCode(inBody: body) == "version_mismatch")
    }

    @Test("non-JSON and unrelated bodies yield nil")
    func garbageBodies() {
        #expect(rejectionCode(inBody: "not json") == nil)
        #expect(rejectionCode(inBody: #"{"detail": "plain string"}"#) == nil)
    }
}

extension SessionStartRejectionTests {
    @Test("a rejection exposes its code and the server's slug for branching")
    func rejectionExposesCode() {
        // 422 with a config slug classifies as `config`; the server's own slug
        // stays readable beside it.
        let error = SessionStartError(
            code: classifyStartRejection(serverCode: "invalid_tool_config", status: 422),
            message: "Tool 'escalate' references queue X which does not exist.",
            status: 422,
            serverCode: "invalid_tool_config"
        )
        #expect(error.code == .config)
        #expect(error.status == 422)
        #expect(error.serverCode == "invalid_tool_config")
        #expect(error.errorDescription ==
            "config: Tool 'escalate' references queue X which does not exist.")
    }
}
