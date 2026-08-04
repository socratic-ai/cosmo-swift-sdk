import Foundation
import os.lock
import Testing
import LiveKit
@testable import CosmoRealtime

/// Mirrors the legacy ``ScreenShareStateTests`` for the new external-
/// protocol surface: the screen-share lock-state machine now lives in
/// ``LiveKitSessionTransport`` (it owns the room), so the publish-failure
/// recovery invariants are asserted there. These drive the production
/// ``handleScreenSharePublishFailure(_:capturedState:)`` helper directly —
/// the same code the deferred-publish catch block runs — so the
/// identity guard (``current === capturedState``) is exercised offline,
/// not just via the LiveKit-gated E2E suite. Runs fully offline — no
/// LiveKit server, no real publish.
@Suite("Session screen-share publish-failure recovery")
struct SessionScreenShareTests {

    private struct SimulatedError: Error, LocalizedError {
        var errorDescription: String? { "simulated publish error" }
    }

    private func makeTransport() -> LiveKitSessionTransport {
        LiveKitSessionTransport(
            options: RealtimeSession.Options(
                apiKey: "test-key"
            )
        )
    }

    @Test("publish-failure recovery clears the screen-share lock")
    func publishFailureClearsLock() async throws {
        // After the deferred publish task fails, the lock must be cleared
        // so the capture loop's "publishTask == nil → kick off publish"
        // path is reachable again on a follow-up ``startScreenShare``.
        let transport = makeTransport()

        guard let state = await transport._testInjectScreenShareWedge() else {
            Issue.record("fixture should install a wedge")
            return
        }
        transport.handleScreenSharePublishFailure(
            RealtimeSessionError.screenShareUnavailable, capturedState: state
        )

        #expect(!(await transport._testScreenShareLockHasValue()), "publish-failure recovery must clear the lock")
    }

    @Test("onScreenShareFailed listener fires on publish failure")
    func onScreenShareFailedFires() async throws {
        let transport = makeTransport()

        let captured = OSAllocatedUnfairLock<String?>(initialState: nil)
        let cancellable = transport.onScreenShareFailed { error in
            captured.withLock { $0 = error.localizedDescription }
        }

        guard let state = await transport._testInjectScreenShareWedge() else {
            Issue.record("fixture should install a wedge"); return
        }
        transport.handleScreenSharePublishFailure(SimulatedError(), capturedState: state)

        #expect(captured.withLock { $0 } == "simulated publish error")
        cancellable.cancel()
    }

    @Test("cancelled listener does not fire")
    func cancelledListenerDoesNotFire() async throws {
        let transport = makeTransport()

        let fired = OSAllocatedUnfairLock<Bool>(initialState: false)
        let cancellable = transport.onScreenShareFailed { _ in fired.withLock { $0 = true } }
        cancellable.cancel()

        guard let state = await transport._testInjectScreenShareWedge() else {
            Issue.record("fixture should install a wedge"); return
        }
        transport.handleScreenSharePublishFailure(SimulatedError(), capturedState: state)

        #expect(!(fired.withLock { $0 }), "a cancelled listener must not fire")
    }

    @Test("a stale failure (stop+restart) neither wipes the newer share nor fires")
    func staleFailureDoesNotWipeNewerShareOrFire() async throws {
        // The subtlest guard: while share s1's deferred publish is in
        // flight, a stop + restart replaces the active share with s2.
        // When s1's publish then fails, the identity check
        // (``current === capturedState``) must keep s2 intact and NOT fire
        // a failure the current share didn't have.
        let transport = makeTransport()

        let fired = OSAllocatedUnfairLock<Bool>(initialState: false)
        let cancellable = transport.onScreenShareFailed { _ in fired.withLock { $0 = true } }
        defer { cancellable.cancel() }

        guard let s1 = await transport._testInjectScreenShareWedge() else {
            Issue.record("wedge s1"); return
        }
        guard let s2 = await transport._testInjectScreenShareWedge() else {
            Issue.record("wedge s2"); return
        }
        #expect(s1 !== s2, "the second wedge must be a distinct instance")

        // s1's stale publish fails while s2 is the active share.
        transport.handleScreenSharePublishFailure(SimulatedError(), capturedState: s1)

        #expect(await transport._testCurrentScreenShareState() === s2, "a stale failure must not wipe the newer share")
        #expect(!(fired.withLock { $0 }), "a stale failure must not fire onScreenShareFailed")
    }

    // MARK: reconcileScreenSharePublish ordering
    //
    // The deferred publish arms LiveKit's ~1 Hz stats timer via
    // ``enableStats``; ``stopScreenShare`` disarms it *before* unpublishing so
    // it never ticks against a removed sender (the crash). The reconciliation
    // must never let stats end up enabled after a concurrent stop — i.e. a
    // stop that lands while stats are being enabled must still leave a
    // ``disableStats`` as the last stats op before the sender goes away. These
    // drive ``reconcileScreenSharePublish`` with recording closures and assert
    // the exact call order for each stop-timing. Fully offline: the crash
    // itself needs a real RTP sender (E2E), but the ordering that prevents it
    // is pure control flow.

    @Test("reconcile: no concurrent stop → enable stats, adopt, never tear down")
    func reconcileHappyPathEnablesThenAdopts() async throws {
        let transport = makeTransport()
        let calls = OSAllocatedUnfairLock<[String]>(initialState: [])

        await transport.reconcileScreenSharePublish(
            stillCurrent: { true },
            enableStats: { calls.withLock { $0.append("enable") } },
            adopt: { calls.withLock { $0.append("adopt") }; return true },
            disableStats: { calls.withLock { $0.append("disable") } },
            unpublish: { calls.withLock { $0.append("unpublish") } }
        )

        #expect(calls.withLock { $0 } == ["enable", "adopt"],
                "the live share must enable stats then adopt, with no teardown")
    }

    @Test("reconcile: stop before enable → unpublish only, stats never touched")
    func reconcileSupersededBeforeEnableSkipsStats() async throws {
        let transport = makeTransport()
        let calls = OSAllocatedUnfairLock<[String]>(initialState: [])

        await transport.reconcileScreenSharePublish(
            stillCurrent: { false },
            enableStats: { calls.withLock { $0.append("enable") } },
            adopt: { calls.withLock { $0.append("adopt") }; return true },
            disableStats: { calls.withLock { $0.append("disable") } },
            unpublish: { calls.withLock { $0.append("unpublish") } }
        )

        // Never enabling stats is the point: nothing to leave running against
        // the sender we are about to drop.
        #expect(calls.withLock { $0 } == ["unpublish"],
                "a share already superseded at publish time must unpublish without enabling stats")
    }

    @Test("reconcile: stop during enable → disable stats before unpublish (regression)")
    func reconcileSupersededDuringEnableDisablesBeforeUnpublish() async throws {
        // The crash regression: the share was current when the publish landed
        // (stats get enabled), but a stop replaced it before ``adopt`` — so the
        // enabled stats MUST be disabled again, and that disable MUST precede
        // the unpublish, or the ~1 Hz timer ticks against the removed sender.
        let transport = makeTransport()
        let calls = OSAllocatedUnfairLock<[String]>(initialState: [])

        await transport.reconcileScreenSharePublish(
            stillCurrent: { true },
            enableStats: { calls.withLock { $0.append("enable") } },
            adopt: { calls.withLock { $0.append("adopt") }; return false },
            disableStats: { calls.withLock { $0.append("disable") } },
            unpublish: { calls.withLock { $0.append("unpublish") } }
        )

        #expect(calls.withLock { $0 } == ["enable", "adopt", "disable", "unpublish"],
                "a stop during enable must disable stats before unpublishing the stale sender")
        let order = calls.withLock { $0 }
        let disableIdx = order.firstIndex(of: "disable")
        let unpublishIdx = order.firstIndex(of: "unpublish")
        #expect(disableIdx != nil && unpublishIdx != nil && disableIdx! < unpublishIdx!,
                "stats must be disabled strictly before the sender is unpublished")
    }

    @Test("startScreenShare without a connected room throws .notConnected")
    func startWithoutRoomThrows() async throws {
        let transport = makeTransport()

        await #expect(throws: RealtimeSessionError.notConnected) {
            try await transport.startScreenShare()
        }
        #expect(!(await transport._testScreenShareLockHasValue()), "guard must reject before installing state")
    }

    @Test("setScreenShareFrameProcessor and pushScreenShareFrame are safe before start")
    func processorAndPushAreSafeBeforeStart() async throws {
        let transport = makeTransport()
        // No active share installed: push is a no-op, processor install
        // never runs. Neither should crash or install state.
        transport.setScreenShareFrameProcessor { buffer in buffer }
        #expect(!(await transport._testScreenShareLockHasValue()))
    }
}

/// The non-screen video-stream publish: same single slot and deferred
/// publish as the screen share, but a camera-source track behind a
/// pushable handle. Runs fully offline — the detached-room hook passes
/// the start guard and no frame is ever pushed, so no publish fires.
@Suite("Video-stream publish")
struct VideoStreamPublishTests {

    private func makeTransport() -> LiveKitSessionTransport {
        LiveKitSessionTransport(
            options: RealtimeSession.Options(apiKey: "test-key")
        )
    }

    @Test("addVideoStream without a connected room throws .notConnected")
    func addWithoutRoomThrows() async throws {
        let transport = makeTransport()
        await #expect(throws: RealtimeSessionError.notConnected) {
            _ = try await transport.addVideoStream()
        }
        #expect(!(await transport._testScreenShareLockHasValue()))
    }

    @Test("addVideoStream publishes a camera-source track")
    func addInstallsCameraSourceTrack() async throws {
        let transport = makeTransport()
        await transport._testInstallDetachedRoom()

        _ = try await transport.addVideoStream()

        let state = await transport._testCurrentScreenShareState()
        #expect(state?.source == .camera, "video streams carry the camera source — the wire label for 'not the user's screen'")
        #expect(state?.track.name == Track.cameraName)
    }

    @Test("one video publish at a time, in both directions")
    func slotIsExclusive() async throws {
        let transport = makeTransport()
        await transport._testInstallDetachedRoom()

        _ = try await transport.addVideoStream()
        await #expect(throws: RealtimeSessionError.videoPublishAlreadyActive) {
            _ = try await transport.addVideoStream()
        }
        // A live video stream must not be silently torn down by a share.
        await #expect(throws: RealtimeSessionError.videoPublishAlreadyActive) {
            try await transport.startScreenShare()
        }

        // And the reverse: a live share blocks a video stream.
        let shared = makeTransport()
        await shared._testInstallDetachedRoom()
        try await shared.startScreenShare()
        await #expect(throws: RealtimeSessionError.videoPublishAlreadyActive) {
            _ = try await shared.addVideoStream()
        }
    }

    @Test("removeVideoStream is identity-keyed and stopScreenShare never touches it")
    func removalIsIdentityKeyed() async throws {
        let transport = makeTransport()
        await transport._testInstallDetachedRoom()

        let handle = try await transport.addVideoStream()
        // stopScreenShare is scoped to screen-source state: the stream stays.
        await transport.stopScreenShare()
        #expect(await transport._testScreenShareLockHasValue())

        await transport.removeVideoStream(handle)
        #expect(!(await transport._testScreenShareLockHasValue()))

        // A stale handle is a no-op against a newer publish.
        let second = try await transport.addVideoStream()
        await transport.removeVideoStream(handle)
        #expect(await transport._testScreenShareLockHasValue())
        await transport.removeVideoStream(second)
        #expect(!(await transport._testScreenShareLockHasValue()))
    }
}
