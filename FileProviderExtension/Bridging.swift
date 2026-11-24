// Swift 6 bridging helpers for the FileProvider Objective-C callbacks.
//
// FileProvider hands us non-Sendable Objective-C completion blocks and
// observer objects. Work runs in a Task, so these values must cross into it:
// they are wrapped in @unchecked Sendable boxes. That is sound here because
// FileProvider documents its completion handlers and observers as callable
// from any thread, and `Once` serialises the single permitted call.

import Foundation

/// Runs a completion handler at most once, from whichever path gets there
/// first (normal completion, error, or Progress cancellation).
final class Once<Arguments>: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Arguments) -> Void)?

    init(_ handler: @escaping (Arguments) -> Void) {
        self.handler = handler
    }

    /// Calls the handler if it has not been called yet. Returns whether it ran.
    @discardableResult
    func callAsFunction(_ arguments: Arguments) -> Bool {
        lock.lock()
        let h = handler
        handler = nil
        lock.unlock()
        guard let h else { return false }
        h(arguments)
        return true
    }

    var hasFired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return handler == nil
    }
}

/// Carries a non-Sendable reference (observer, Progress, domain) into a Task.
struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Starts `operation` in a Task tied to `progress`: cancelling the progress
/// cancels the task and immediately reports `onCancel`, as the FileProvider
/// headers require ("the extension is then expected to quickly call the
/// completion handler").
func startTask(
    for progress: Progress,
    onCancel: @escaping @Sendable () -> Void,
    operation: @escaping @Sendable () async -> Void
) {
    let task = Task { await operation() }
    progress.cancellationHandler = {
        task.cancel()
        onCancel()
    }
    // A Progress cancelled before the handler was installed never calls it.
    if progress.isCancelled {
        task.cancel()
        onCancel()
    }
}
