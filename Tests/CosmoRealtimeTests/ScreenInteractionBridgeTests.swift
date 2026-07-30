import CoreGraphics
import Foundation
import Testing
@testable import CosmoRealtime

/// A test conformer that returns a canned capture and records the activate /
/// highlight calls the bridge routes to it — the Swift counterpart of the
/// Python SDK's `FakeScreenInteraction` conformance fixture.
private final class FakeScreenInteraction: ScreenInteraction, @unchecked Sendable {
    var canned: ScreenCapture
    var captureError: Error?
    var activateResult = ScreenActionOutcome(true)
    var highlightResult = ScreenActionOutcome(true)
    private(set) var captureCount = 0
    private(set) var activateCalls: [(element: ScreenElement, action: ScreenAction)] = []
    private(set) var highlightCalls: [(element: ScreenElement, label: String, placement: ScreenPlacement, affordance: ScreenAffordance)] = []
    private(set) var highlightRegionCalls: [(region: ScreenRegion, element: ScreenElementHint?, label: String, placement: ScreenPlacement, affordance: ScreenAffordance)] = []

    init(canned: ScreenCapture) { self.canned = canned }

    func capture() async throws -> ScreenCapture {
        captureCount += 1
        if let captureError { throw captureError }
        return canned
    }

    func activate(
        element: ScreenElement, capture: ScreenCapture, action: ScreenAction
    ) async throws -> ScreenActionOutcome {
        activateCalls.append((element, action))
        return activateResult
    }

    func highlightElement(
        element: ScreenElement, capture: ScreenCapture,
        label: String, placement: ScreenPlacement, affordance: ScreenAffordance
    ) async throws -> ScreenActionOutcome {
        highlightCalls.append((element, label, placement, affordance))
        return highlightResult
    }

    func highlightRegion(
        region: ScreenRegion, element: ScreenElementHint?,
        label: String, placement: ScreenPlacement, affordance: ScreenAffordance
    ) async throws -> ScreenActionOutcome {
        highlightRegionCalls.append((region, element, label, placement, affordance))
        return highlightResult
    }
}

@Suite struct ScreenInteractionBridgeTests {
    @Test func captureRPCRawValuesMatchWire() {
        #expect(ScreenInteractionRPC.capture.rawValue == "screen_interaction_capture")
        #expect(ScreenInteractionRPC.activate.rawValue == "screen_interaction_activate")
        #expect(ScreenInteractionRPC.highlightElement.rawValue == "screen_interaction_highlight")
        #expect(ScreenInteractionRPC.highlightRegion.rawValue == "screen_interaction_highlight_region")
        #expect(ScreenInteractionRPC.captureTopic == "screen_interaction_capture")
    }

    private static func capture(elementCount: Int = 2) -> ScreenCapture {
        ScreenCapture(
            imageJPEG: Data([0xff, 0xd8]),
            elements: (0..<elementCount).map { i in
                ScreenElement(
                    index: i, role: "AXButton", title: "b\(i)", label: nil, value: nil,
                    frame: CGRect(x: Double(i) * 10, y: 0, width: 20, height: 20)
                )
            },
            context: ScreenCaptureContext(appPID: 7, windowFrame: nil)
        )
    }

    private final class Sent: @unchecked Sendable {
        var payloads: [(data: Data, topic: String)] = []
    }

    private func makeBridge(_ fake: FakeScreenInteraction) -> (ScreenInteractionBridge, Sent) {
        let sent = Sent()
        let bridge = ScreenInteractionBridge(conformer: fake, cache: ScreenCaptureCache())
        bridge.bindSendBytes { data, topic in sent.payloads.append((data, topic)) }
        return (bridge, sent)
    }

    @Test func captureCachesAndPublishesPayload() async throws {
        let fake = FakeScreenInteraction(canned: Self.capture())
        let (bridge, sent) = makeBridge(fake)

        let reply = try await bridge.handle(.capture, args: ["capture_id": .string("cap1")])

        #expect(reply["captured"]?.boolValue == true)
        let published = try #require(sent.payloads.first)
        #expect(sent.payloads.count == 1)
        #expect(published.topic == ScreenInteractionRPC.captureTopic)
        let json = try #require(
            try JSONSerialization.jsonObject(with: published.data) as? [String: Any]
        )
        #expect(json["capture_id"] as? String == "cap1")
        #expect(json["mime_type"] as? String == "image/jpeg")
        #expect((json["ax_elements"] as? [[String: Any]])?.count == 2)
    }

    @Test func captureUnavailableDeclinesWithoutPublish() async throws {
        let fake = FakeScreenInteraction(canned: Self.capture())
        fake.captureError = ScreenCaptureUnavailable(message: "sharing off")
        let (bridge, sent) = makeBridge(fake)

        let reply = try await bridge.handle(.capture, args: ["capture_id": .string("cap1")])

        #expect(reply["captured"]?.boolValue == false)
        #expect(reply["message"]?.stringValue == "sharing off")
        #expect(sent.payloads.isEmpty)
    }

    @Test func activateResolvesAndActs() async throws {
        let fake = FakeScreenInteraction(canned: Self.capture())
        let (bridge, _) = makeBridge(fake)
        _ = try await bridge.handle(.capture, args: ["capture_id": .string("cap1")])

        let reply = try await bridge.handle(.activate, args: [
            "capture_id": .string("cap1"), "element_idx": .int(1),
            "button": .string("secondary"), "double": .bool(true),
        ])

        #expect(reply["activated"]?.boolValue == true)
        let call = try #require(fake.activateCalls.first)
        #expect(fake.activateCalls.count == 1)
        #expect(call.element.index == 1)
        #expect(call.action.button == .secondary)
        #expect(call.action.double == true)
    }

    @Test func activateDefaultsToPrimarySingle() async throws {
        let fake = FakeScreenInteraction(canned: Self.capture())
        let (bridge, _) = makeBridge(fake)
        _ = try await bridge.handle(.capture, args: ["capture_id": .string("cap1")])

        _ = try await bridge.handle(.activate, args: [
            "capture_id": .string("cap1"), "element_idx": .int(0),
        ])

        let call = try #require(fake.activateCalls.first)
        #expect(call.action.button == .primary)
        #expect(call.action.double == false)
    }

    @Test func activateUnknownCaptureDeclinesWithoutActing() async throws {
        let fake = FakeScreenInteraction(canned: Self.capture())
        let (bridge, _) = makeBridge(fake)

        let reply = try await bridge.handle(.activate, args: [
            "capture_id": .string("never-captured"), "element_idx": .int(0),
        ])

        #expect(reply["activated"]?.boolValue == false)
        #expect(fake.activateCalls.isEmpty)
    }

    @Test func activateOutOfRangeDeclines() async throws {
        // An unresolvable reference (out-of-range index) is a benign decline, not
        // a hard error — matches the shared conformance vectors + Python/TS.
        let fake = FakeScreenInteraction(canned: Self.capture(elementCount: 1))
        let (bridge, _) = makeBridge(fake)
        _ = try await bridge.handle(.capture, args: ["capture_id": .string("cap1")])

        let reply = try await bridge.handle(.activate, args: [
            "capture_id": .string("cap1"), "element_idx": .int(5),
        ])
        #expect(reply["activated"]?.boolValue == false)
        #expect(fake.activateCalls.isEmpty)
    }

    @Test func activateMissingCaptureIdDeclines() async throws {
        let fake = FakeScreenInteraction(canned: Self.capture())
        let (bridge, _) = makeBridge(fake)
        let reply = try await bridge.handle(.activate, args: ["element_idx": .int(0)])
        #expect(reply["activated"]?.boolValue == false)
        #expect(fake.activateCalls.isEmpty)
    }

    @Test func activateDeclineMessagePropagates() async throws {
        let fake = FakeScreenInteraction(canned: Self.capture())
        fake.activateResult = ScreenActionOutcome(false, message: "foreground changed")
        let (bridge, _) = makeBridge(fake)
        _ = try await bridge.handle(.capture, args: ["capture_id": .string("cap1")])

        let reply = try await bridge.handle(.activate, args: [
            "capture_id": .string("cap1"), "element_idx": .int(0),
        ])

        #expect(reply["activated"]?.boolValue == false)
        #expect(reply["message"]?.stringValue == "foreground changed")
    }

    @Test func highlightResolvesAndForwardsArgs() async throws {
        let fake = FakeScreenInteraction(canned: Self.capture())
        let (bridge, _) = makeBridge(fake)
        _ = try await bridge.handle(.capture, args: ["capture_id": .string("cap1")])

        let reply = try await bridge.handle(.highlightElement, args: [
            "capture_id": .string("cap1"), "element_idx": .int(0),
            "label": .string("Tap here"), "placement": .string("bottom"),
            "interaction": .string("double_click"),
        ])

        #expect(reply["shown"]?.boolValue == true)
        #expect(reply["method"]?.stringValue == "grounded")
        let call = try #require(fake.highlightCalls.first)
        #expect(call.label == "Tap here")
        #expect(call.placement == .bottom)
        #expect(call.affordance == .doubleClick)
    }

    @Test func highlightRegionDrawsWithoutACapture() async throws {
        let fake = FakeScreenInteraction(canned: Self.capture())
        let (bridge, _) = makeBridge(fake)

        let reply = try await bridge.handle(.highlightRegion, args: [
            "x": .double(0.25), "y": .double(0.5),
            "width": .double(0.1), "height": .int(0),
            "label": .string("Click Save"), "placement": .string("top"),
            "interaction": .string("click"),
        ])

        #expect(reply["shown"]?.boolValue == true)
        #expect(reply["method"]?.stringValue == "direct")
        #expect(fake.captureCount == 0)
        let call = try #require(fake.highlightRegionCalls.first)
        #expect(call.region == ScreenRegion(x: 0.25, y: 0.5, width: 0.1, height: 0))
        #expect(call.label == "Click Save")
    }

    @Test func highlightRegionRejectsNonNumericCoordinates() async throws {
        let fake = FakeScreenInteraction(canned: Self.capture())
        let (bridge, _) = makeBridge(fake)

        await #expect(throws: ScreenInteractionError.self) {
            _ = try await bridge.handle(.highlightRegion, args: [
                "x": .double(0.25), "y": .string("halfway"),
                "width": .double(0.1), "height": .double(0.1),
                "label": .string("Click Save"),
            ])
        }
        #expect(fake.highlightRegionCalls.isEmpty)
    }
}
