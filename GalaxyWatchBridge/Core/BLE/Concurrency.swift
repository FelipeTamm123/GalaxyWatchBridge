import Foundation

/// Races `body` against a deadline.
///
/// CoreBluetooth has no timeouts of its own. `connect(_:options:)` in particular will wait
/// indefinitely — if the peripheral stopped advertising, neither `didConnect` nor
/// `didFailToConnect` is ever called and the awaiting task hangs forever. Every bridged
/// operation therefore goes through here.
///
/// - Important: whichever task loses is cancelled, so `body` must honour cancellation
///   (`withTaskCancellationHandler`) if it holds a continuation.
func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: String,
    body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw BLEError.timedOut(operation: operation)
        }

        // Returns the first task to finish, success or failure. A throw here propagates
        // and the group cancels the remaining child on scope exit.
        guard let result = try await group.next() else {
            throw BLEError.timedOut(operation: operation)
        }
        group.cancelAll()
        return result
    }
}

/// A continuation that can be resumed at most once.
///
/// Resuming a `CheckedContinuation` twice traps. That is easy to do accidentally with
/// CoreBluetooth, where a single logical operation can be terminated by several different
/// callbacks — a write can finish via `didWriteValueFor`, or be aborted by
/// `didDisconnectPeripheral`, or lose a timeout race. This box makes the second resume a
/// no-op instead of a crash.
///
/// - Important: not internally synchronised. `BLEManager` confines every instance to its
///   serial queue, which is what makes the unguarded `settled` flag safe.
final class PendingOperation<T> {
    private var continuation: CheckedContinuation<T, Error>?
    private var isSettled = false

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    var hasSettled: Bool { isSettled }

    func settle(_ result: Result<T, Error>) {
        guard !isSettled else { return }
        isSettled = true
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }

    func succeed(_ value: T) { settle(.success(value)) }
    func fail(_ error: Error) { settle(.failure(error)) }
}

extension PendingOperation where T == Void {
    func succeed() { settle(.success(())) }
}
