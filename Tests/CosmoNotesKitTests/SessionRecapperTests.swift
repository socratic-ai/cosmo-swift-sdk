import Foundation
import Testing

@testable import CosmoNotesKit

@Suite struct SessionRecapperTests {
    @Test func sendsPromptAndReturnsFirstRecap() async {
        let sent = Sent()
        let expected = Recap(
            summary: "From the stream.",
            keyPoints: ["a", "b"],
            actionItems: [ActionItem(text: "do it")]
        )
        let stream = AsyncStream<Recap> { continuation in
            continuation.yield(expected)
            continuation.yield(Recap(summary: "later, ignored"))
            continuation.finish()
        }

        let recap = await SessionRecapper.request(
            send: { await sent.set($0) },
            recaps: stream
        )
        #expect(recap == expected)
        #expect(await sent.value == SessionRecapper.recapPrompt)
    }

    @Test func timesOutToNilWhenNoRecapArrives() async {
        // A stream that never yields and never finishes; the timeout arm must
        // win and return nil rather than hang.
        let stream = AsyncStream<Recap> { _ in /* never yields, never finishes */ }
        let recap = await SessionRecapper.request(
            send: { _ in },
            recaps: stream,
            timeout: .milliseconds(50)
        )
        #expect(recap == nil)
    }

    @Test func returnsNilWhenStreamEndsWithoutRecap() async {
        let stream = AsyncStream<Recap> { $0.finish() }
        let recap = await SessionRecapper.request(
            send: { _ in },
            recaps: stream
        )
        #expect(recap == nil)
    }

    @Test func returnsNilWhenSendFails() async {
        struct SendError: Error {}
        let stream = AsyncStream<Recap> { $0.yield(Recap(summary: "never read")); $0.finish() }
        let recap = await SessionRecapper.request(
            send: { _ in throw SendError() },
            recaps: stream
        )
        #expect(recap == nil)
    }

    private actor Sent {
        private(set) var value: String?
        func set(_ v: String) { value = v }
    }
}
