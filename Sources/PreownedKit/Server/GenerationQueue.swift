/// Runs one operation at a time, in the order that they arrive.
///
/// An actor alone does not serialize async work,
/// because it can run another call while one is suspended.
/// The queue keeps a busy flag and a list of waiting callers,
/// and hands the turn to the next caller when an operation ends.
///
/// The list of waiting callers has a limit,
/// because each waiter holds its request body in memory,
/// and an image can take minutes in the window modes.
/// A caller that finds the list full gets a 429 error
/// that tells OpenAI clients not to retry,
/// because their automatic retries come within seconds
/// and would find the queue still full.
public actor GenerationQueue {
    /// The default limit of waiting callers.
    public static let defaultMaximumWaiters = 8

    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let maximumWaiters: Int

    public init(maximumWaiters: Int = defaultMaximumWaiters) {
        self.maximumWaiters = maximumWaiters
    }

    /// Waits for the turn, then runs an operation.
    ///
    /// - Throws: A 429 ``OpenAIError`` if ``waitingCount`` is at the limit.
    public func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        if isBusy, waiters.count >= maximumWaiters {
            throw OpenAIError(
                status: .tooManyRequests,
                message: "\(maximumWaiters) image requests are already waiting. Try again when one finishes.",
                type: "rate_limit_error",
                code: "queue_full",
                shouldRetry: false
            )
        }
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
