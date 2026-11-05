// ResizeCoalescer — live resize reports a size many times a second; the guest should
// get the last one, once the window has settled, and never two at the same time.
//
// A guest can refuse a mode it will accept a moment later: a freshly booted guest's
// agent answers before its desktop session exists. A refused mode is tried again, with a
// growing wait, until it is taken, a newer size arrives, or the waits run out.
import Foundation
import OpenVMCore

actor ResizeCoalescer {
    typealias Mode = DisplayFit.Mode

    private let delay: Duration
    private let retryDelays: [Duration]
    private let sleep: @Sendable (Duration) async -> Void
    private let apply: @Sendable (Mode) async -> Bool
    private var pending: Mode?
    private var applied: Mode?
    private var inFlight = false
    /// How many retries the current size has used.
    private var retries = 0
    /// Every request supersedes the timers before it, so no timer needs cancelling.
    private var generation = 0

    /// `delay` is how long to wait after the last change. `sleep` waits for a duration; a
    /// test supplies its own. `apply` says whether the guest took the mode.
    init(
        delay: Duration = .milliseconds(250),
        sleep: (@Sendable (Duration) async -> Void)? = nil,
        retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(30)],
        apply: @escaping @Sendable (Mode) async -> Bool
    ) {
        self.delay = delay
        self.retryDelays = retryDelays
        self.sleep = sleep ?? { try? await Task.sleep(for: $0) }
        self.apply = apply
    }

    func request(_ mode: Mode) {
        pending = mode
        retries = 0  // a new size starts afresh
        schedule(after: delay)
    }

    /// The guest may have lost its mode (a resume, a restart): the next request is sent
    /// even if it equals the last one.
    func forget() { applied = nil }

    private func schedule(after wait: Duration) {
        generation += 1
        let mine = generation
        let pause = sleep
        Task { [self] in
            await pause(wait)
            await fire(mine)
        }
    }

    private func fire(_ token: Int) async {
        guard token == generation, !inFlight, let mode = pending else { return }
        pending = nil
        guard mode != applied else { return }
        inFlight = true
        let taken = await apply(mode)
        inFlight = false
        if taken {
            applied = mode
            retries = 0
        }
        if pending != nil {
            // A size arrived while the guest was busy: it goes next.
            schedule(after: delay)
        } else if !taken, retries < retryDelays.count {
            // Refused, and nothing newer is waiting: try this one again, later.
            pending = mode
            schedule(after: retryDelays[retries])
            retries += 1
        }
    }
}
