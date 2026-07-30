import Foundation
import os

/// Audio shell for ``VoiceSession``.
///
/// The SDK owns the full audio path through LiveKit: mic capture +
/// Opus + upstream publication, and remote-track playback. This actor
/// is a public no-op shell so the Mac app keeps a stable surface
/// (``start``, ``stop``, ``setMicMuted``, ``inputLevel``,
/// ``outputLevel``, ``diagnostics``).
///
/// Mute is still meaningful: ``setMicMuted`` flips local state and
/// ``VoiceSession.setMuted`` forwards through the SDK, which gates
/// LiveKit's local mic publication and notifies the server.
///
/// Future direction: re-hydrate level metering by tapping LiveKit's
/// ``AudioManager`` for input level and the remote audio track for
/// output level. Until then, the level streams emit nothing.
public actor VoiceAudioEngine {
    private static let log = Logger(subsystem: CosmoRealtimeLog.subsystem, category: "audio")

    private var running = false
    private var micMuted: Bool = false

    private nonisolated let diagnosticsBox = DiagnosticsBox()

    private nonisolated let inputLevelStream: AsyncStream<Float>
    private nonisolated let inputLevelContinuation: AsyncStream<Float>.Continuation
    private nonisolated let outputLevelStream: AsyncStream<Float>
    private nonisolated let outputLevelContinuation: AsyncStream<Float>.Continuation

    public nonisolated var inputLevel: AsyncStream<Float> { inputLevelStream }
    public nonisolated var outputLevel: AsyncStream<Float> { outputLevelStream }
    public nonisolated var diagnostics: Diagnostics { diagnosticsBox.snapshot() }

    public init() {
        let inputStream = AsyncStream<Float>.makeStream(bufferingPolicy: .bufferingNewest(8))
        self.inputLevelStream = inputStream.stream
        self.inputLevelContinuation = inputStream.continuation

        let outputStream = AsyncStream<Float>.makeStream(bufferingPolicy: .bufferingNewest(8))
        self.outputLevelStream = outputStream.stream
        self.outputLevelContinuation = outputStream.continuation
    }

    public func start() async throws {
        Self.log.info("start() entry (LiveKit transport — audio engine is a shell)")
        guard !running else { return }
        running = true
    }

    public func stop() async {
        Self.log.info("stop() entry")
        guard running else { return }
        running = false
        micMuted = false
    }

    /// Local mic gate. ``VoiceSession.setMuted`` forwards this through
    /// the SDK, which gates LiveKit's local mic publication and
    /// notifies the server.
    public func setMicMuted(_ muted: Bool) {
        micMuted = muted
        Self.log.info("mic muted=\(muted, privacy: .public)")
    }
}

// MARK: - Diagnostics storage

/// Thread-safe diagnostics counters. The actor exposes `nonisolated`
/// `diagnostics`, so the underlying storage has to be safe to read from
/// any thread without hopping onto the actor.
private final class DiagnosticsBox: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: Diagnostics())

    func snapshot() -> Diagnostics {
        state.withLock { $0 }
    }
}
