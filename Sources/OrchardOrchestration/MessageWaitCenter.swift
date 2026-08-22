import Foundation

public enum MessageWaitOutcome: Equatable, Sendable {
    case arrived(recipient: String, type: MessageType)
    case timedOut
}

/// The long-poll primitive behind `check --wait`: suspend until a matching message
/// arrives or the timeout lapses. The RPC layer (T2) calls `waitForMessage`, and the
/// store's `onMessageArrived` hook feeds `notifyMessageArrived`.
///
/// A wake-up is a hint, not a delivery: the woken caller re-reads the store (via
/// `getOrCreateRunDelivery`), so a spurious or raced wake costs one empty read, never a
/// lost message. That's also why a timeout is a checkpoint, not a failure
/// (docs/research/orca-inventory.md §1.5).
///
/// Lock-protected rather than an actor so the synchronous store commit path can notify
/// without hopping executors.
public final class MessageWaitCenter: @unchecked Sendable {
    private struct Waiter {
        let recipient: String?
        let types: Set<MessageType>?
        let continuation: CheckedContinuation<MessageWaitOutcome, Never>
    }

    private let lock = NSLock()
    private var waiters: [UUID: Waiter] = [:]

    public init() {}

    /// Suspend until a message for `recipient` (nil = any recipient) whose type is in
    /// `types` (nil = any type) arrives, or until `timeout` elapses.
    public func waitForMessage(
        recipient: String? = nil,
        types: Set<MessageType>? = nil,
        timeout: TimeInterval
    ) async -> MessageWaitOutcome {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            lock.lock()
            waiters[id] = Waiter(recipient: recipient, types: types, continuation: continuation)
            lock.unlock()
            // The timeout task simply loses the race when a notify already resumed the
            // waiter: `take(id)` returns nil and the sleep's result is discarded.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                self?.take(id)?.continuation.resume(returning: .timedOut)
            }
        }
    }

    /// Wake every waiter whose filters match this arrival. Callable from any thread,
    /// including the store's synchronous commit path.
    public func notifyMessageArrived(recipient: String, type: MessageType) {
        lock.lock()
        let matching = waiters.filter { _, waiter in
            (waiter.recipient == nil || waiter.recipient == recipient)
                && (waiter.types == nil || waiter.types?.contains(type) == true)
        }
        for key in matching.keys {
            waiters.removeValue(forKey: key)
        }
        lock.unlock()
        for waiter in matching.values {
            waiter.continuation.resume(returning: .arrived(recipient: recipient, type: type))
        }
    }

    /// Number of currently suspended waiters (test/diagnostic surface).
    public var waiterCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    private func take(_ id: UUID) -> Waiter? {
        lock.lock()
        defer { lock.unlock() }
        return waiters.removeValue(forKey: id)
    }
}
