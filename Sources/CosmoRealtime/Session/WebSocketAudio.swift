@preconcurrency import AVFAudio
import Foundation
import os

actor WebSocketAudio: WebSocketAudioHandling {
    private static let log = Logger(
        subsystem: CosmoRealtimeLog.subsystem,
        category: "websocket-audio"
    )

    private final class ConverterBox: @unchecked Sendable {
        let converter: AVAudioConverter
        let format: AVAudioFormat

        init(source: AVAudioFormat, sampleRate: Double) throws {
            guard
                let format = AVAudioFormat(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: sampleRate,
                    channels: 1,
                    interleaved: false
                ),
                let converter = AVAudioConverter(from: source, to: format)
            else {
                throw AudioUnavailableError(message: "could not create the websocket audio converter")
            }
            self.converter = converter
            self.format = format
        }
    }

    final class StreamConverter: @unchecked Sendable {
        private struct State {
            var sourceFormat: AVAudioFormat?
            var sampleRate = 0
            var converter: ConverterBox?
        }

        private let state = OSAllocatedUnfairLock<State>(initialState: State())

        func convert(
            _ buffer: AVAudioPCMBuffer,
            sampleRate: Int
        ) throws -> Data {
            try state.withLock { state in
                if state.sourceFormat != buffer.format || state.sampleRate != sampleRate {
                    state.sourceFormat = buffer.format
                    state.sampleRate = sampleRate
                    state.converter = try ConverterBox(
                        source: buffer.format,
                        sampleRate: Double(sampleRate)
                    )
                }
                guard let converter = state.converter else {
                    throw AudioUnavailableError(message: "could not create the websocket audio converter")
                }
                return try WebSocketAudio.convert(
                    buffer,
                    with: converter,
                    endOfStream: false
                )
            }
        }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let inputLevelsContinuation: AsyncStream<Float>.Continuation
    private let outputLevelsContinuation: AsyncStream<Float>.Continuation
    private var sendAudio: (@Sendable (Data) -> Void)?
    private var inputSampleRate = 0.0
    private var outputFormat: AVAudioFormat?
    private var microphoneEnabled = false
    private var prepared = false
    private var scheduledFrames: AVAudioFramePosition = 0
#if os(iOS)
    /// Set the moment the session goes active, so a `prepare` that throws
    /// afterwards still hands it back — ``prepared`` is never reached on
    /// that path, and a live play-and-record session keeps the microphone
    /// indicator lit for the whole app.
    private var activatedAudioSession = false
#endif

    init(
        inputLevelsContinuation: AsyncStream<Float>.Continuation,
        outputLevelsContinuation: AsyncStream<Float>.Continuation
    ) {
        self.inputLevelsContinuation = inputLevelsContinuation
        self.outputLevelsContinuation = outputLevelsContinuation
    }

    func prepare(
        inputSampleRate: Int,
        outputSampleRate: Int,
        microphoneEnabled: Bool,
        sendAudio: @escaping @Sendable (Data) -> Void
    ) throws {
        self.inputSampleRate = Double(inputSampleRate)
        self.sendAudio = sendAudio
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(outputSampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw AudioUnavailableError(message: "could not create the websocket output format")
        }
        self.outputFormat = outputFormat
#if os(iOS)
        // LiveKit auto-manages the AVAudioSession on the room lane; this lane
        // has no LiveKit, so the engine gets its session configured here —
        // unless the app took ownership of it.
        let audioSession = AVAudioSession.sharedInstance()
        activatedAudioSession = try Self.activateAudioSession(
            managed: RealtimeSession.managesAudioSession,
            setCategory: {
                try audioSession.setCategory(
                    .playAndRecord,
                    mode: .voiceChat,
                    options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
                )
            },
            setActive: { try audioSession.setActive(true) }
        )
#endif
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
        var tapInstalled = false
        do {
            if microphoneEnabled {
                try installMicrophoneTap()
                tapInstalled = true
            }
            try engine.start()
        } catch {
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
            engine.reset()
            deactivateAudioSession()
            self.sendAudio = nil
            self.outputFormat = nil
            throw error
        }
        self.microphoneEnabled = microphoneEnabled
        prepared = true
    }

    func setMicrophoneEnabled(_ enabled: Bool) throws {
        guard prepared, enabled != microphoneEnabled else { return }
        if enabled {
            try Self.activateMicrophone(
                stopEngine: { engine.stop() },
                installTap: { try installMicrophoneTap() },
                startEngine: { try engine.start() },
                removeTap: { engine.inputNode.removeTap(onBus: 0) },
                disableVoiceProcessing: {
                    try engine.inputNode.setVoiceProcessingEnabled(false)
                }
            )
        } else {
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            try Self.deactivateVoiceProcessing(
                isEnabled: input.isVoiceProcessingEnabled,
                stopEngine: { engine.stop() },
                setEnabled: { try input.setVoiceProcessingEnabled($0) },
                startEngine: { if !engine.isRunning { try engine.start() } }
            )
        }
        microphoneEnabled = enabled
    }

    func play(_ data: Data) {
        guard
            Self.isCompletePCM16Frame(data),
            let outputFormat,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(data.count / 2)
            ),
            let channel = buffer.int16ChannelData?[0]
        else { return }
        data.withUnsafeBytes { raw in
            if let baseAddress = raw.baseAddress {
                memcpy(channel, baseAddress, data.count)
            }
        }
        buffer.frameLength = AVAudioFrameCount(data.count / 2)
        outputLevelsContinuation.yield(Self.rms(data))
        if !player.isPlaying {
            scheduledFrames = 0
        } else if let played = playedFrames(), played > scheduledFrames {
            // The player timeline keeps running through silence after the
            // queue drains, so it overtakes the scheduled total between
            // turns; a new buffer starts at "now", not at the stale total.
            scheduledFrames = played
        }
        player.scheduleBuffer(buffer)
        scheduledFrames += AVAudioFramePosition(buffer.frameLength)
        if !player.isPlaying { player.play() }
    }

    func flushPlayback() {
        guard prepared, let outputFormat else { return }
        guard Self.shouldFlushPlayback(
            scheduledFrames: scheduledFrames,
            playedFrames: playedFrames(),
            sampleRate: outputFormat.sampleRate
        ) else { return }
        player.stop()
        scheduledFrames = 0
    }

    private func playedFrames() -> AVAudioFramePosition? {
        guard
            player.isPlaying,
            let nodeTime = player.lastRenderTime,
            let playerTime = player.playerTime(forNodeTime: nodeTime)
        else { return nil }
        return playerTime.sampleTime
    }

    func setVolume(_ volume: Double) {
        player.volume = Float(min(max(volume, 0), 1))
    }

    func close() {
        if microphoneEnabled {
            engine.inputNode.removeTap(onBus: 0)
        }
        player.stop()
        scheduledFrames = 0
        engine.stop()
        engine.reset()
        deactivateAudioSession()
        sendAudio = nil
        outputFormat = nil
        microphoneEnabled = false
        prepared = false
    }

    private func deactivateAudioSession() {
#if os(iOS)
        guard activatedAudioSession else { return }
        activatedAudioSession = false
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        } catch {
            Self.log.warning(
                "audio session deactivation failed: \(error.localizedDescription, privacy: .public)"
            )
        }
#endif
    }

    /// Configure and activate the shared session, reporting whether this
    /// session is now the one holding it. An app that owns the session gets
    /// its category, mode, route and activation left exactly as it set them.
    nonisolated static func activateAudioSession(
        managed: Bool,
        setCategory: () throws -> Void,
        setActive: () throws -> Void
    ) throws -> Bool {
        guard managed else { return false }
        try setCategory()
        try setActive()
        return true
    }

    private func installMicrophoneTap() throws {
        let input = engine.inputNode
        try Self.configureVoiceProcessing(
            isEnabled: input.isVoiceProcessingEnabled,
            setEnabled: { try input.setVoiceProcessingEnabled($0) },
            setAGCEnabled: { input.isVoiceProcessingAGCEnabled = $0 },
            minimizeOtherAudioDucking: {
                if #available(macOS 14.0, iOS 17.0, *) {
                    input.voiceProcessingOtherAudioDuckingConfiguration = .init(
                        enableAdvancedDucking: false,
                        duckingLevel: .min
                    )
                }
            }
        )
        let sourceFormat = input.outputFormat(forBus: 0)
        guard sourceFormat.channelCount > 0, sourceFormat.sampleRate > 0 else {
            // A zero-channel, zero-rate input format is the platform saying
            // there is no input device to open.
            throw AudioUnavailableError(
                message: "no usable microphone input format", code: .micNotFound)
        }
        let box = try ConverterBox(
            source: sourceFormat,
            sampleRate: inputSampleRate
        )
        let sendAudio = self.sendAudio
        let levels = inputLevelsContinuation
        input.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: sourceFormat
        ) { buffer, _ in
            levels.yield(Self.rms(buffer))
            do {
                let data = try Self.convert(buffer, with: box, endOfStream: false)
                if !data.isEmpty, let sendAudio {
                    sendAudio(data)
                }
            } catch {
                Self.log.error("microphone PCM conversion failed: \(error)")
            }
        }
    }

    nonisolated static func pcm16Data(
        from buffer: AVAudioPCMBuffer,
        sampleRate: Int
    ) throws -> Data {
        try convert(
            buffer,
            with: ConverterBox(
                source: buffer.format,
                sampleRate: Double(sampleRate)
            ),
            endOfStream: true
        )
    }

    nonisolated static func streamingPCM16Data(
        from buffers: [AVAudioPCMBuffer],
        sampleRate: Int
    ) throws -> [Data] {
        let converter = StreamConverter()
        return try buffers.map {
            try converter.convert($0, sampleRate: sampleRate)
        }
    }

    nonisolated static func isCompletePCM16Frame(_ data: Data) -> Bool {
        data.count >= MemoryLayout<Int16>.size && data.count.isMultiple(of: 2)
    }

    /// Backlog above which an assistant turn-complete stops the player. A
    /// normal turn end leaves only a network-latency tail unplayed (the
    /// server's playout gate models its own send clock, not the client's);
    /// an interruption leaves the server's ~300 ms pacing lead. 100 ms
    /// splits the two so ordinary turn tails are never clipped.
    nonisolated static let playbackFlushBacklogThreshold: TimeInterval = 0.1

    nonisolated static func shouldFlushPlayback(
        scheduledFrames: AVAudioFramePosition,
        playedFrames: AVAudioFramePosition?,
        sampleRate: Double
    ) -> Bool {
        guard let playedFrames, sampleRate > 0 else { return false }
        let backlog = Double(scheduledFrames - playedFrames) / sampleRate
        return backlog > playbackFlushBacklogThreshold
    }

    /// Voice processing (Apple VPIO) supplies the echo canceller; the player
    /// shares the engine, so its playback is the canceller's far-end
    /// reference. AGC is off so double-talk keeps the user's captured level
    /// (barge-in survives); VPIO exposes no separate noise-suppression
    /// switch. Must run before the tap-format read and only while the engine
    /// is stopped — enabling swaps the I/O unit and changes both formats.
    nonisolated static func configureVoiceProcessing(
        isEnabled: Bool,
        setEnabled: (Bool) throws -> Void,
        setAGCEnabled: (Bool) -> Void,
        minimizeOtherAudioDucking: () -> Void
    ) throws {
        if !isEnabled {
            try setEnabled(true)
        }
        setAGCEnabled(false)
        minimizeOtherAudioDucking()
    }

    /// An engaged VPIO unit keeps rerouting and ducking other apps' audio,
    /// so it is turned off whenever capture stops. Needs the same
    /// stopped-engine window as enabling; a failed disable is non-fatal
    /// (the ducking persists) and the engine is restarted regardless so
    /// playback continues.
    nonisolated static func deactivateVoiceProcessing(
        isEnabled: Bool,
        stopEngine: () -> Void,
        setEnabled: (Bool) throws -> Void,
        startEngine: () throws -> Void
    ) throws {
        if isEnabled {
            stopEngine()
            do {
                try setEnabled(false)
            } catch {
                Self.log.error("voice processing could not be disabled: \(error)")
            }
        }
        // Unconditional: an earlier attempt can have disabled processing and
        // then failed to restart, which leaves nothing to disable and an
        // engine that is still stopped.
        try startEngine()
    }

    nonisolated static func activateMicrophone(
        stopEngine: () -> Void,
        installTap: () throws -> Void,
        startEngine: () throws -> Void,
        removeTap: () -> Void,
        disableVoiceProcessing: () throws -> Void
    ) throws {
        stopEngine()
        var tapInstalled = false
        do {
            try installTap()
            tapInstalled = true
            try startEngine()
        } catch {
            if tapInstalled { removeTap() }
            // The tap installs voice processing before the steps that can
            // fail, and the microphone stays off after this — leaving it
            // engaged would duck other apps for a session that never
            // captured anything.
            do {
                try disableVoiceProcessing()
            } catch {
                Self.log.error("voice processing could not be disabled after a microphone failure: \(error)")
            }
            do {
                try startEngine()
            } catch {
                Self.log.error("could not restore output-only audio after microphone failure: \(error)")
            }
            throw error
        }
    }

    private nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer,
        with box: ConverterBox,
        endOfStream: Bool
    ) throws -> Data {
        let ratio = box.format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 1
        guard
            let output = AVAudioPCMBuffer(
                pcmFormat: box.format,
                frameCapacity: capacity
            )
        else {
            throw AudioUnavailableError(message: "could not allocate websocket PCM")
        }
        var supplied = false
        var conversionError: NSError?
        let status = box.converter.convert(
            to: output,
            error: &conversionError
        ) { _, inputStatus in
            if supplied {
                inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if let conversionError { throw conversionError }
        guard
            status != .error,
            let channel = output.int16ChannelData?[0]
        else {
            throw AudioUnavailableError(message: "websocket PCM conversion failed")
        }
        return Data(
            bytes: channel,
            count: Int(output.frameLength) * MemoryLayout<Int16>.size
        )
    }

    private nonisolated static func rms(_ data: Data) -> Float {
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return 0 }
            let total = samples.reduce(0.0) { sum, sample in
                let value = Double(sample)
                return sum + value * value
            }
            return Float(sqrt(total / Double(samples.count)) / 32_768)
        }
    }

    nonisolated static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        if let samples = buffer.floatChannelData?[0] {
            let total = (0..<count).reduce(0.0) { sum, index in
                let value = Double(samples[index])
                return sum + value * value
            }
            return Float(sqrt(total / Double(count)))
        }
        if let samples = buffer.int16ChannelData?[0] {
            let total = (0..<count).reduce(0.0) { sum, index in
                let value = Double(samples[index])
                return sum + value * value
            }
            return Float(sqrt(total / Double(count)) / 32_768)
        }
        return 0
    }
}
