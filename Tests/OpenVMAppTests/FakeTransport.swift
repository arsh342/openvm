// A stand-in for the host: scripted rows and replies, recorded requests, and failures on demand.
import Foundation
import OpenVMCore

nonisolated final class FakeTransport: HostTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _rows: [CBOR] = []
    private var _failure: Error?
    private var _requests: [(op: String, args: [(key: String, value: CBOR)])] = []
    private var _responses: [String: [(key: String, value: CBOR)]] = [:]
    private var _failures: [String: Error] = [:]
    private var _handlers: [String: Handler] = [:]
    private var _counters: [String: Int] = [:]

    typealias Handler = @Sendable ([(key: String, value: CBOR)]) async throws -> [(key: String, value: CBOR)]

    var rows: [CBOR] {
        get { lock.withLock { _rows } }
        set { lock.withLock { _rows = newValue } }
    }
    /// Thrown by every call while set.
    var failure: Error? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }
    /// What each op answers with (`list` is answered from `rows`).
    func respond(_ op: String, with fields: [(key: String, value: CBOR)]) {
        lock.withLock { _responses[op] = fields }
    }
    /// Runs code for an op, which may wait: how a test makes `start` block until `stop` arrives.
    func handle(_ op: String, _ handler: @escaping Handler) { lock.withLock { _handlers[op] = handler } }

    /// Answers an op with each response in turn, then the last one for ever (a task being polled).
    func respond(_ op: String, inSequence responses: [[(key: String, value: CBOR)]]) {
        handle(op) { [weak self] _ in
            guard let self else { return [] }
            let n = self.lock.withLock { () -> Int in
                let n = self._counters[op, default: 0]
                self._counters[op] = n + 1
                return n
            }
            return responses[min(n, responses.count - 1)]
        }
    }

    /// Makes one op fail, and the others not.
    func fail(_ op: String, with error: Error) { lock.withLock { _failures[op] = error } }

    var calls: [String] { lock.withLock { _requests.map(\.op) } }
    var requests: [(op: String, args: [(key: String, value: CBOR)])] { lock.withLock { _requests } }

    /// Every value a key carried across all requests of one op, in order. `audio` is used for
    /// status, enable and disable alike, so tests ask which operations were sent.
    func values(_ op: String, _ key: String) -> [CBOR] {
        requests.filter { $0.op == op }.compactMap { $0.args.first(where: { $0.key == key })?.value }
    }

    /// The argument the last request of an op carried, for assertions.
    func arg(_ op: String, _ key: String) -> CBOR? {
        requests.last(where: { $0.op == op })?.args.first(where: { $0.key == key })?.value
    }

    func send(_ op: String, _ args: [(key: String, value: CBOR)]) async throws -> [(key: String, value: CBOR)] {
        let (failure, rows, response, handler) = lock.withLock {
            () -> (Error?, [CBOR], [(key: String, value: CBOR)]?, Handler?) in
            _requests.append((op, args))
            return (_failures[op] ?? _failure, _rows, _responses[op], _handlers[op])
        }
        if let failure { throw failure }
        if let handler { return try await handler(args) }
        if let response { return response }
        return op == "list" ? [("vms", .array(rows))] : []
    }

    static func row(
        _ name: String, state: String = "stopped", activity: String? = nil, bootMode: String = "linux",
        cpus: UInt64 = 4, memoryMB: UInt64 = 4096, timezone: String? = nil, clipboardSync: Bool? = nil
    ) -> CBOR {
        var fields: [(key: String, value: CBOR)] = [
            ("name", .text(name)), ("state", .text(state)), ("uuid", .text("uuid-\(name)")),
            ("cpus", .uint(cpus)), ("memoryMB", .uint(memoryMB)), ("bootMode", .text(bootMode)),
        ]
        if let activity { fields.append(("activity", .text(activity))) }
        if let timezone { fields.append(("timezone", .text(timezone))) }
        if let clipboardSync { fields.append(("clipboardSync", .bool(clipboardSync))) }
        return .map(fields)
    }

    static func summary(_ name: String = "w", state: String = "stopped", bootMode: String = "linux", cpus: UInt64 = 4, memoryMB: UInt64 = 4096, timezone: String? = nil, clipboardSync: Bool? = nil) -> VmSummary {
        VmSummary(row: row(name, state: state, bootMode: bootMode, cpus: cpus, memoryMB: memoryMB, timezone: timezone, clipboardSync: clipboardSync))!
    }

    /// What `host-info` answers on a Mac with 8 CPUs and 16 GiB.
    static let hostInfoFields: [(key: String, value: CBOR)] = [
        ("maxCpus", .uint(8)), ("maxMemoryMB", .uint(16384)), ("freeDiskMB", .uint(500_000)),
        ("linuxReady", .bool(true)), ("hostWimlib", .bool(false)),
    ]
}
