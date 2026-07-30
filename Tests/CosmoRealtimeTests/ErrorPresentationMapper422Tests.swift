import Foundation
import Testing
@testable import CosmoRealtime

/// HTTP 422 at session start is request validation (a malformed session
/// request), not an auth failure — re-signing in cannot fix it. These tests
/// pin that 422 never presents as auth and never offers "Sign back in".
@Suite struct ErrorPresentationMapper422Tests {

    @Test func handshake422IsNotPresentedAsAuth() {
        let presentation = ErrorPresentationMapper.presentation(
            VoiceClientError.handshakeFailed(status: 422, body: nil),
            heardTranscript: "open slack"
        )
        #expect(presentation.headline == "Couldn't start the session")
        #expect(presentation.kind == .other)
        #expect(presentation.actions == [.retry, .revealLogs])
        #expect(!presentation.actions.contains(.signBackIn))
        #expect(presentation.heardTranscript == "open slack")
    }

    @Test func closeReason422IsNotPresentedAsAuth() {
        let presentation = ErrorPresentationMapper.presentation(
            ConnectionCloseReason.handshakeFailed(status: 422)
        )
        #expect(presentation.headline == "Couldn't start the session")
        #expect(presentation.kind == .other)
        #expect(!presentation.actions.contains(.signBackIn))
    }

    @Test func describe422SaysRejectedNotAuthFailed() {
        let described = ErrorPresentationMapper.describe(.handshakeFailed(status: 422))
        #expect(described == "Session request rejected (HTTP 422).")
        #expect(!described.contains("Auth"))
    }

    @Test func otherStatusesKeepAuthPresentation() {
        let presentation = ErrorPresentationMapper.presentation(
            VoiceClientError.handshakeFailed(status: 500, body: nil)
        )
        #expect(presentation.headline == "Couldn't authenticate (HTTP 500)")
        #expect(presentation.kind == .auth)
    }
}
