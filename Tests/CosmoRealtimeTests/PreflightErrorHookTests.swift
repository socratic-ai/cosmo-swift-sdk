import Foundation
import Testing
@testable import CosmoRealtime

/// Contract: `onError` fires exactly once per error occurrence, and by the
/// time it fires the model has settled into `.error` — hosts (macOS AppModel,
/// iOS SessionViewModel) run analytics capture and teardown from this hook,
/// so a double fire double-counts and a pre-transition fire forces hosts to
/// defer any state read.
@Suite struct PreflightErrorHookTests {

    private static func notSignedIn() -> AppErrorPresentation {
        AppErrorPresentation(
            headline: "Not signed in",
            message: "Sign in to your Cosmo workspace to start a session.",
            heardTranscript: nil,
            actions: [.signBackIn]
        )
    }

    @Test @MainActor func preflightErrorFiresOnErrorExactlyOnceWithStateSettled() {
        guard #available(macOS 14, iOS 17, *) else { return }
        let model = VoiceSessionModel()
        var fires = 0
        var stateAtFire: VoiceSessionState?
        model.hooks.onError = { [weak model] _ in
            fires += 1
            stateAtFire = model?.state
        }

        let presentation = Self.notSignedIn()
        model.markPreflightError(presentation)

        #expect(fires == 1)
        #expect(stateAtFire == .error(presentation))
    }

    /// A repeat failure with an identical presentation (e.g. two signed-out
    /// talk presses in a row) is a new occurrence: the state transition
    /// no-ops, but the host still needs the hook — it drives per-attempt
    /// analytics and mode cleanup (a dictation start that fails preflight
    /// relies on it to unlatch `dictationMode`).
    @Test @MainActor func repeatIdenticalPreflightErrorFiresAgain() {
        guard #available(macOS 14, iOS 17, *) else { return }
        let model = VoiceSessionModel()
        var fires = 0
        model.hooks.onError = { _ in fires += 1 }

        model.markPreflightError(Self.notSignedIn())
        model.markPreflightError(Self.notSignedIn())

        #expect(fires == 2)
    }
}
