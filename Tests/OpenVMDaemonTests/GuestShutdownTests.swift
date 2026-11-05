// Tests for the stop policy.
import Testing

@testable import openvmd

@MainActor
@Suite struct GuestShutdownTests {
    private enum StopError: Error, Equatable {
        case graceful
        case forced
    }

    @Test func alreadyStoppedDoesNotRequestShutdown() async throws {
        try await GuestShutdown.stop(
            isStopped: { true },
            requestStop: { Issue.record("Requested shutdown of a stopped guest") },
            forceStop: { Issue.record("Forced shutdown of a stopped guest") },
            gracePolls: 0)
    }

    @Test func gracefulCompletionAvoidsForcedStop() async throws {
        var stopped = false
        var requested = false
        var polls = 0
        try await GuestShutdown.stop(
            isStopped: { stopped },
            requestStop: { requested = true },
            forceStop: { Issue.record("Forced shutdown after graceful completion") },
            gracePolls: 1,
            waitForNextPoll: {
                polls += 1
                stopped = true
            })
        #expect(requested)
        #expect(polls == 1)
        #expect(stopped)
    }

    @Test func graceExpiryForcesStop() async throws {
        var stopped = false
        var requested = false
        var polls = 0
        try await GuestShutdown.stop(
            isStopped: { stopped },
            requestStop: { requested = true },
            forceStop: {
                #expect(requested)
                #expect(polls == 2)
                stopped = true
            },
            gracePolls: 2,
            waitForNextPoll: { polls += 1 })
        #expect(stopped)
    }

    @Test func gracefulRequestFailureStillForcesStop() async throws {
        var stopped = false
        try await GuestShutdown.stop(
            isStopped: { stopped },
            requestStop: { throw StopError.graceful },
            forceStop: { stopped = true },
            gracePolls: 1,
            waitForNextPoll: { Issue.record("Waited after graceful request failed") })
        #expect(stopped)
    }

    @Test func forcedStopFailurePropagates() async {
        await #expect(throws: StopError.forced) {
            try await GuestShutdown.stop(
                isStopped: { false },
                requestStop: { throw StopError.graceful },
                forceStop: { throw StopError.forced },
                gracePolls: 0)
        }
    }

    @Test func forcedStopMustConfirmStoppedState() async {
        var forced = false
        await #expect(throws: GuestShutdownError.notStopped) {
            try await GuestShutdown.stop(
                isStopped: { false },
                requestStop: {},
                forceStop: { forced = true },
                gracePolls: 0)
        }
        #expect(forced)
    }
}
