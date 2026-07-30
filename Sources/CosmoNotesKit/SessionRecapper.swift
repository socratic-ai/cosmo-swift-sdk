import CosmoRealtime
import Foundation
import os

/// Thin orchestration over the recap request. Rather than asking the model for a
/// rigid text block and hand-parsing it (voice models comply with strict text
/// formats poorly), it instructs the model to call the `submit_recap` client
/// tool and awaits the structured ``Recap`` that handler produces. Transport is
/// kept behind the `send` closure and the `recaps` sequence so this stays
/// testable; the app feeds `recaps` from `NoteToolPack`'s `onSubmitRecap`.
public enum SessionRecapper {
    private struct RecapTimeout: Error {}

    private static let log = Logger(subsystem: CosmoRealtimeLog.subsystem, category: "notes-recap")

    /// The instruction sent to the model to request a recap. It must call the
    /// `submit_recap` tool with structured data rather than printing the recap.
    public static let recapPrompt = """
        The session is wrapping up. Call the submit_recap tool to record a recap: \
        pass a short 3-6 word title, a concise summary (one or two sentences), the \
        key points discussed as short bullet strings, and any action items the user \
        should follow up on. Do not print the recap as text — return it only through \
        the submit_recap tool call.
        """

    /// Send the recap prompt and return the first ``Recap`` yielded on `recaps`,
    /// or `nil` (best-effort) if sending fails, the stream ends without a recap,
    /// or none arrives within `timeout`.
    ///
    /// Wiring contract: pass a **fresh, session-scoped** `recaps` sequence per
    /// call, fed by this session's `NoteToolPack.onSubmitRecap`. It must buffer
    /// (a default `AsyncStream` does) so a `submit_recap` that fires before
    /// iteration begins isn't dropped. Reusing one long-lived stream across
    /// sessions can deliver a stale or late recap to the wrong session.
    public static func request<Recaps: AsyncSequence & Sendable>(
        send: @Sendable (String) async throws -> Void,
        recaps: Recaps,
        timeout: Duration = .seconds(20)
    ) async -> Recap? where Recaps.Element == Recap {
        do {
            try await send(recapPrompt)
        } catch {
            log.error("recap prompt send failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        return await withThrowingTaskGroup(of: Recap?.self) { group -> Recap? in
            group.addTask {
                // `try?` flattens `Element?`, so a thrown error or end-of-sequence
                // both yield nil; the first element is the recap.
                var iterator = recaps.makeAsyncIterator()
                return (try? await iterator.next()) ?? nil
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw RecapTimeout()
            }
            // Whichever arm finishes first wins; cancel the other so the loser
            // (a pending sleep or a stalled consume) is torn down cleanly.
            defer { group.cancelAll() }
            return (try? await group.next()) ?? nil
        }
    }
}
