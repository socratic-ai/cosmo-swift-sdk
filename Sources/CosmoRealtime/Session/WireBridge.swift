import CosmoRealtimeAPI
import Foundation

// The only crossings between the hand-written wire mirrors and the
// generated module: the REST client's decoded responses come in, and the
// config send path goes out. Every enum maps by exhaustive switch, so a
// spec change that adds or renames a case fails compilation here rather
// than drifting silently.

extension CredentialInfo {
    init(_ wire: CosmoRealtimeAPI.Components.Schemas.VerifyResponse) {
        self.init(
            canStartSessions: wire.canStartSessions,
            credential: CredentialKind(wire.credential),
            externalUserId: wire.externalUserId,
            realtimeVoiceAvailable: wire.realtimeVoiceAvailable,
            scopes: wire.scopes,
            workspace: wire.workspace.map(WorkspaceInfo.init)
        )
    }
}

extension WorkspaceInfo {
    init(_ wire: CosmoRealtimeAPI.Components.Schemas.WorkspaceInfo) {
        self.init(name: wire.name, slug: wire.slug)
    }
}

extension CredentialKind {
    init(_ wire: CosmoRealtimeAPI.Components.Schemas.CredentialKind) {
        switch wire {
        case .apiKey: self = .apiKey
        case .userToken: self = .userToken
        }
    }
}

extension SessionUsage {
    init(_ wire: CosmoRealtimeAPI.Components.Schemas.SessionUsage) {
        self.init(
            agentSpeakingSeconds: wire.agentSpeakingSeconds,
            durationSeconds: wire.durationSeconds,
            model: wire.model,
            provider: wire.provider.map(ProviderPayload.init),
            status: SessionStatus(wire.status),
            tokens: wire.tokens.map(SessionTokenUsage.init),
            turnCount: wire.turnCount,
            usageStatus: UsageStatus(wire.usageStatus),
            userSpeakingSeconds: wire.userSpeakingSeconds
        )
    }
}

extension SessionUsage.ProviderPayload {
    init(_ wire: CosmoRealtimeAPI.Components.Schemas.SessionUsage.ProviderPayload) {
        switch wire {
        case .gemini: self = .gemini
        case .openai: self = .openai
        case .openaiMini: self = .openaiMini
        case .openaiLive: self = .openaiLive
        case .grok: self = .grok
        case .cosmoVoicePersonaplex: self = .cosmoVoicePersonaplex
        case .cosmoVoiceUltravox: self = .cosmoVoiceUltravox
        }
    }
}

extension SessionTokenUsage {
    init(_ wire: CosmoRealtimeAPI.Components.Schemas.SessionTokenUsage) {
        self.init(
            inputAudioTokens: wire.inputAudioTokens ?? 0,
            inputCachedTokens: wire.inputCachedTokens ?? 0,
            inputImageTokens: wire.inputImageTokens ?? 0,
            inputTextTokens: wire.inputTextTokens ?? 0,
            inputTokens: wire.inputTokens ?? 0,
            outputAudioTokens: wire.outputAudioTokens ?? 0,
            outputTextTokens: wire.outputTextTokens ?? 0,
            outputTokens: wire.outputTokens ?? 0,
            totalTokens: wire.totalTokens ?? 0
        )
    }
}

extension SessionStatus {
    init(_ wire: CosmoRealtimeAPI.Components.Schemas.SessionStatus) {
        switch wire {
        case .active: self = .active
        case .completed: self = .completed
        case .error: self = .error
        }
    }
}

extension UsageStatus {
    init(_ wire: CosmoRealtimeAPI.Components.Schemas.UsageStatus) {
        switch wire {
        case .pending: self = .pending
        case .recorded: self = .recorded
        case .unavailable: self = .unavailable
        }
    }
}

extension RealtimeSessionStartTimings {
    init(_ wire: CosmoRealtimeAPI.Components.Schemas.SessionStartTimings) {
        self.init(
            dbInsertMs: wire.dbInsertMs,
            dispatchMs: wire.dispatchMs,
            mintTokensMs: wire.mintTokensMs,
            projectCheckMs: wire.projectCheckMs,
            providerResolveMs: wire.providerResolveMs,
            resolveMs: wire.resolveMs,
            totalMs: wire.totalMs,
            versionCheckMs: wire.versionCheckMs
        )
    }
}

extension CosmoRealtimeAPI.Components.Schemas.SessionStartTimings {
    init(_ timings: RealtimeSessionStartTimings) {
        self.init(
            dbInsertMs: timings.dbInsertMs,
            dispatchMs: timings.dispatchMs,
            mintTokensMs: timings.mintTokensMs,
            projectCheckMs: timings.projectCheckMs,
            providerResolveMs: timings.providerResolveMs,
            resolveMs: timings.resolveMs,
            totalMs: timings.totalMs,
            versionCheckMs: timings.versionCheckMs
        )
    }
}

extension CosmoRealtimeAPI.Components.Schemas.SilenceTimeout {
    init(_ hook: SilenceTimeout) {
        self.init(
            action: .init(hook.action),
            maxCount: hook.maxCount,
            name: hook.name,
            resetMode: hook.resetMode.map { mode in
                switch mode {
                case .never: .never
                case .onUserSpeech: .onUserSpeech
                }
            },
            timeoutSeconds: hook.timeoutSeconds,
            trigger: hook.trigger.map { trigger in
                switch trigger {
                case .user_speech_timeout: .user_speech_timeout
                }
            }
        )
    }
}

extension CosmoRealtimeAPI.Components.Schemas.SilenceTimeout.ActionPayload {
    init(_ action: SilenceTimeout.ActionPayload) {
        switch action {
        case .say(let say): self = .say(.init(say))
        case .endCall(let endCall): self = .endCall(.init(endCall))
        }
    }
}

extension CosmoRealtimeAPI.Components.Schemas.Say {
    init(_ say: Say) {
        self.init(prompt: say.prompt, text: say.text, _type: .say)
    }
}

extension CosmoRealtimeAPI.Components.Schemas.NoiseCancellation {
    init(_ mode: NoiseCancellation) {
        switch mode {
        case .off: self = .off
        case .denoise: self = .denoise
        case .voiceFocus: self = .voiceFocus
        }
    }
}

extension CosmoRealtimeAPI.Components.Schemas.InterruptionSensitivity {
    init(_ sensitivity: InterruptionSensitivity) {
        switch sensitivity {
        case ._default: self = ._default
        case .high: self = .high
        case .low: self = .low
        }
    }
}

extension CosmoRealtimeAPI.Components.Schemas.GrokReasoningEffort {
    init(_ effort: GrokReasoningEffort) {
        switch effort {
        case .high: self = .high
        case .none: self = .none
        }
    }
}

extension CosmoRealtimeAPI.Components.Schemas.ThinkingLevel {
    init(_ level: ThinkingLevel) {
        switch level {
        case .minimal: self = .minimal
        case .low: self = .low
        case .medium: self = .medium
        case .high: self = .high
        }
    }
}

extension CosmoRealtimeAPI.Components.Schemas.EndOfSpeechSensitivity {
    init(_ sensitivity: EndOfSpeechSensitivity) {
        switch sensitivity {
        case .low: self = .low
        case .high: self = .high
        }
    }
}

extension CosmoRealtimeAPI.Components.Schemas.SemanticEagerness {
    init(_ eagerness: SemanticEagerness) {
        switch eagerness {
        case .low: self = .low
        case .medium: self = .medium
        case .high: self = .high
        case .auto: self = .auto
        }
    }
}

extension CosmoRealtimeAPI.Components.Schemas.TurnDetectionMode {
    init(_ mode: TurnDetectionMode) {
        switch mode {
        case .serverVad: self = .serverVad
        case .semanticVad: self = .semanticVad
        case .cosmoVad: self = .cosmoVad
        }
    }
}

extension CosmoRealtimeAPI.Components.Schemas.EndCall {
    init(_ endCall: EndCall) {
        self.init(farewell: endCall.farewell, _type: .endCall)
    }
}

// ``additionalProperties: false`` enforcement for the mirrors' strict
// decoders — same behavior as the generated module's runtime helper, which
// is SPI and unreachable from hand-written code.
extension Decoder {
    func ensureNoUnknownKeys(knownKeys: Set<String>) throws {
        let container = try container(keyedBy: RawCodingKey.self)
        let unknown = container.allKeys.filter { !knownKeys.contains($0.stringValue) }
        guard let first = unknown.sorted(by: { $0.stringValue < $1.stringValue }).first else {
            return
        }
        throw DecodingError.dataCorruptedError(
            forKey: first,
            in: container,
            debugDescription:
                "Additional properties are disabled, but found \(unknown.count) unknown keys during decoding"
        )
    }
}

struct RawCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension CosmoRealtimeAPI.Components.Schemas.OpenAILiveReasoningEffort {
    init(_ effort: OpenAILiveReasoningEffort) {
        switch effort {
        case .minimal: self = .minimal
        case .low: self = .low
        case .medium: self = .medium
        case .high: self = .high
        }
    }
}

extension CosmoRealtimeAPI.Components.Schemas.OpenAILiveVerbosity {
    init(_ verbosity: OpenAILiveVerbosity) {
        switch verbosity {
        case .low: self = .low
        case .medium: self = .medium
        case .high: self = .high
        }
    }
}

extension CosmoRealtimeAPI.Components.Schemas.OpenAILiveToolChoice {
    init(_ choice: OpenAILiveToolChoice) {
        switch choice {
        case .auto: self = .auto
        case .required: self = .required
        case .none: self = .none
        }
    }
}

extension CosmoRealtimeAPI.Components.Schemas.OpenAILiveServiceTier {
    init(_ tier: OpenAILiveServiceTier) {
        switch tier {
        case .auto: self = .auto
        case ._default: self = ._default
        case .flex: self = .flex
        case .priority: self = .priority
        }
    }
}

extension CosmoRealtimeAPI.Components.Schemas.OpenAILiveDelegation {
    init(_ delegation: OpenAILiveDelegation) {
        switch delegation {
        case .responses: self = .responses
        case .client: self = .client
        case .cosmo: self = .cosmo
        }
    }
}

extension CosmoRealtimeAPI.Components.Schemas.DelegationChannel {
    init(_ channel: DelegationChannel) {
        switch channel {
        case .thinking: self = .thinking
        case .commentary: self = .commentary
        case .instructions: self = .instructions
        }
    }
}
