// A drop onto a VM window: checked before anything is copied, then followed to its end.
import Foundation
import OpenVMCore
import Testing

@testable import OpenVMApp

@MainActor
struct DropSessionTests {
    private func session(_ host: FakeTransport) -> DropSession {
        DropSession(uuid: "uuid-w", name: "w", transport: host, interval: .milliseconds(1))
    }

    nonisolated private static func statusReply(done: Bool, bytes: UInt64 = 0, placed: [String] = [], error: String? = nil)
        -> [(key: String, value: CBOR)]
    {
        var f: [(key: String, value: CBOR)] = [("done", .bool(done)), ("bytes", .uint(bytes))]
        f.append(("placed", .array(placed.map { .text($0) })))
        if let error { f.append(("error", .text(error))) }
        return f
    }

    /// The host answers `drop` at once and `status` from a script.
    private func script(_ host: FakeTransport, _ statuses: [[(key: String, value: CBOR)]]) {
        let counter = DropCounter()
        host.handle("drag") { args in
            let op = args.first(where: { $0.key == "op" })?.value
            if op == .text("status") {
                let n = counter.next()
                return statuses[min(n, statuses.count - 1)]
            }
            return []
        }
    }

    @Test func tooManyItemsFailsBeforeCopying() async {
        let host = FakeTransport()
        let drop = session(host)
        await drop.begin(paths: (0..<65).map { "/tmp/f\($0)" })
        #expect(drop.state == .failed("a drop takes at most 64 items"))
        #expect(host.calls.isEmpty)
    }

    @Test func duplicateNamesAreReported() async {
        let host = FakeTransport()
        let drop = session(host)
        await drop.begin(paths: ["/a/report.txt", "/b/report.txt"])
        guard case .failed(let why) = drop.state else { Issue.record("expected a failure"); return }
        #expect(why.contains("report.txt"))
        #expect(host.calls.isEmpty)
    }

    @Test func pollsUntilDone() async {
        let host = FakeTransport()
        script(
            host,
            [
                Self.statusReply(done: false, bytes: 10), Self.statusReply(done: false, bytes: 20),
                Self.statusReply(done: true, bytes: 30, placed: ["a.txt"]),
            ])
        let drop = session(host)
        await drop.begin(paths: ["/tmp/a.txt"])
        #expect(drop.state == .finished(["a.txt"]))
        #expect(host.values("drag", "op").filter { $0 == .text("status") }.count == 3)
        #expect(host.values("drag", "op").first == .text("drop"))
    }

    @Test func guestErrorIsShown() async {
        let host = FakeTransport()
        script(host, [Self.statusReply(done: true, error: "no space left")])
        let drop = session(host)
        await drop.begin(paths: ["/tmp/a.txt"])
        #expect(drop.state == .failed("no space left"))
    }

    @Test func aRefusedDropIsReportedWithTheHostsReason() async {
        let host = FakeTransport()
        host.fail("drag", with: HostError.remote("a drop is already running"))
        let drop = session(host)
        await drop.begin(paths: ["/tmp/a.txt"])
        #expect(drop.state == .failed("a drop is already running"))
    }

    @Test func secondDropIsRefusedWithReason() async {
        let host = FakeTransport()
        script(host, [Self.statusReply(done: false, bytes: 1)])  // never finishes
        let drop = session(host)
        let first = Task { await drop.begin(paths: ["/tmp/a.txt"]) }
        while drop.state == .idle { await Task.yield() }
        await drop.begin(paths: ["/tmp/b.txt"])
        #expect(drop.refusal?.contains("already") == true)
        #expect(host.values("drag", "op").filter { $0 == .text("drop") }.count == 1)
        first.cancel()
        await first.value
    }

    @Test func pollingStopsWhenTheVmStops() async {
        let host = FakeTransport()
        let counter = DropCounter()
        host.handle("drag") { args in
            if args.first(where: { $0.key == "op" })?.value == .text("status") {
                if counter.next() >= 2 { throw HostError.remote("w is not running") }
                return Self.statusReply(done: false, bytes: 5)
            }
            return []
        }
        let drop = session(host)
        await drop.begin(paths: ["/tmp/a.txt"])
        #expect(drop.state == .failed("w is not running"))
        let seen = host.calls.count
        try? await Task.sleep(for: .milliseconds(30))
        #expect(host.calls.count == seen)  // nothing polls a stopped VM
    }

    @Test func aFinishedDropCanBeDismissedAndAnotherStarted() async {
        let host = FakeTransport()
        script(host, [Self.statusReply(done: true, placed: ["a.txt"])])
        let drop = session(host)
        await drop.begin(paths: ["/tmp/a.txt"])
        drop.dismiss()
        #expect(drop.state == .idle)
        await drop.begin(paths: ["/tmp/b.txt"])
        #expect(host.values("drag", "op").filter { $0 == .text("drop") }.count == 2)
    }
}

private nonisolated final class DropCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { defer { n += 1 }; return n } }
}
