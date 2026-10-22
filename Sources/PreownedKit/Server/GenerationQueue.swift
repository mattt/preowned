/// Runs one operation at a time, in the order that they arrive.
///
/// An actor alone does not serialize async work,
/// because it can run another call while one is suspended.
/// The queue keeps a busy flag and a list of waiting callers,
/// and hands the turn to the next caller when an operation ends.
public actor GenerationQueue {
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// Waits for the turn, then runs an operation.
    public func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    /// The number of callers that wait for a turn.
    public var waitingCount: Int {
        waiters.count
    }

    private func acquire() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            // The queue stays busy and passes the turn directly to the next caller.
            waiters.removeFirst().resume()
        }
    }
}
