// ResizeCoalescer — live resize reports a size many times a second; the guest should
// get the last one, once the window has settled, and never two at the same time.
import Foundation
import OpenVMCore

actor ResizeCoalescer {
    typealias Mode = DisplayFit.Mode

    private let sleep: @Sendable () async -> Void
    private let apply: @Sendable (Mode) async -> Bool
    private var pending: Mode?
    private var applied: Mode?
    private var inFlight = false
    /// Every request supersedes the timers before it, so no timer needs cancelling.
    private var generation = 0

    /// `sleep` is how long to wait after the last change; a test supplies its own.
    /// `apply` says whether the guest took the mode: a mode that failed is tried again.
    init(
        delay: Duration = .milliseconds(250), sleep: (@Sendable () async -> Void)? = nil,
        apply: @escaping @Sendable (Mode) async -> Bool
    ) {
        self.sleep = sleep ?? { try? await Task.sleep(for: delay) }
        self.apply = apply
    }

    func request(_ mode: Mode) {
        pending = mode
        schedule()
    }

    /// The guest may have lost its mode (a resume, a restart): the next request is sent
    /// even if it equals the last one.
    func forget() { applied = nil }

    private func schedule() {
        generation += 1
        let mine = generation
        let wait = sleep
        Task { [self] in
            await wait()
            await fire(mine)
        }
    }

    private func fire(_ token: Int) async {
        guard token == generation, !inFlight, let mode = pending else { return }
        pending = nil
        guard mode != applied else { return }
        inFlight = true
        if await apply(mode) { applied = mode }
        inFlight = false
        // A size arrived while the guest was busy: it goes next.
        if pending != nil { schedule() }
    }
}
