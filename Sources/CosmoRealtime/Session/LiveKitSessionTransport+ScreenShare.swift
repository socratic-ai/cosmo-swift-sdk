import CoreMedia
import Foundation
import LiveKit
import os

// MARK: - Screen-share publish
extension LiveKitSessionTransport {

    fileprivate static let screenShareLog = Logger(subsystem: CosmoRealtimeLog.subsystem, category: "session-screenshare")

    /// Start a screen-share publish over LiveKit. The video track is
    /// created immediately but the SFU publish is deferred until the
    /// first ``pushScreenShareFrame`` arrives — ``BufferCapturer`` cannot
    /// resolve frame dimensions until at least one sample buffer has
    /// been captured, and ``publish(videoTrack:)`` blocks indefinitely
    /// without dimensions.
    ///
    /// Idempotent: if a screen-share is already running, the existing
    /// track is unpublished first before creating a new one.
    ///
    /// Throws ``RealtimeSessionError/notConnected`` if no room is open —
    /// without this guard the track is created and frames are captured
    /// into a sink that never publishes, which presents as a silent
    /// failure to the caller.
    func startScreenShare() async throws {
        guard room != nil else {
            throw RealtimeSessionError.notConnected
        }
        if screenShareLock.withLock({ $0 }) != nil {
            await stopScreenShare()
        }
        let track = LocalVideoTrack.createBufferTrack(
            name: Track.screenShareVideoName,
            source: .screenShareVideo,
            options: BufferCaptureOptions()
        )
        guard let capturer = track.capturer as? BufferCapturer else {
            throw RealtimeSessionError.screenShareUnavailable
        }
        screenShareLock.withLock { $0 = ScreenShareState(track: track, capturer: capturer) }
    }

    /// Push one captured frame into the active screen-share publish.
    /// Safe to call from a video-capture thread. The first call kicks
    /// off the deferred LiveKit publish; subsequent calls feed frames
    /// to the already-publishing track. No-op if ``startScreenShare``
    /// has not been called or after ``stopScreenShare``.
    nonisolated func pushScreenShareFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let state = screenShareLock.withLock({ $0 }) else { return }
        let processor = screenShareFrameProcessorLock.withLock { $0 }
        let outgoing = processor?(sampleBuffer) ?? sampleBuffer
        state.capturer.capture(outgoing)
        _ = screenShareLock.withLock { current -> Bool in
            guard let s = current, s.publishTask == nil else { return false }
            s.publishTask = Task { [weak self] in
                guard let self else { return }
                // The transport is single-attempt: a closed transport
                // means teardown already ran; drop the deferred publish
                // so it never publishes into a torn-down room.
                if self.isClosed.withLock({ $0 }) { return }
                guard let room = await self.room else { return }
                do {
                    // Publish a single full-resolution VP8 layer: the only
                    // subscriber is the backend agent (Python SDK, no H.264
                    // support). Without an explicit codec, LiveKit publishes
                    // an H.264 primary + VP8 backup sender; the agent gets the
                    // backup, which skips the degradationPreference setup and
                    // starts bandwidth-pinned — at 1fps the estimator never
                    // ramps, so frames arrive ~640px wide forever. Simulcast
                    // off for the same reason: the SFU would forward the
                    // low layer to the agent.
                    let pub = try await room.localParticipant.publish(
                        videoTrack: s.track,
                        options: VideoPublishOptions(
                            simulcast: false,
                            preferredCodec: .vp8
                        )
                    )
                    // Reconcile the completed publish against ``stopScreenShare``
                    // (and stop + restart), which can clear or REPLACE state
                    // during the publish await. See ``reconcileScreenSharePublish``
                    // for why the enable-then-expose ordering is load-bearing.
                    await self.reconcileScreenSharePublish(
                        stillCurrent: { self.screenShareLock.withLock { $0 === s } },
                        // Collect LiveKit's outbound video QoE (fps, encode
                        // time, CPU/bandwidth quality-limitation) via the same
                        // observer the audio tracks use.
                        enableStats: { await self.enableQoEStats(on: s.track) },
                        // Adopt the publication into state. Identity check, not
                        // nil check: adopting a stale publication into a newer
                        // share's state would hand that share a track it never
                        // created. Atomic under the lock, so a concurrent stop
                        // is serialized against it.
                        adopt: {
                            self.screenShareLock.withLock { current -> Bool in
                                guard let c = current, c === s else { return false }
                                c.publication = pub
                                return true
                            }
                        },
                        disableStats: { await self.disableQoEStats(on: s.track) },
                        unpublish: { try? await room.localParticipant.unpublish(publication: pub) }
                    )
                } catch {
                    // Recoverable failure (SFU rejected the track, network
                    // blip during DTLS, codec mismatch, etc.). Identity-
                    // guarded recovery clears state so the next
                    // ``startScreenShare`` can retry, then fires
                    // ``onScreenShareFailed`` — but only if this is still
                    // the active share.
                    self.handleScreenSharePublishFailure(error, capturedState: s)
                }
            }
            return true
        }
    }

    /// Stop the active screen-share publish. Idempotent; no-op if there
    /// is no active publish.
    func stopScreenShare() async {
        let state = screenShareLock.withLock { current -> ScreenShareState? in
            let s = current
            current = nil
            return s
        }
        guard let state else { return }
        state.publishTask?.cancel()
        guard let publication = state.publication else { return }
        // Stop the stats timer *before* the sender leaves the peer connection.
        // LiveKit's `unpublish` removes the RTP sender but leaves the track's
        // ~1 Hz statistics timer running against it, and only cancels timers on
        // room disconnect — so the next tick calls `GetStats` on a sender the
        // peer connection no longer owns and WebRTC aborts the process.
        //
        // Known residual (not closable client-side on LiveKit 2.14.1):
        // `set(reportStatistics: false)` cancels the timer but does NOT drain a
        // callback already inside `GetStats`. If stop lands within the in-flight
        // window of a tick (~ms out of the 1 s period), that call can still race
        // `unpublish`. This shrinks the crash from every mid-call stop to that
        // sliver; fully closing it needs an awaitable stats-shutdown upstream.
        await disableQoEStats(on: state.track)
        try? await room?.localParticipant.unpublish(publication: publication)
    }

    /// Install or clear a frame processor. The processor runs inside
    /// ``pushScreenShareFrame`` before the frame is handed to LiveKit's
    /// capturer. Pass ``nil`` to remove a previously-installed processor.
    nonisolated func setScreenShareFrameProcessor(_ processor: ScreenShareFrameProcessor?) {
        screenShareFrameProcessorLock.withLock { $0 = processor }
    }

    /// Register a callback fired when the deferred screen-share publish
    /// task fails (SFU rejection, codec mismatch, network blip, etc.).
    /// The transport clears its screen-share state automatically before
    /// the callback fires, so the caller can re-attempt by calling
    /// ``startScreenShare()`` again. Returns a ``Cancellable`` to drop
    /// the listener.
    nonisolated func onScreenShareFailed(
        _ handler: @escaping @Sendable (Error) -> Void
    ) -> Cancellable {
        let id = UUID()
        screenShareFailedListeners.withLock { $0[id] = handler }
        // Removal is a synchronous lock write (no actor hop), so run it
        // inline on ``cancel()`` rather than dispatching it — a caller
        // that cancels then triggers a failure must not still be called.
        return Cancellable(awaitable: { [weak self] in
            self?.screenShareFailedListeners.withLock { $0.removeValue(forKey: id) }
            return Task {}
        })
    }

    /// Reconcile a completed deferred publish against screen-share state
    /// that a concurrent ``stopScreenShare`` (or stop + restart) may have
    /// cleared or replaced during the publish await. Side effects are
    /// injected so the ordering is unit-testable offline — the real path
    /// needs a live SFU, and the crash it prevents needs a real RTP sender.
    ///
    /// The ordering is the whole fix. ``enableStats`` arms LiveKit's ~1 Hz
    /// per-track stats timer; ``stopScreenShare`` disarms it *before*
    /// unpublishing so it never ticks against a removed sender (the crash
    /// this file exists to prevent). If stats were ever enabled *after* stop
    /// disabled them, that crash returns. Because ``stopScreenShare`` keys off
    /// the publication, enabling stats *before* the publication is exposed
    /// makes stop a no-op until we are done — so no stop can slip a disable
    /// between our enable and the unpublish. If a stop nonetheless replaced
    /// the share while stats were enabling, ``adopt`` fails and this task owns
    /// teardown: stop never saw this publication, so it neither disabled these
    /// stats nor unpublished this sender.
    nonisolated func reconcileScreenSharePublish(
        stillCurrent: () -> Bool,
        enableStats: () async -> Void,
        adopt: () -> Bool,
        disableStats: () async -> Void,
        unpublish: () async -> Void
    ) async {
        guard stillCurrent() else {
            await unpublish()
            return
        }
        await enableStats()
        guard adopt() else {
            await disableStats()
            await unpublish()
            return
        }
    }

    /// Identity-guarded publish-failure recovery, extracted from the
    /// deferred-publish catch so the guard is unit-testable offline.
    /// Clears the screen-share state and fires ``onScreenShareFailed``
    /// ONLY if ``s`` is still the active share: a stop — or a stop +
    /// restart that installed a NEW share during the publish await — must
    /// neither wipe the newer share's state nor report a failure it
    /// didn't have.
    nonisolated func handleScreenSharePublishFailure(
        _ error: Error, capturedState s: ScreenShareState
    ) {
        Self.screenShareLog.error("publish screen-share track failed: \(error.localizedDescription, privacy: .public)")
        let wasCurrentShare = screenShareLock.withLock { current -> Bool in
            guard current === s else { return false }
            current = nil
            return true
        }
        if wasCurrentShare {
            fireScreenShareFailure(error)
        }
    }

    /// Fire all registered ``onScreenShareFailed`` listeners. Called
    /// from the deferred-publish catch block AFTER state has been
    /// cleared so a listener can immediately call ``startScreenShare``
    /// to retry without seeing stale state.
    nonisolated func fireScreenShareFailure(_ error: Error) {
        let handlers = screenShareFailedListeners.withLock { Array($0.values) }
        for handler in handlers {
            handler(error)
        }
    }
}
