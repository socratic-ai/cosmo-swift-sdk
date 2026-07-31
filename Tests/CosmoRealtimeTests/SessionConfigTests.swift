import Foundation
import Testing
@testable import CosmoRealtime

@Suite("SessionConfig")
struct SessionConfigTests {

    private func encodedFields(_ config: SessionConfig) throws -> [String: JSONValue] {
        let data = try JSONEncoder().encode(try config.wirePayload())
        guard case .object(let fields) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            Issue.record("session-config did not encode to a JSON object")
            return [:]
        }
        return fields
    }

    private func object(_ fields: [String: JSONValue], _ key: String) -> [String: JSONValue]? {
        guard case .object(let nested)? = fields[key] else { return nil }
        return nested
    }

    @Test("wire payload carries type and version; unset fields stay absent")
    func defaultsStayAbsent() throws {
        let fields = try encodedFields(SessionConfig())
        #expect(fields["type"] == .string("session-config"))
        #expect(fields["version"] == .string(RealtimeSession.protocolVersion))
        // Empty agent/session sub-objects stay off the wire entirely.
        for absent in ["agent", "session"] {
            #expect(fields[absent] == nil, "expected \(absent) to stay off the wire")
        }
    }

    @Test("noise cancellation stays off the wire when unset, even with other agent fields set")
    func noiseCancellationAbsentWhenUnset() throws {
        // The agent block is present (instructions set), but an unset
        // noiseCancellationEnabled must not put the key on the wire — the
        // server only defaults it on when the field is absent from
        // ``model_fields_set``.
        let fields = try encodedFields(
            SessionConfig(instructions: "Be terse.", noiseCancellationEnabled: nil)
        )
        guard let agent = object(fields, "agent") else {
            Issue.record("expected an agent sub-object, got \(String(describing: fields["agent"]))")
            return
        }
        #expect(agent["instructions"] == .string("Be terse."))
        #expect(
            agent["noise_cancellation_enabled"] == nil,
            "unset noise cancellation must stay off the wire so the server default applies"
        )
    }

    @Test("explicit noise-cancellation false is emitted so it wins over the server default")
    func explicitNoiseCancellationFalseIsEmitted() throws {
        let fields = try encodedFields(SessionConfig(noiseCancellationEnabled: false))
        guard let agent = object(fields, "agent") else {
            Issue.record("expected an agent sub-object, got \(String(describing: fields["agent"]))")
            return
        }
        #expect(agent["noise_cancellation_enabled"] == .bool(false))
    }

    @Test("set fields serialize under their wire names, nested by scope")
    func setFieldsSerialize() throws {
        let fields = try encodedFields(
            SessionConfig(
                model: "gemini-live",
                modelOptions: .gemini(
                    temperature: 0.7, maxOutputTokens: 4096, thinkingLevel: .high),
                voice: "Puck",
                audioOutput: false,
                instructions: "Be terse.",
                speakingStyle: "Talk warmly.",
                tools: [
                    .client(
                        name: "get_local_time",
                        description: "Returns the local wall-clock time.",
                        parameters: ["type": .string("object")]
                    ),
                    .webSearch,
                ],
                interruptionSensitivity: .high,
                noiseCancellationEnabled: true,
                greeting: "Hi, I'm Cosmo.",
                resumeSessionId: "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d",
                storeRecording: false
            )
        )
        // Agent-scoped knobs nest under `agent`.
        guard let agent = object(fields, "agent") else {
            Issue.record("expected an agent sub-object, got \(String(describing: fields["agent"]))")
            return
        }
        #expect(agent["model"] == .string("gemini-live"))
        guard let modelOptions = object(agent, "model_options") else {
            Issue.record(
                "expected a model_options sub-object, got \(String(describing: agent["model_options"]))"
            )
            return
        }
        #expect(modelOptions["provider"] == .string("gemini"))
        #expect(modelOptions["temperature"] == .double(0.7))
        #expect(modelOptions["max_output_tokens"] == .int(4096))
        #expect(modelOptions["thinking_level"] == .string("high"))
        #expect(agent["voice"] == .string("Puck"))
        #expect(agent["audio_output"] == .bool(false))
        #expect(agent["instructions"] == .string("Be terse."))
        #expect(agent["speaking_style"] == .string("Talk warmly."))
        #expect(agent["interruption_sensitivity"] == .string("high"))
        #expect(agent["greeting"] == .string("Hi, I'm Cosmo."))
        // Audio is agent config, so noise cancellation nests under `agent`.
        #expect(agent["noise_cancellation_enabled"] == .bool(true))
        // Session-scoped knobs nest under `session`; resume_session_id rides
        // under the experimental knobs object inside it.
        guard let session = object(fields, "session") else {
            Issue.record("expected a session sub-object, got \(String(describing: fields["session"]))")
            return
        }
        #expect(
            session["experimental"]
                == .object(["resume_session_id": .string("0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d")])
        )
        #expect(session["store_recording"] == .bool(false))
        guard case .array(let tools)? = agent["tools"], tools.count == 2 else {
            Issue.record("expected two serialized tool specs, got \(String(describing: agent["tools"]))")
            return
        }
        guard case .object(let clientSpec) = tools[0], case .object(let serverSpec) = tools[1] else {
            Issue.record("tool specs did not encode as objects")
            return
        }
        #expect(clientSpec["kind"] == .string("client"))
        #expect(clientSpec["name"] == .string("get_local_time"))
        #expect(clientSpec["parameters"] == .object(["type": .string("object")]))
        #expect(serverSpec["kind"] == .string("web_search"))
        // Zero-config: the kind is the entire spec.
        #expect(serverSpec.count == 1)
    }

    @Test("client-tool handlers are local-only and never reach the wire")
    func handlersStayLocal() throws {
        let handler: ClientToolHandler = { _ in ["ok": .bool(true)] }
        let config = SessionConfig(
            tools: [
                .client(
                    name: "get_local_time",
                    description: "Returns the local wall-clock time.",
                    parameters: ["type": .string("object")],
                    handler: handler
                )
            ]
        )
        #expect(config.clientToolHandlers().keys.sorted() == ["get_local_time"])
        let fields = try encodedFields(config)
        guard let agent = object(fields, "agent"),
            case .array(let tools)? = agent["tools"], case .object(let spec) = tools[0]
        else {
            Issue.record("expected one serialized client-tool spec under agent")
            return
        }
        #expect(spec["handler"] == nil, "handler must not serialize onto the wire")
    }

    @Test("catalog agent serializes as agent.name + agent.inputs")
    func catalogAgentSerializes() throws {
        let fields = try encodedFields(
            SessionConfig(
                agentName: "driver-pay",
                agentInputs: ["caller_name": "Sam", "city": "NYC"]
            )
        )
        guard let agent = object(fields, "agent") else {
            Issue.record("expected an agent sub-object, got \(String(describing: fields["agent"]))")
            return
        }
        #expect(agent["type"] == .string("catalog"))
        #expect(agent["name"] == .string("driver-pay"))
        #expect(
            agent["inputs"]
                == .object(["caller_name": .string("Sam"), "city": .string("NYC")])
        )
        #expect(agent.count == 3, "no other keys may ride along: \(agent.keys.sorted())")
    }

    @Test("a bare catalog launch serializes only the tag and agent.name; unset stays absent")
    func bareCatalogAgentSerializes() throws {
        let fields = try encodedFields(SessionConfig(agentName: "driver-pay"))
        #expect(
            object(fields, "agent")
                == ["type": .string("catalog"), "name": .string("driver-pay")]
        )
    }

    @Test("a stored-config field alongside a catalog launch throws instead of riding along")
    func storedConfigFieldWithCatalogAgentThrows() throws {
        let config = SessionConfig(agentName: "driver-pay", voice: "Puck")
        #expect(throws: RealtimeSessionError.self) {
            try config.wirePayload()
        }
    }

    @Test("dictation composes audioOutput=false and strips every tool")
    func dictationComposesFromPrimitives() throws {
        let config = try VoiceSession.makeConfig(
            declaredTools: [
                DeclaredClientTool(
                    name: "type_text", description: "types text",
                    parametersJSON: #"{"type":"object"}"#
                )
            ],
            backgroundClientToolHandlers: nil,
            voiceName: nil,
            resumeFromCallId: nil,
            providerPreference: nil,
            noiseCancellationEnabled: nil,
            storeRecording: false,
            interruptionSensitivity: nil,
            thinkingLevel: nil,
            connectGreeting: nil,
            systemPrompt: "Transcribe only.",
            agentName: nil,
            dictation: true,
            screenInteractionEnabled: false
        )
        #expect(config.audioOutput == false)
        #expect(config.tools == nil, "dictation must strip every tool")
    }

    @Test("non-dictation sessions leave audioOutput unset on the wire")
    func nonDictationLeavesAudioOutputUnset() throws {
        let config = try VoiceSession.makeConfig(
            declaredTools: nil,
            backgroundClientToolHandlers: nil,
            voiceName: nil,
            resumeFromCallId: nil,
            providerPreference: nil,
            noiseCancellationEnabled: nil,
            storeRecording: true,
            interruptionSensitivity: nil,
            thinkingLevel: nil,
            connectGreeting: nil,
            systemPrompt: nil,
            agentName: nil,
            dictation: false,
            screenInteractionEnabled: false
        )
        #expect(config.audioOutput == nil)
    }
}

extension SessionConfigTests {
    @Test("typed server opt-ins serialize as bare kinds")
    func typedServerOptInsSerializeAsKinds() throws {
        var config = SessionConfig(
            instructions: "Be helpful.",
            tools: [.webSearch, .examineImage, .detect, .point]
        )
        config.declaresScreenInteraction = true
        let fields = try encodedFields(config)
        guard let agent = object(fields, "agent"),
            case .array(let tools)? = agent["tools"]
        else {
            Issue.record("expected agent.tools on the wire")
            return
        }
        var kinds: [JSONValue] = []
        for tool in tools {
            guard case .object(let spec) = tool else {
                Issue.record("tool spec did not encode as an object")
                return
            }
            // Zero-config entries: the kind is the entire spec.
            #expect(spec.count == 1)
            if let kind = spec["kind"] { kinds.append(kind) }
        }
        #expect(
            kinds == [
                .string("web_search"),
                .string("examine_image"),
                .string("detect"),
                .string("point"),
                .string("screen_interaction"),
            ]
        )
    }

    @Test("the capability is not declared without a conformer, and dictation strips it")
    func capabilityFollowsTheConformer() throws {
        let bare = try VoiceSession.makeConfig(
            declaredTools: nil,
            backgroundClientToolHandlers: nil,
            voiceName: nil,
            resumeFromCallId: nil,
            providerPreference: nil,
            noiseCancellationEnabled: nil,
            storeRecording: false,
            interruptionSensitivity: nil,
            thinkingLevel: nil,
            connectGreeting: nil,
            systemPrompt: nil,
            agentName: nil,
            dictation: false,
            screenInteractionEnabled: true
        )
        #expect(bare.declaresScreenInteraction)
        // The locator pair rides every session too — pointing must not depend
        // on an agent carrying them in builtin_tool_names. Asserted as an exact
        // list so a cutover that rewrites this block can't drop them silently.
        #expect(bare.tools == [.webSearch, .examineImage, .detect, .point])

        let dictation = try VoiceSession.makeConfig(
            declaredTools: nil,
            backgroundClientToolHandlers: nil,
            voiceName: nil,
            resumeFromCallId: nil,
            providerPreference: nil,
            noiseCancellationEnabled: nil,
            storeRecording: false,
            interruptionSensitivity: nil,
            thinkingLevel: nil,
            connectGreeting: nil,
            systemPrompt: nil,
            agentName: nil,
            dictation: true,
            screenInteractionEnabled: true
        )
        #expect(dictation.declaresScreenInteraction == false)
        #expect(dictation.tools == nil)
    }
}
