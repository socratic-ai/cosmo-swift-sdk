import Foundation
import Testing
@testable import CosmoRealtime

extension ExternalTrace: CustomTestStringConvertible {
    var testDescription: String { name }
}

/// Executes every external-protocol contract trace against the stream
/// API (``RealtimeSession``) over an in-memory ``FakeSessionTransport``
/// — offline, no LiveKit. The legacy lifecycle traces under
/// ``contract/lifecycle-traces/`` have no Swift runner; they pin the
/// legacy first-party surface, which is retired separately.
@Suite("External contract traces")
struct ExternalContractTraceTests {

    static var allTraces: [ExternalTrace] {
        (try? ExternalTraceLoader.loadAll()) ?? []
    }

    /// Sentinel: a misconfigured fixture path or malformed trace must
    /// fail the suite loudly instead of silently parameterizing over
    /// zero cases.
    @Test("trace discovery yields every external trace")
    func discovery() throws {
        let traces = try ExternalTraceLoader.loadAll()
        #expect(traces.count >= 9, "expected the external traces under sdks/cosmo-realtime/contract/external-traces/")
    }

    @Test("trace", arguments: allTraces)
    func runTrace(_ trace: ExternalTrace) async throws {
        let transport = FakeSessionTransport()
        let session = RealtimeSession(transport: transport)

        let stateRecorder = TraceRecorder<String>()
        let statesStream = session.states
        let statesPipe = Task {
            for await state in statesStream {
                await stateRecorder.append(stateString(state))
            }
        }

        let eventRecorder = TraceRecorder<ObservedEvent>()
        let eventsFinished = CompletionFlag()
        let eventsSequence = session.events
        let eventsPipe = Task {
            do {
                for try await event in eventsSequence {
                    if let observed = observe(event) {
                        await eventRecorder.append(observed)
                    }
                }
            } catch {
                // A throwing finish is still a finished stream.
            }
            eventsFinished.set()
        }

        // MARK: Drive steps

        var thrown: RealtimeSessionError?
        var handshake: [ExternalTrace.Frame] = []
        var started = false

        for step in trace.steps {
            switch step {
            case .serverFrames(let frames):
                if started {
                    for frame in frames {
                        await transport.inject(frame.wireData)
                    }
                } else {
                    handshake.append(contentsOf: frames)
                }
            case .start(let config):
                if let rejection = scriptedRejection(fromHandshake: handshake) {
                    await transport.scriptRejection(rejection)
                    handshake = []
                }
                do {
                    try await session._start(config: try sessionConfig(fromTrace: config))
                    for frame in handshake {
                        await transport.inject(frame.wireData)
                    }
                } catch let error as RealtimeSessionError {
                    thrown = error
                }
                handshake = []
                started = true
            case .clientSend(let message):
                try await performClientSend(message, on: session)
            case .end:
                await session.end()
            }
        }

        // MARK: Settle

        if trace.expect?.streamFinished == true {
            await waitUntil(deadline: 2.0) { eventsFinished.isSet }
        } else {
            await eventRecorder.awaitAtLeast(trace.expectEvents?.count ?? 0)
        }
        await stateRecorder.awaitAtLeast(trace.expect?.states?.count ?? 0)

        let observedEvents = await eventRecorder.items
        let observedStates = await stateRecorder.items
        let sentFrames = await transport.sent.map(observeSentFrame)

        // MARK: Assert

        if let matchers = trace.expectEvents,
           let failure = subsequenceFailure(matchers: matchers, events: observedEvents, label: "expectEvents")
        {
            Issue.record("[\(trace.name)] \(failure)")
        }

        if let matchers = trace.expectSent,
           let failure = subsequenceFailure(matchers: matchers, events: sentFrames, label: "expectSent")
        {
            Issue.record("[\(trace.name)] \(failure)")
        }

        if let expect = trace.expect {
            if let expectedStates = expect.states {
                let prefix = Array(observedStates.prefix(expectedStates.count))
                if prefix != expectedStates {
                    Issue.record("[\(trace.name)] states: expected prefix \(expectedStates), got \(observedStates)")
                }
            }
            if let expectedFinished = expect.streamFinished {
                if expectedFinished, !eventsFinished.isSet {
                    Issue.record("[\(trace.name)] expected the event stream to finish, but it stayed open")
                }
                if !expectedFinished {
                    // Give any stray terminal close a beat to surface
                    // before pinning "still open".
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if eventsFinished.isSet {
                        Issue.record("[\(trace.name)] expected the event stream to stay open, but it finished")
                    }
                }
            }
            if let expectedThrown = expect.thrown {
                if let thrown {
                    if thrownName(thrown) != expectedThrown {
                        Issue.record("[\(trace.name)] thrown: expected \(expectedThrown), got \(thrownName(thrown))")
                    } else if let fragment = expect.thrownDetailContains {
                        let detail = thrownDetail(thrown) ?? ""
                        if !detail.contains(fragment) {
                            Issue.record("[\(trace.name)] thrownDetailContains: \(fragment) not in \(detail)")
                        }
                    }
                } else {
                    Issue.record("[\(trace.name)] expected thrown \(expectedThrown) but start did not throw")
                }
            } else if let thrown {
                Issue.record("[\(trace.name)] unexpected throw: \(thrown)")
            }
            if let expectedLast = expect.lastEventType {
                let last = observedEvents.last?.type
                if last != expectedLast {
                    Issue.record("[\(trace.name)] lastEventType: expected \(expectedLast), got \(last ?? "<none>")")
                }
            }
        }

        eventsPipe.cancel()
        statesPipe.cancel()
    }
}
