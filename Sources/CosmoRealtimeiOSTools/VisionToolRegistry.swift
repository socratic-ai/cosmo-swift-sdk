import CosmoRealtime
import Foundation

/// The tools the kit ships. Adding a tool = add its file under `Tools/` and one
/// line here; nothing else in the module changes. Keep entries append-ordered so
/// parallel additions conflict trivially (a one-line merge).
public enum VisionToolRegistry {
    public static let all: [any VisionToolProviding.Type] = [
        FaceLandmarksTool.self,
        CaptureQualityTool.self,
        ReadTextTool.self,
        BodyPoseTool.self,
        HandPoseTool.self,
        ScanBarcodeTool.self,
        ClassifyImageTool.self,
        CameraLevelTool.self,
        ForegroundSubjectTool.self,
        FaceRegionsTool.self,
        AnalyzeColorTool.self,
        MeasureLightingTool.self,
        CompareToReferenceTool.self,
        FaceContoursTool.self,
    ]

    /// The tool advertised under `name`, or nil if unknown — the dispatch lookup.
    static func tool(named name: String) -> (any VisionToolProviding.Type)? {
        all.first { $0.name == name }
    }

    /// Declarations for every tool the device can actually run right now — pass
    /// straight to `VoiceSession.start(declaredTools:)`. Skips unsupported tools so
    /// the model is never advertised a capability that would only fail.
    public static func declaredTools() -> [DeclaredClientTool] {
        all.filter { $0.isSupported }.map { $0.declaredTool() }
    }
}
