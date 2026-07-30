import Foundation
import Testing
@testable import CosmoRealtime

@Suite("draw_path contract + decode")
struct DrawPathToolTests {
    @Test("wire name is the pinned, backend-legal value")
    func wireName() {
        // Pin the wire name: a rename is a wire break.
        #expect(DrawPathTool.name == "draw_path")
        // Mirrors the backend regex `^[a-z][a-z0-9_]{2,63}$` from client_declared.py.
        let pattern = #/^[a-z][a-z0-9_]{2,63}$/#
        #expect(DrawPathTool.name.wholeMatch(of: pattern) != nil)
    }

    @Test("parametersJSON is a wire-legal object requiring a points array")
    func parametersSchema() throws {
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(DrawPathTool.parametersJSON.utf8)) as? [String: Any]
        )
        #expect(object["type"] as? String == "object")
        #expect(object["required"] as? [String] == ["points"])
        let properties = try #require(object["properties"] as? [String: Any])

        let points = try #require(properties["points"] as? [String: Any])
        #expect(points["type"] as? String == "array")
        let item = try #require(points["items"] as? [String: Any])
        #expect(item["required"] as? [String] == ["x", "y"])

        let style = try #require(properties["style"] as? [String: Any])
        #expect(Set(try #require(style["enum"] as? [String])) == ["stroke", "arrow"])

        // The schema must survive the backend's restricted dialect, or the whole
        // tool is rejected and never offered to the model.
        #expect(ClientToolSchemaDialect.firstViolation(inSchemaJSON: DrawPathTool.parametersJSON) == nil)
    }

    @Test("declaredTool carries the tool's identity")
    func declaration() {
        let declared = DrawPathTool.declaredTool()
        #expect(declared.name == DrawPathTool.name)
        #expect(declared.description == DrawPathTool.toolDescription)
        #expect(declared.group == "ui")
    }

    @Test("decodes a well-formed path with closed, style, and label")
    func decodesValidRequest() throws {
        let args: [String: JSONValue] = [
            "points": .array([
                .object(["x": .double(0.1), "y": .double(0.2)]),
                .object(["x": .double(0.3), "y": .double(0.4)]),
                .object(["x": .double(0.5), "y": .double(0.6)]),
            ]),
            "closed": .bool(true),
            "style": .string("arrow"),
            "label": .string("blend up & out"),
        ]
        let request = try #require(DrawPathTool.request(from: args))
        #expect(request == DrawPathRequest(
            points: [
                NormalizedPoint(x: 0.1, y: 0.2),
                NormalizedPoint(x: 0.3, y: 0.4),
                NormalizedPoint(x: 0.5, y: 0.6),
            ],
            closed: true,
            style: .arrow,
            label: "blend up & out"
        ))
    }

    @Test("closed, style, and label default when omitted")
    func appliesDefaults() throws {
        let args: [String: JSONValue] = [
            "points": .array([
                .object(["x": .double(0.2), "y": .double(0.2)]),
                .object(["x": .double(0.8), "y": .double(0.8)]),
            ]),
        ]
        let request = try #require(DrawPathTool.request(from: args))
        #expect(request.closed == false)
        #expect(request.style == .stroke)
        #expect(request.label == nil)
        #expect(request.points.count == 2)
    }

    @Test("accepts integer-valued coordinates and clamps out-of-range points")
    func decodesIntegerAndClampsCoordinates() throws {
        let args: [String: JSONValue] = [
            "points": .array([
                .object(["x": .int(0), "y": .int(1)]),         // bare ints
                .object(["x": .double(-0.2), "y": .double(1.5)]), // out of range
            ]),
        ]
        let request = try #require(DrawPathTool.request(from: args))
        #expect(request.points == [
            NormalizedPoint(x: 0, y: 1),
            NormalizedPoint(x: 0, y: 1),
        ])
    }

    @Test("an unknown style falls back to stroke")
    func unknownStyleFallsBack() throws {
        let args: [String: JSONValue] = [
            "points": .array([
                .object(["x": .double(0.2), "y": .double(0.2)]),
                .object(["x": .double(0.8), "y": .double(0.8)]),
            ]),
            "style": .string("squiggle"),
        ]
        let request = try #require(DrawPathTool.request(from: args))
        #expect(request.style == .stroke)
    }

    @Test("returns nil when there are fewer than two valid points")
    func rejectsTooFewPoints() {
        // No points key at all.
        #expect(DrawPathTool.request(from: ["label": .string("x")]) == nil)
        // Empty array.
        #expect(DrawPathTool.request(from: ["points": .array([])]) == nil)
        // A single valid point.
        #expect(DrawPathTool.request(from: [
            "points": .array([.object(["x": .double(0.1), "y": .double(0.2)])]),
        ]) == nil)
        // Two entries but only one is well-formed (the other is dropped).
        #expect(DrawPathTool.request(from: [
            "points": .array([
                .object(["x": .double(0.1), "y": .double(0.2)]),
                .object(["x": .string("nope"), "y": .double(0.4)]),
            ]),
        ]) == nil)
    }
}
