/// The tool constructors.
///
/// Every tool an agent can use is built by calling one of these, and every one
/// returns ``AgentTool`` — the only tool type a caller names. In a `tools:`
/// literal the type is inferred, so they read as `.webSearchTool()`; typing
/// `AgentTool.` lists the whole catalogue. Names match `web_search_tool()` in
/// Python and `webSearchTool()` in TypeScript.

import Foundation

extension AgentTool {
    // Same spelling as the payload cases, so the SDK's own construction sites
    // read unchanged while the cases themselves stay internal.
    static var webSearch: AgentTool { AgentTool(.webSearch) }
    static var examineImage: AgentTool { AgentTool(.examineImage) }
    static var detectObjects: AgentTool { AgentTool(.detectObjects) }
    static var pointAtObject: AgentTool { AgentTool(.pointAtObject) }
    static var speakerLog: AgentTool { AgentTool(.speakerLog) }
    static var endCall: AgentTool { AgentTool(.endCall) }

    static func client(
        name: String,
        description: String,
        parameters: [String: JSONValue],
        handler: @escaping ClientToolHandler
    ) -> AgentTool {
        AgentTool(.client(name: name, description: description, parameters: parameters, handler: handler))
    }

    static func backgroundClient(
        name: String,
        description: String,
        parameters: [String: JSONValue],
        handler: @escaping BackgroundClientToolHandler
    ) -> AgentTool {
        AgentTool(.backgroundClient(name: name, description: description, parameters: parameters, handler: handler))
    }

    static func sdkClient(_ tool: SDKClientTool) -> AgentTool { AgentTool(.sdkClient(tool)) }

    static func screenLocate(_ tool: ScreenLocateTool) -> AgentTool { AgentTool(.screenLocate(tool)) }
}

// MARK: - Server tools

extension AgentTool {
    /// Live web search, run on Cosmo's backend.
    public static func webSearchTool() -> AgentTool { .webSearch }

    /// Examine the freshest published video frame at full resolution.
    public static func examineImageTool() -> AgentTool { .examineImage }

    /// Locate a named object in the frame, returning one box per matching instance.
    public static func detectObjectsTool() -> AgentTool { .detectObjects }

    /// Locate a named object in the frame, returning points.
    public static func pointAtObjectTool() -> AgentTool { .pointAtObject }

    /// Read who said what from the room's speaker-labelled transcript.
    public static func speakerLogTool() -> AgentTool { .speakerLog }

    /// Let the agent hang up the call itself. Ending binds the call, not
    /// just the agent — every leg drops — and the spoken goodbye is
    /// allowed to finish first.
    public static func endCallTool() -> AgentTool { .endCall }
}

// MARK: - Client tools you declare

extension AgentTool {
    /// Declare a client tool: the SDK advertises it at session start and the
    /// server routes matching invocations back over the transport.
    ///
    /// `input` is the JSON Schema for the tool's arguments; `Args` is decoded
    /// from it before the handler runs, so a malformed call never reaches you.
    public static func clientTool<Args: Decodable & Sendable>(
        name: String,
        description: String,
        input: ToolSchema,
        handler: @escaping @Sendable (Args) async throws -> [String: JSONValue]
    ) throws -> AgentTool {
        try .define(name: name, description: description, input: input, handler: handler)
    }

    /// Declare a client tool from a hand-written JSON Schema, for a schema the
    /// typed form does not express. The handler receives the decoded arguments
    /// verbatim.
    public static func clientTool(
        name: String,
        description: String,
        parameters: [String: JSONValue],
        handler: @escaping ClientToolHandler
    ) -> AgentTool {
        .client(name: name, description: description, parameters: parameters, handler: handler)
    }

    /// Declare a client tool whose work outlives the voice turn. Its handler
    /// acks the call through the ``ClientToolJob`` and delivers the result later.
    public static func backgroundClientTool<Args: Decodable & Sendable>(
        name: String,
        description: String,
        input: ToolSchema,
        handler: @escaping @Sendable (Args, ClientToolJob) async throws -> Void
    ) throws -> AgentTool {
        try .defineBackground(name: name, description: description, input: input, handler: handler)
    }

    /// Declare a background client tool from a hand-written JSON Schema.
    public static func backgroundClientTool(
        name: String,
        description: String,
        parameters: [String: JSONValue],
        handler: @escaping BackgroundClientToolHandler
    ) -> AgentTool {
        .backgroundClient(name: name, description: description, parameters: parameters, handler: handler)
    }
}

// MARK: - Client tools the SDK ships

extension AgentTool {
    /// The box renderer, ready to add alongside the locator that feeds it.
    public static func drawBoxTool(
        onDraw: @escaping @MainActor @Sendable (DrawBoxRequest) -> DrawOutcome
    ) -> AgentTool { .drawBox(onDraw: onDraw) }

    /// The point renderer. Same contract as ``drawBoxTool(onDraw:)``, with a
    /// ``DrawPointRequest``.
    public static func drawPointTool(
        onDraw: @escaping @MainActor @Sendable (DrawPointRequest) -> DrawOutcome
    ) -> AgentTool { .drawPoint(onDraw: onDraw) }

    /// Click the element the locator grounded.
    public static func screenClickElementTool(
        onClick: @escaping @Sendable (ScreenClickRequest) async throws -> ScreenClickOutcome
    ) -> AgentTool { .screenClickElement(onClick: onClick) }

    /// Highlight the element the locator grounded.
    public static func screenHighlightElementTool(
        onHighlight: @escaping @Sendable (ScreenHighlightRequest) async throws -> ScreenHighlightOutcome
    ) -> AgentTool { .screenHighlightElement(onHighlight: onHighlight) }

    /// Highlight a box the model located itself — no capture, no grounding.
    public static func screenHighlightBoxTool(
        onHighlight: @escaping @Sendable (ScreenHighlightBoxRequest) async throws -> ScreenHighlightOutcome
    ) -> AgentTool { .screenHighlightBox(onHighlight: onHighlight) }

    /// Offer the host's screen to the server-executed locator. The request
    /// says what the caller will read — see ``ScreenCaptureRequest``.
    public static func screenLocateTool(
        capture: @escaping ScreenCaptureHandler
    ) -> AgentTool { .screenLocate(capture: capture) }
}
