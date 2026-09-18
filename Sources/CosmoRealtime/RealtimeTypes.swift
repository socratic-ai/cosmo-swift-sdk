import Foundation

// MARK: - Cancellable

/// A handle returned by a listener registration (e.g.
/// ``RealtimeSession/onScreenShareFailed(_:)``). Call ``cancel()`` to
/// deregister the listener.
///
/// Listener removal is dispatched onto the transport's actor, so ``cancel()``
/// returns before the handler is guaranteed to stop firing. Callers that
/// must guarantee no further callbacks (e.g. tearing down captured state)
/// should use ``cancelAndWait()`` instead.
public struct Cancellable: Sendable {
    private let _cancel: @Sendable () -> Task<Void, Never>

    /// Construct from a synchronous cancellation closure. The closure runs
    /// fire-and-forget; ``cancelAndWait()`` will complete as soon as the
    /// closure returns.
    public init(_ cancel: @escaping @Sendable () -> Void) {
        self._cancel = { Task { cancel() } }
    }

    /// Construct from a closure that returns the actor-isolated removal
    /// task. Used internally by listener registrations so
    /// ``cancelAndWait()`` can await the dispatched removal.
    internal init(awaitable: @escaping @Sendable () -> Task<Void, Never>) {
        self._cancel = awaitable
    }

    /// Fire-and-forget deregistration. Returns immediately; the underlying
    /// removal may complete asynchronously on the client actor.
    public func cancel() { _ = _cancel() }

    /// Deregister and await completion of any actor-isolated removal
    /// work. Use when you need to guarantee no further callbacks fire
    /// before releasing captured state.
    public func cancelAndWait() async { await _cancel().value }
}

// MARK: - Errors

/// Base for every error this SDK throws, so `catch let error as RealtimeError`
/// catches them as one family and can read `message` off any of them. Mirrors
/// Python's `cosmo_ai.RealtimeError` and TypeScript's `RealtimeError`.
///
/// A catch target, not a conformance point: the SDK's own errors adopt it and
/// nothing outside needs to. Conforming your own type would make it catchable
/// as an error this SDK threw, which is the opposite of what the family is
/// for, and leaves it to be updated when a requirement is added.
public protocol RealtimeError: Error {
    /// Human-readable explanation, for logs and display. Written for a person
    /// and free to change between releases — branch on the `code` the thrown
    /// error carries, never on this.
    var message: String { get }
}
