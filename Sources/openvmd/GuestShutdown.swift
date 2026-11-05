// How long a stop waits for a guest, and when it forces the VM off.
enum GuestShutdownError: Error, Equatable {
    case notStopped
}

@MainActor
enum GuestShutdown {
    /// What the agent said to a request to shut down.
    nonisolated enum AgentAnswer { case stopping, refused, none }

    /// How long a guest gets (50 ms polls) to stop by itself. Forcing it off is a
    /// power cut, so a guest whose agent started a shutdown gets real time. One
    /// that refused is alive and may be mid-way through something of its own, like
    /// Windows setup restarting itself. With no agent nothing is coming: the power
    /// button does not reach it.
    nonisolated static func gracePolls(_ answer: AgentAnswer) -> Int {
        switch answer {
        case .stopping: return 2400
        case .refused: return 600
        case .none: return 40
        }
    }

    static func stop(
        isStopped: @MainActor () -> Bool,
        requestStop: @MainActor () throws -> Void,
        forceStop: @MainActor () async throws -> Void,
        gracePolls: Int = 40,
        waitForNextPoll: @MainActor () async throws -> Void = {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    ) async throws {
        guard !isStopped() else { return }

        do {
            try requestStop()
            for _ in 0..<max(0, gracePolls) {
                if isStopped() { return }
                try await waitForNextPoll()
            }
        } catch {
            // A failed graceful request or wait must not bypass forced shutdown.
        }

        if !isStopped() {
            try await forceStop()
        }
        guard isStopped() else { throw GuestShutdownError.notStopped }
    }
}
