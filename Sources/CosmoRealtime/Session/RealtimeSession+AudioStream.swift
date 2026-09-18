import AVFAudio
import Foundation
import os

// MARK: - Audio streams
extension RealtimeSession {

    private static let audioStreamLog = Logger(
        subsystem: CosmoRealtimeLog.subsystem, category: "session-audiostream"
    )

    /// Take the session's voice for caller-owned audio — a synthetic
    /// generator, file replay, or any pipeline the SDK cannot capture
    /// itself — then feed it with ``pushAudioBuffer(_:)``. For the device
    /// microphone use ``setMuted(_:)``.
    ///
    /// A session carries one voice, so while the stream is running the device
    /// microphone is silenced and the agent hears exactly the pushed buffers;
    /// ``stopAudioStream()`` gives it back. The server-side mute gate is
    /// cleared as part of the publish. Throws
    /// ``SessionStateError`` while a stream is
    /// already running, and ``SessionStateError`` outside a
    /// live session.
    public func startAudioStream() async throws {
        await beginAudioStreamOperation()
        defer { endAudioStreamOperation() }
        try _assertSendable()
        try await transport.startAudioStream()
        do {
            try await _setMuted(false)
        } catch {
            await transport.stopAudioStream()
            throw error
        }
    }

    /// Push one buffer into the running stream. The call may resample and copy
    /// the buffer synchronously; call it from a capture queue, not an audio
    /// render callback. A push with no stream running is inert.
    public nonisolated func pushAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        transport.pushAudioBuffer(buffer)
    }

    /// Give the voice back to whatever held it before the stream. Idempotent,
    /// and pushes after it are inert.
    ///
    /// A session that had no microphone publishing — one started with
    /// ``micMuted`` — is left with none, and the server gate closes behind it.
    /// One that did keeps it, gate open.
    public func stopAudioStream() async {
        await beginAudioStreamOperation()
        defer { endAudioStreamOperation() }
        let microphoneHasVoice = await transport.stopAudioStream()
        do {
            try await _setMuted(!microphoneHasVoice)
        } catch {
            // The track is already unpublished, so the agent hears nothing
            // either way; the gate is the server's view of that.
            Self.audioStreamLog.error(
                "audio stream stopped but the mute gate did not follow: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func beginAudioStreamOperation() async {
        if audioStreamOperationRunning {
            await withCheckedContinuation { continuation in
                audioStreamOperationWaiters.append(continuation)
            }
        } else {
            audioStreamOperationRunning = true
        }
    }

    func endAudioStreamOperation() {
        guard !audioStreamOperationWaiters.isEmpty else {
            audioStreamOperationRunning = false
            return
        }
        audioStreamOperationWaiters.removeFirst().resume()
    }
}
