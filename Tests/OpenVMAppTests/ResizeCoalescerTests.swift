// Live resize fires many sizes a second. The guest should get the last one, one at a time.
import Foundation
import OpenVMCore
import Testing

@testable import OpenVMApp

/// A timer the test releases by hand, so no test depends on real time.
actor TimerGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var pending: Int { waiters.count }
    func wait() async { await withCheckedContinuation { waiters.append($0) } }
    func releaseAll() {
        let all = waiters
        waiters = []
        all.forEach { $0.resume() }
    }
}

actor Recorder {
    private(set) var applied: [DisplayFit.Mode] = []
    private(set) var running = 0
    private(set) var maxRunning = 0
    private let hold: TimerGate?
    init(hold: TimerGate? = nil) { self.hold = hold }
    func apply(_ mode: DisplayFit.Mode) async -> Bool {
        running += 1
        maxRunning = max(maxRunning, running)
        await hold?.wait()
        applied.append(mode)
        running -= 1
        return true
    }
}

func eventually(_ what: String = "", _ condition: @escaping () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

struct ResizeCoalescerTests {
    private func mode(_ w: UInt64, _ h: UInt64 = 600, _ s: UInt64 = 1) -> DisplayFit.Mode {
        DisplayFit.Mode(width: w, height: h, scale: s)
    }

    @Test func onlyTheLatestSizeIsApplied() async {
        let timers = TimerGate()
        let recorder = Recorder()
        let coalescer = ResizeCoalescer(sleep: { await timers.wait() }, apply: { await recorder.apply($0) })
        await coalescer.request(mode(800))
        await coalescer.request(mode(900))
        await coalescer.request(mode(1000))
        #expect(await eventually { await timers.pending == 3 })
        await timers.releaseAll()
        #expect(await eventually { await recorder.applied.count == 1 })
        #expect(await recorder.applied == [mode(1000)])
    }

    @Test func oneApplyAtATime() async {
        let timers = TimerGate()
        let hold = TimerGate()
        let recorder = Recorder(hold: hold)
        let coalescer = ResizeCoalescer(sleep: { await timers.wait() }, apply: { await recorder.apply($0) })
        await coalescer.request(mode(800))
        #expect(await eventually { await timers.pending == 1 })
        await timers.releaseAll()
        #expect(await eventually { await recorder.running == 1 })  // the first apply is in flight
        await coalescer.request(mode(900))  // a new size arrives mid-apply
        #expect(await eventually { await timers.pending == 1 })
        await timers.releaseAll()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await recorder.maxRunning == 1)  // the second waits for the first
        await hold.releaseAll()  // the first apply finishes
        #expect(await eventually { await timers.pending == 1 })  // the waiting size is scheduled again
        await timers.releaseAll()
        #expect(await eventually { await recorder.running == 1 })
        await hold.releaseAll()  // the second apply finishes
        #expect(await eventually { await recorder.applied.count == 2 })
        #expect(await recorder.applied == [mode(800), mode(900)])
        #expect(await recorder.maxRunning == 1)
    }

    @Test func aSizeAlreadyAppliedIsNotSentAgain() async {
        let timers = TimerGate()
        let recorder = Recorder()
        let coalescer = ResizeCoalescer(sleep: { await timers.wait() }, apply: { await recorder.apply($0) })
        await coalescer.request(mode(800))
        #expect(await eventually { await timers.pending == 1 })
        await timers.releaseAll()
        #expect(await eventually { await recorder.applied.count == 1 })
        await coalescer.request(mode(800))  // the same size again: a backing-scale notification, say
        #expect(await eventually { await timers.pending == 1 })
        await timers.releaseAll()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await recorder.applied.count == 1)
    }

    @Test func forgetLetsTheSameSizeBeAppliedAgain() async {
        // After a resume or a restart the guest may have lost the mode.
        let timers = TimerGate()
        let recorder = Recorder()
        let coalescer = ResizeCoalescer(sleep: { await timers.wait() }, apply: { await recorder.apply($0) })
        await coalescer.request(mode(800))
        #expect(await eventually { await timers.pending == 1 })
        await timers.releaseAll()
        #expect(await eventually { await recorder.applied.count == 1 })
        await coalescer.forget()
        await coalescer.request(mode(800))
        #expect(await eventually { await timers.pending == 1 })
        await timers.releaseAll()
        #expect(await eventually { await recorder.applied.count == 2 })
    }
}
