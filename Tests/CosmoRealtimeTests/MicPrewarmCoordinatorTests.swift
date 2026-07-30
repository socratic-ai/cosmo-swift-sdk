import Foundation
import Testing

@testable import CosmoRealtime

/// ``MicPrewarmCoordinator/settle()`` is what lets a caller about to open the
/// input device through another engine (the note-taker's passive tap) know the
/// queued VPIO transition has actually been applied, not merely queued.
///
/// The coordinator is process-global and other suites drive it concurrently
/// (every `VoiceSessionModel` teardown queues a release), so these tests only
/// assert on their own transitions — never on the exact applied sequence.
@Suite("MicPrewarmCoordinator", .serialized)
@MainActor
struct MicPrewarmCoordinatorTests {

    @MainActor
    private final class Recorder {
        private(set) var applied: [Bool] = []
        func record(_ enabled: Bool) { applied.append(enabled) }
    }

    @Test("settle suspends until the queued transition has applied")
    func settleSuspendsUntilApplied() async {
        let recorder = Recorder()
        let (gate, gateContinuation) = AsyncStream.makeStream(of: Void.self)
        let original = MicPrewarmCoordinator.transition
        defer { MicPrewarmCoordinator.transition = original }
        MicPrewarmCoordinator.transition = { enabled in
            var opened = gate.makeAsyncIterator()
            await opened.next()
            recorder.record(enabled)
        }

        MicPrewarmCoordinator.set(false)
        let appliedWhenSettled = Task { @MainActor in
            await MicPrewarmCoordinator.settle()
            return recorder.applied
        }
        gateContinuation.yield()

        #expect(await appliedWhenSettled.value.contains(false))
    }

    @Test("settle returns even when the transition throws")
    func settleSurvivesFailure() async {
        let original = MicPrewarmCoordinator.transition
        defer { MicPrewarmCoordinator.transition = original }
        MicPrewarmCoordinator.transition = { _ in
            throw CocoaError(.featureUnsupported)
        }

        MicPrewarmCoordinator.set(false)
        await MicPrewarmCoordinator.settle()
    }
}
