// DaemonClient — the CLI's names for the shared client in OpenVMCore.
import Foundation
import OpenVMCore

typealias CLIError = HostError

let home = OVMPaths.home
let sockPath = OVMPaths.socket

func daemonRequest(_ op: String, args: [(key: String, value: CBOR)]) throws -> Envelope {
    try DaemonClient(socket: sockPath).request(op, args: args)
}

func resultFields(_ reply: Envelope) throws -> [(key: String, value: CBOR)] {
    try DaemonClient.resultFields(reply)
}

func field(_ fields: [(key: String, value: CBOR)], _ key: String) -> CBOR? {
    DaemonClient.field(fields, key)
}
