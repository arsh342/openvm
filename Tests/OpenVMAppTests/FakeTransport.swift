// A stand-in for the host: scripted rows, recorded calls, and failures on demand.
import Foundation
import OpenVMCore

final class FakeTransport: HostTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _rows: [CBOR] = []
    private var _failure: Error?
    private var _calls: [String] = []

    var rows: [CBOR] {
        get { lock.withLock { _rows } }
        set { lock.withLock { _rows = newValue } }
    }
    /// Thrown by every call while set.
    var failure: Error? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }
    var calls: [String] { lock.withLock { _calls } }

    func send(_ op: String, _ args: [(key: String, value: CBOR)]) async throws -> [(key: String, value: CBOR)] {
        let (failure, rows) = lock.withLock { () -> (Error?, [CBOR]) in
            _calls.append(op)
            return (_failure, _rows)
        }
        if let failure { throw failure }
        return op == "list" ? [("vms", .array(rows))] : []
    }

    static func row(
        _ name: String, state: String = "stopped", activity: String? = nil, bootMode: String = "linux"
    ) -> CBOR {
        var fields: [(key: String, value: CBOR)] = [
            ("name", .text(name)), ("state", .text(state)), ("uuid", .text("uuid-\(name)")),
            ("cpus", .uint(4)), ("memoryMB", .uint(4096)), ("bootMode", .text(bootMode)),
        ]
        if let activity { fields.append(("activity", .text(activity))) }
        return .map(fields)
    }
}
