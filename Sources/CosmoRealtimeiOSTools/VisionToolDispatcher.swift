import CosmoRealtime
import CoreGraphics
import Foundation
import ImageIO

public struct VisionToolError: Error, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// Routes a model-issued client-tool call to its tool's measurement and returns
/// the JSON reply object. The app owns the bridge: install a client-tool handler
/// on the session (the high-level `VoiceSession` / `RealtimeSession`
/// `SessionConfig.Tool.client` surface) and, inside it, grab the current camera
/// still and call `run`. The handler's returned `[String: JSONValue]` IS the
/// reply — the SDK wraps it in the `{ok, result, error}` envelope; there is no
/// per-call send.
///
/// ```swift
/// // inside the session's client-tool handler; `args` is the decoded call:
/// guard let frame = await camera.currentFrame() else {
///     throw VisionToolError("camera is off — ask the user to enable it")
/// }
/// return try await VisionToolDispatcher.run(name: toolName, args: args, frame: frame)
/// ```
///
/// `frame` is the current camera still — capture is the app's `CameraSource` (the
/// PERCEIVE layer; not in the SDK yet). Lookup + capability gating come from
/// `VisionToolRegistry`; per-tool OS gating lives in each tool's `isSupported`, so
/// this entry point is not itself `@available`-bound.
public enum VisionToolDispatcher {
    public static func run(
        name: String,
        args: [String: JSONValue] = [:],
        frame: CGImage,
        orientation: CGImagePropertyOrientation = .up
    ) async throws -> [String: JSONValue] {
        guard let tool = VisionToolRegistry.tool(named: name) else {
            throw VisionToolError("unknown_tool: \(name)")
        }
        guard tool.isSupported else {
            throw VisionToolError("unsupported_tool: \(name) needs a newer OS")
        }
        return try await tool.run(frame: frame, args: args, orientation: orientation)
    }
}
