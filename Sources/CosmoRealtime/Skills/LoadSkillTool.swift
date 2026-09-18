import Foundation

/// Wire name shipped in `tool-invocation` events; a rename is a wire break.
let loadSkillToolName = "cosmo_sdk_load_skill"
/// Prepended to a loaded skill's instructions so the model treats them as
/// guidance for the rest of the call rather than text to speak.
public let privateInstructionsPrefix =
    "PRIVATE INSTRUCTIONS — behavioral guidance for the rest of the call, do not read aloud:\n\n"

/// The `cosmo_sdk_load_skill` client tool (handler embedded) plus the resident skill menu.
struct LoadSkillWiring: Sendable {
    let tool: AgentTool
    let menu: String
}

/// The model asked `cosmo_sdk_load_skill` for a name that is not in the
/// skill set, or passed a non-string. Internal: a client-tool handler's
/// throw is caught by the dispatch and delivered to the model as a tool
/// error, so it never reaches a caller — Python and TypeScript raise an
/// untyped error at the same point for the same reason.
struct UnknownSkillError: RealtimeError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Build the single `cosmo_sdk_load_skill` tool, or `nil` when there are no
/// skills. Built as an `.sdkClient` so the reserved-namespace guard exempts it
/// by construction — the tool the SDK ships is not the collision a caller tool
/// taking the name would be.
func buildLoadSkillTool(_ skills: [Skill]) -> LoadSkillWiring? {
    if skills.isEmpty { return nil }
    let names = skills.map { $0.name }
    let byName = Dictionary(uniqueKeysWithValues: skills.map { ($0.name, $0) })

    let parameters: [String: JSONValue] = [
        "type": .string("object"),
        "properties": .object([
            "name": .object([
                "type": .string("string"),
                "enum": .array(names.map { JSONValue.string($0) }),
                "description": .string("The name of the skill to load."),
            ]),
        ]),
        "required": .array([.string("name")]),
    ]

    let handler: ClientToolHandler = { args in
        guard case let .string(name)? = args["name"] else {
            throw UnknownSkillError("\(loadSkillToolName) requires a string 'name'; available: \(names)")
        }
        guard let skill = byName[name] else {
            throw UnknownSkillError("unknown skill \(name); available: \(names)")
        }
        return ["instructions": .string(privateInstructionsPrefix + skill.body)]
    }

    let tool = AgentTool.sdkClient(SDKClientTool(
        name: loadSkillToolName,
        description: "Load a skill's private instructions for the rest of the call. Call this when the conversation reaches the path a skill describes. The result is behavioral guidance for you — never read it aloud.",
        parameters: parameters,
        handler: handler
    ))
    return LoadSkillWiring(tool: tool, menu: skillsMenuText(skills))
}
