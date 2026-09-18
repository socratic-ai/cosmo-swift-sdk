import Foundation
import os

/// Raised when `_withConnectTimeout` hits its deadline. Internal callers
/// convert it to a ``SessionStartFailure`` before it reaches an SDK caller.
struct ConnectTimeoutReached: Error {}

/// Run `operation` with a hard `seconds` deadline, throwing
/// ``ConnectTimeoutReached`` if it doesn't settle in time.
///
/// Unstructured tasks + a one-shot ``CheckedContinuation`` (guarded by an
/// ``OSAllocatedUnfairLock``) rather than a task group, so a non-cancellable
/// operation doesn't keep the caller waiting past the deadline; a
/// `withThrowingTaskGroup` would block until every child settled on closure exit.
///
/// `onLateSettlement` runs ONCE, after the operation actually returns/throws, IF
/// the timeout already won (the caller has moved on) — letting the caller
/// schedule cleanup (e.g. `room.disconnect()`) against a settled state instead
/// of racing a still-in-flight non-cancellable operation.
func _withConnectTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T,
    onLateSettlement: @escaping @Sendable () async -> Void = {}
) async throws -> T {
    let resumed = OSAllocatedUnfairLock<Bool>(initialState: false)
    return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
        let opTask = Task<Void, Never> {
            let opResult: Result<T, Error>
            do {
                opResult = .success(try await operation())
            } catch {
                opResult = .failure(error)
            }
            let alreadyResumed = resumed.withLock { current -> Bool in
                let was = current
                current = true
                return was
            }
            if !alreadyResumed {
                switch opResult {
                case .success(let value): cont.resume(returning: value)
                case .failure(let e): cont.resume(throwing: e)
                }
            } else {
                // Timeout already won; caller has moved on. Run late-settlement
                // cleanup against the now-resolved operation state.
                await onLateSettlement()
            }
        }
        Task<Void, Never> {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            let alreadyResumed = resumed.withLock { current -> Bool in
                let was = current
                current = true
                return was
            }
            if !alreadyResumed {
                opTask.cancel()
                cont.resume(throwing: ConnectTimeoutReached())
            }
        }
    }
}
