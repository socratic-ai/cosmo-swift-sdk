import LiveKit
import Testing

@testable import CosmoRealtime

/// Which publish failure is a microphone failure. Read off the failure's own
/// type, never off the host's permissions: a machine with no input device
/// would otherwise relabel every publish failure as a microphone one, and
/// `startAudioStream` — whose whole purpose is audio the SDK does not capture
/// — runs through the same path on exactly those hosts.
@Suite struct AudioUnavailableTests {

    @Test func refusedCaptureIsNamed() {
        #expect(
            LiveKitSessionTransport.captureFailureCode(LiveKitError(.deviceAccessDenied))
                == .micDenied
        )
    }

    @Test("a missing device is not claimed — the vendor raises deviceNotFound for cameras")
    func missingDeviceIsNotClaimed() {
        // The audio device module reports a host with no input device as an
        // engine fault, indistinguishable from any other. Naming it
        // mic_not_found would be a guess, and would hand a Swift consumer a
        // code nothing produces. `deviceNotFound` is the vendor's camera
        // fault — its neighbours are capture-format and FPS-range errors.
        #expect(LiveKitSessionTransport.captureFailureCode(LiveKitError(.deviceNotFound)) == nil)
    }

    @Test("an unattributed audio fault is still an audio failure")
    func audioFaultIsNamedGenerically() {
        // Not knowing *which* device fault it was is what `audio_unavailable`
        // is for. Returning nil here made the same condition a
        // `SessionStartError` on this carrier and an `AudioUnavailableError`
        // on the websocket one, which is the divergence the closed codes exist
        // to remove.
        #expect(
            LiveKitSessionTransport.captureFailureCode(LiveKitError(.audioEngine))
                == .audioUnavailable
        )
        #expect(
            LiveKitSessionTransport.captureFailureCode(LiveKitError(.audioSession))
                == .audioUnavailable
        )
    }

    @Test("a publish failure that is not about the device is not a microphone failure")
    func unrelatedLiveKitFailureIsNotClaimed() {
        #expect(LiveKitSessionTransport.captureFailureCode(LiveKitError(.network)) == nil)
        #expect(LiveKitSessionTransport.captureFailureCode(LiveKitError(.invalidState)) == nil)
    }

    @Test("an error from outside the transport is passed through untouched")
    func foreignErrorIsNotClaimed() {
        struct Scripted: Error {}
        #expect(LiveKitSessionTransport.captureFailureCode(Scripted()) == nil)
    }

    @Test("the error carries the slug and renders it")
    func errorShape() {
        let err = AudioUnavailableError(message: "no input device", code: .micNotFound)
        #expect(err.code == .micNotFound)
        #expect(err.message == "no input device")
        #expect(err.errorDescription == "mic_not_found: no input device")
    }

    @Test("the default slug is the unattributed one")
    func defaultCode() {
        #expect(AudioUnavailableError(message: "portaudio missing").code == .audioUnavailable)
    }
}
