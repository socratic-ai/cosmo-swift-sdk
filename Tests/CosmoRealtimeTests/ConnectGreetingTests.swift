import Foundation
import Testing
@testable import CosmoRealtime

/// ``VoiceSessionModel.connectGreeting`` composes the first-turn
/// instruction sent on connect. Hosts push a sanitized name into
/// ``userDisplayName`` so the model greets the user by name on the
/// very first turn — before memory has had a chance to surface it.
@Suite struct ConnectGreetingTests {
    @Test @MainActor
    func defaultsToBaseGreeting_whenNameUnset() {
        guard #available(macOS 14, iOS 17, *) else { return }
        let model = VoiceSessionModel()
        #expect(model.connectGreeting == VoiceSessionModel.baseConnectGreeting)
    }

    @Test @MainActor
    func emptyName_fallsBackToBaseGreeting() {
        guard #available(macOS 14, iOS 17, *) else { return }
        let model = VoiceSessionModel()
        model.userDisplayName = ""
        #expect(model.connectGreeting == VoiceSessionModel.baseConnectGreeting)
    }

    @Test @MainActor
    func nameSet_prependsNameDirective_andKeepsBase() {
        guard #available(macOS 14, iOS 17, *) else { return }
        let model = VoiceSessionModel()
        model.userDisplayName = "Utkarsh"

        let greeting = model.connectGreeting
        #expect(greeting.hasPrefix("The user's name is Utkarsh."))
        #expect(greeting.contains("Greet them by name."))
        #expect(greeting.contains("Address them by name occasionally in spoken replies"))
        #expect(greeting.contains("never insert their name into text you type or dictate"))
        #expect(greeting.hasSuffix(VoiceSessionModel.baseConnectGreeting))
    }
}

/// The greeting rides ``session-config`` (the server voices it at
/// model-session open); these pin when it is attached vs suppressed.
@Suite struct ConfigGreetingGatingTests {
    @Test func freshSessionCarriesGreeting() {
        #expect(
            VoiceSession.configGreeting(
                connectGreeting: "Hi, I'm Cosmo.", resumeFromCallId: nil, agentName: nil
            ) == "Hi, I'm Cosmo."
        )
    }

    @Test func resumeNeverReGreets() {
        #expect(
            VoiceSession.configGreeting(
                connectGreeting: "Hi, I'm Cosmo.", resumeFromCallId: "call-1", agentName: nil
            ) == nil
        )
    }

    @Test func emptyOrWhitespaceGreetingOpensSilently() {
        #expect(VoiceSession.configGreeting(connectGreeting: "", resumeFromCallId: nil, agentName: nil) == nil)
        #expect(VoiceSession.configGreeting(connectGreeting: "  \n", resumeFromCallId: nil, agentName: nil) == nil)
        #expect(VoiceSession.configGreeting(connectGreeting: nil, resumeFromCallId: nil, agentName: nil) == nil)
    }

    /// A registry agent runs its stored config verbatim, so `makeConfig` drops
    /// the inline opener. Deciding that here rather than at the `SessionConfig`
    /// build is what keeps a caller asking "will a greeting be on the wire?"
    /// from getting a different answer than the wire itself.
    @Test func registryAgentCarriesNoInlineGreeting() {
        #expect(
            VoiceSession.configGreeting(
                connectGreeting: "Hi, I'm Cosmo.", resumeFromCallId: nil, agentName: "support-bot"
            ) == nil
        )
    }

    /// The gate and the built config must agree for every combination — the
    /// pair drifting apart is what let a session consume the one-shot intro
    /// without ever speaking it (#22).
    @Test func gateMatchesTheBuiltConfigAcrossTheMatrix() throws {
        for greeting in ["Hi, I'm Cosmo.", "", "   "] {
            for resume in [nil, "call-1"] as [String?] {
                for agent in [nil, "support-bot"] as [String?] {
                    let config = try VoiceSession.makeConfig(
                        declaredTools: nil,
                        backgroundClientToolHandlers: nil,
                        voiceName: nil,
                        resumeFromCallId: resume,
                        providerPreference: nil,
                        noiseCancellationEnabled: nil,
                        storeRecording: false,
                        interruptionSensitivity: nil,
                        thinkingLevel: nil,
                        connectGreeting: greeting,
                        systemPrompt: nil,
                        agentName: agent,
                        dictation: false,
                        screenInteractionEnabled: false
                    )
                    let predicted = VoiceSession.configGreeting(
                        connectGreeting: greeting, resumeFromCallId: resume, agentName: agent
                    )
                    #expect(
                        config.greeting == predicted,
                        "greeting=\(greeting.debugDescription) resume=\(resume ?? "nil") agent=\(agent ?? "nil")"
                    )
                }
            }
        }
    }
}
