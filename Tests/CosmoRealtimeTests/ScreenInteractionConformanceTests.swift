import CoreGraphics
import Foundation
import Testing
@testable import CosmoRealtime

/// Executes the shared ScreenInteraction conformance vectors
/// (``sdks/cosmo-realtime/contract/screen-interaction-vectors.json``) against the
/// Swift ``ScreenInteractionBridge``. Swift and TS both run the same file, so a
/// wire-contract drift (capture cache, published payload, activate/highlight
/// resolution) fails CI in whichever SDK disagrees. The TS mirror is
/// `screen_interaction_conformance.test.ts`.
@Suite struct ScreenInteractionConformanceTests {

    // MARK: - Vector model

    private struct VectorElement: Decodable {
        let index: Int
        let role: String
        let frame: [Double]
        let title: String?
        let label: String?
        let value: String?
    }
    private struct VectorCapture: Decodable {
        let image_b64: String
        let elements: [VectorElement]
    }
    private struct ActivateExpect: Decodable {
        let index: Int
        let button: String
        let double: Bool
    }
    private struct HighlightExpect: Decodable {
        let index: Int
        let label: String
        let placement: String
        let interaction: String
    }
    private struct HighlightRegionExpect: Decodable {
        let region: [Double]  // [x, y, width, height], display fractions
        let label: String
        let placement: String
        let interaction: String
        let element_title: String?
        let element_role: String?
    }
    private struct PublishedExpect: Decodable {
        let topic: String
        let payload: JSONValue
    }
    private struct Step: Decodable {
        let rpc: String
        let request: [String: JSONValue]
        let expect_reply: [String: JSONValue]
        let expect_published: PublishedExpect?
        let expect_no_publish: Bool?
        let advance_clock_seconds: Double?
        let expect_activate: ActivateExpect?
        let expect_highlight: HighlightExpect?
        let expect_highlight_region: HighlightRegionExpect?
    }
    private struct Vector: Decodable {
        let name: String
        let capture: VectorCapture
        let capture_supported: Bool?
        let highlight_result: Bool?
        let steps: [Step]
    }
    private struct VectorFile: Decodable {
        let vectors: [Vector]
    }

    private static func loadVectors() throws -> [Vector] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CosmoRealtimeTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // swift/
            .deletingLastPathComponent()  // cosmo-realtime/
            .appendingPathComponent("contract/screen-interaction-vectors.json", isDirectory: false)
        return try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: url)).vectors
    }

    // MARK: - Fakes

    /// Advanceable clock injected into the cache so the vectors' TTL step is
    /// deterministic instead of wall-clock-bound.
    private final class ClockBox: @unchecked Sendable {
        private let lock = NSLock()
        private var t = Date(timeIntervalSince1970: 1_000_000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ seconds: Double) {
            lock.lock(); t = t.addingTimeInterval(seconds); lock.unlock()
        }
    }

    private final class PublishedBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(topic: String, data: Data)] = []
        var entries: [(topic: String, data: Data)] {
            lock.lock(); defer { lock.unlock() }; return items
        }
        func append(_ topic: String, _ data: Data) {
            lock.lock(); items.append((topic, data)); lock.unlock()
        }
    }

    private final class VectorConformer: ScreenInteraction, @unchecked Sendable {
        let canned: ScreenCapture
        let captureSupported: Bool
        let highlightResult: Bool
        private let lock = NSLock()
        private var activate: [(element: ScreenElement, action: ScreenAction)] = []
        private var highlight: [(element: ScreenElement, label: String, placement: ScreenPlacement, affordance: ScreenAffordance)] = []
        private var highlightRegion: [(region: ScreenRegion, element: ScreenElementHint?, label: String, placement: ScreenPlacement, affordance: ScreenAffordance)] = []
        var activateCalls: [(element: ScreenElement, action: ScreenAction)] {
            lock.lock(); defer { lock.unlock() }; return activate
        }
        var highlightCalls: [(element: ScreenElement, label: String, placement: ScreenPlacement, affordance: ScreenAffordance)] {
            lock.lock(); defer { lock.unlock() }; return highlight
        }
        var highlightRegionCalls: [(region: ScreenRegion, element: ScreenElementHint?, label: String, placement: ScreenPlacement, affordance: ScreenAffordance)] {
            lock.lock(); defer { lock.unlock() }; return highlightRegion
        }

        init(canned: ScreenCapture, captureSupported: Bool, highlightResult: Bool) {
            self.canned = canned
            self.captureSupported = captureSupported
            self.highlightResult = highlightResult
        }

        func capture() async throws -> ScreenCapture {
            if !captureSupported { throw ScreenCaptureUnavailable(message: "unsupported") }
            return canned
        }

        func activate(
            element: ScreenElement, capture: ScreenCapture, action: ScreenAction
        ) async throws -> ScreenActionOutcome {
            lock.lock(); activate.append((element, action)); lock.unlock()
            return ScreenActionOutcome(true)
        }

        func highlightElement(
            element: ScreenElement, capture: ScreenCapture,
            label: String, placement: ScreenPlacement, affordance: ScreenAffordance
        ) async throws -> ScreenActionOutcome {
            lock.lock(); highlight.append((element, label, placement, affordance)); lock.unlock()
            return ScreenActionOutcome(highlightResult)
        }

        func highlightRegion(
            region: ScreenRegion, element: ScreenElementHint?,
            label: String, placement: ScreenPlacement, affordance: ScreenAffordance
        ) async throws -> ScreenActionOutcome {
            lock.lock(); highlightRegion.append((region, element, label, placement, affordance)); lock.unlock()
            return ScreenActionOutcome(highlightResult)
        }
    }

    // MARK: - Runner

    private func cannedCapture(_ vector: Vector) -> ScreenCapture {
        let elements = vector.capture.elements.map { e in
            ScreenElement(
                index: e.index, role: e.role,
                title: e.title, label: e.label, value: e.value,
                frame: CGRect(x: e.frame[0], y: e.frame[1], width: e.frame[2], height: e.frame[3])
            )
        }
        return ScreenCapture(
            imageJPEG: Data(base64Encoded: vector.capture.image_b64) ?? Data(),
            elements: elements,
            context: ScreenCaptureContext(appPID: nil, windowFrame: nil)
        )
    }

    private func run(_ vector: Vector) async throws {
        let fake = VectorConformer(
            canned: cannedCapture(vector),
            captureSupported: vector.capture_supported ?? true,
            highlightResult: vector.highlight_result ?? true
        )
        let clock = ClockBox()
        let published = PublishedBox()
        let cache = ScreenCaptureCache(now: { clock.now })
        let bridge = ScreenInteractionBridge(conformer: fake, cache: cache)
        bridge.bindSendBytes { data, topic in published.append(topic, data) }

        for (i, step) in vector.steps.enumerated() {
            let ctx = "\(vector.name) step \(i) (\(step.rpc))"
            // The shared vectors express time in seconds.
            if let advance = step.advance_clock_seconds { clock.advance(advance) }

            guard let rpc = ScreenInteractionRPC(rawValue: step.rpc) else {
                Issue.record("\(ctx): unknown rpc \(step.rpc)")
                return
            }
            let reply = try await bridge.handle(rpc, args: step.request)
            for (key, expected) in step.expect_reply {
                #expect(Self.jsonEqual(reply[key] ?? .null, expected), "\(ctx): reply[\(key)]")
            }

            if let pub = step.expect_published {
                #expect(!published.entries.isEmpty, "\(ctx): expected a published payload")
                if let last = published.entries.last {
                    #expect(last.topic == pub.topic, "\(ctx): topic")
                    let decoded = try JSONDecoder().decode(JSONValue.self, from: last.data)
                    #expect(Self.jsonEqual(decoded, pub.payload), "\(ctx): published payload mismatch")
                }
            }
            if step.expect_no_publish == true {
                #expect(published.entries.isEmpty, "\(ctx): expected no publish")
            }

            switch rpc {
            case .activate:
                if let expected = step.expect_activate {
                    let call = fake.activateCalls.last
                    #expect(call?.element.index == expected.index, "\(ctx): activated index")
                    #expect(call?.action.button.rawValue == expected.button, "\(ctx): button")
                    #expect(call?.action.double == expected.double, "\(ctx): double")
                } else {
                    #expect(fake.activateCalls.isEmpty, "\(ctx): activate should not have been called")
                }
            case .highlightElement:
                if let expected = step.expect_highlight {
                    let call = fake.highlightCalls.last
                    #expect(call?.element.index == expected.index, "\(ctx): highlighted index")
                    #expect(call?.label == expected.label, "\(ctx): label")
                    #expect(call?.placement.rawValue == expected.placement, "\(ctx): placement")
                    #expect(call?.affordance.rawValue == expected.interaction, "\(ctx): interaction")
                } else {
                    #expect(fake.highlightCalls.isEmpty, "\(ctx): highlight should not have been called")
                }
            case .highlightRegion:
                if let expected = step.expect_highlight_region {
                    let call = fake.highlightRegionCalls.last
                    #expect(call?.region.x == expected.region[0], "\(ctx): region x")
                    #expect(call?.region.y == expected.region[1], "\(ctx): region y")
                    #expect(call?.region.width == expected.region[2], "\(ctx): region width")
                    #expect(call?.region.height == expected.region[3], "\(ctx): region height")
                    #expect(call?.label == expected.label, "\(ctx): label")
                    #expect(call?.placement.rawValue == expected.placement, "\(ctx): placement")
                    #expect(call?.affordance.rawValue == expected.interaction, "\(ctx): interaction")
                    #expect(call?.element?.title == expected.element_title, "\(ctx): element title")
                    #expect(call?.element?.role == expected.element_role, "\(ctx): element role")
                } else {
                    #expect(fake.highlightRegionCalls.isEmpty, "\(ctx): highlightRegion should not have been called")
                }
            case .capture:
                break
            }
        }
    }

    @Test func bridgeConformsToSharedVectors() async throws {
        let vectors = try Self.loadVectors()
        #expect(vectors.count == 16)
        for vector in vectors {
            try await run(vector)
        }
    }

    // MARK: - Numeric-tolerant JSON equality (matches Python `==` / TS `toEqual`)

    private static func jsonEqual(_ a: JSONValue, _ b: JSONValue) -> Bool {
        switch (a, b) {
        case let (.string(x), .string(y)): return x == y
        case let (.bool(x), .bool(y)): return x == y
        case let (.int(x), .int(y)): return x == y
        case let (.double(x), .double(y)): return x == y
        case let (.int(x), .double(y)): return Double(x) == y
        case let (.double(x), .int(y)): return x == Double(y)
        case (.null, .null): return true
        case let (.array(x), .array(y)):
            return x.count == y.count && zip(x, y).allSatisfy { jsonEqual($0, $1) }
        case let (.object(x), .object(y)):
            return x.count == y.count
                && x.allSatisfy { key, value in
                    guard let other = y[key] else { return false }
                    return jsonEqual(value, other)
                }
        default:
            return false
        }
    }
}
