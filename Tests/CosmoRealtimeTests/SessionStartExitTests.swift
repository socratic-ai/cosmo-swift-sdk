import Foundation
import Testing

@testable import CosmoRealtime

/// Which ``SessionStartErrorCode`` each way out of `start()` carries.
///
/// The rejection vectors pin the classifier — server slug plus status to a
/// code — but the classifier only sees rejections. The other exits never reach
/// it, so nothing pinned them, and four of the ten codes were unreachable in
/// this SDK while Python and TypeScript produced all ten. Python's
/// `test_session_start.py` and TypeScript's `agent_start.test.ts` assert the
/// same table.
@Suite struct SessionStartExitTests {
    private func startFailure(_ scripted: SessionStartFailure) async -> SessionStartError? {
        let transport = FakeSessionTransport()
        await transport.scriptRejection(scripted)
        let session = RealtimeSession(transport: transport)
        do {
            try await session._start(config: SessionConfig())
            return nil
        } catch let error as SessionStartError {
            return error
        } catch {
            return nil
        }
    }

    @Test("a start that never reached a server verdict is `transport`")
    func transportExit() async {
        let error = await startFailure(.transport(message: "connection refused"))
        // Not `rejected`: nothing happened server-side, so the documented
        // advice for `transport` — retrying is safe — has to hold.
        #expect(error?.code == .transport)
        #expect(error?.status == nil)
        #expect(error?.serverCode == nil)
    }

    @Test("a room join that failed after the server accepted is `joinFailed`")
    func joinFailedExit() async {
        let error = await startFailure(.joinFailed(message: "room connect timed out"))
        #expect(error?.code == .joinFailed)
        #expect(error?.status == nil)
    }

    @Test("a server rejection keeps its slug and status")
    func rejectedExit() async {
        let error = await startFailure(
            .rejected(status: 402, code: "free_minutes_exhausted", detail: "spent"))
        #expect(error?.code == .entitlement)
        #expect(error?.status == 402)
        #expect(error?.serverCode == "free_minutes_exhausted")
    }

    @Test("a rejection the classifier does not know falls back to `rejected`")
    func unknownRejectionExit() async {
        let error = await startFailure(
            .rejected(status: 409, code: "some_future_code", detail: "nope"))
        #expect(error?.code == .rejected)
        #expect(error?.serverCode == "some_future_code")
    }

    @Test("a 503 is `voiceDisabled` whatever slug rides with it")
    func voiceDisabledExit() async {
        let error = await startFailure(.rejected(status: 503, code: nil, detail: "off"))
        #expect(error?.code == .voiceDisabled)
    }

    @Test("a capability the transport lacks is `config`, with the slug readable")
    func unsupportedCapabilityExit() async {
        // The slug is the whole verdict here — no server was involved — so it
        // has to reach `serverCode` rather than being spelled into the prose.
        let error = await startFailure(
            .unsupportedCapability(
                code: "background_tools_unsupported",
                detail: "background client tools are not supported by the websocket transport"))
        #expect(error?.code == .config)
        #expect(error?.serverCode == "background_tools_unsupported")
        #expect(error?.status == nil)
    }

    @Test("a busy rejection carries `Retry-After` through to the error")
    func retryAfterReachesTheError() async {
        // The parser is unit-tested below; this is the seam that was broken —
        // the header reaching `SessionStartError` from a real start.
        let error = await startFailure(
            .rejected(
                status: 429, code: "concurrent_session_limit", detail: "busy",
                retryAfterSeconds: 30))
        #expect(error?.code == .busy)
        #expect(error?.retryAfterSeconds == 30)
    }

    @Test("a rejection's structured extras reach the caller")
    func rejectionExtrasReachTheCaller() async {
        // The transport parses the body while it still has it: `detail` is
        // rendered for humans and may carry an `HTTP <status>:` prefix, so
        // re-parsing it downstream yielded nil and the extras were lost.
        // The external envelope the backend actually sends: the typed code and
        // the billing extras ride together inside `error`.
        let body =
            #"{"error":{"type":"api_error","code":"free_minutes_exhausted","message":"spent","granted_minutes":30,"used_minutes":30}}"#
        let error = await startFailure(
            .rejected(
                status: 402, code: "free_minutes_exhausted",
                detail: "HTTP 402: \(body)",
                rejection: SessionStartRejection.from(body: Data(body.utf8))))

        #expect(error?.code == .entitlement)
        #expect(error?.detail?.grantedMinutes == 30)
        #expect(error?.detail?.usedMinutes == 30)
    }

    @Test("a rejection with no status keeps its slug")
    func statuslessRejectionKeepsItsSlug() async {
        let error = await startFailure(
            .rejected(status: nil, code: "some_slug", detail: "refused"))
        #expect(error?.serverCode == "some_slug")
    }

    @Test("`Retry-After` is parsed as whole seconds, and only as a delay")
    func retryAfterParsing() {
        // Both transports read the header through this one helper — the
        // duplicated inline parse is what let the field be half-fixed twice.
        #expect(retryAfterSeconds(header: "30") == 30)
        #expect(retryAfterSeconds(header: " 30 ") == 30)
        // The HTTP-date form is ignored, matching Python: the SDK reports what
        // the server asked for, never a value derived from an unshared clock.
        #expect(retryAfterSeconds(header: "Wed, 21 Oct 2026 07:28:00 GMT") == nil)
        #expect(retryAfterSeconds(header: nil) == nil)
    }
}
