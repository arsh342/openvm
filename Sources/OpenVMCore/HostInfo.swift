// HostInfo — what the host can give a VM, and what is ready, so a client offers only
// choices that will work.
import Foundation

public nonisolated struct HostInfo: Sendable, Equatable {
    public let maxCpus: Int
    public let maxMemoryMB: Int
    public let freeDiskMB: UInt64
    /// The helper VM's files have been fetched. The key keeps its first name, from when they were also
    /// what a Linux guest was built from.
    public let linuxReady: Bool
    /// The Mac has `wimlib-imagex`, which building Windows media prefers.
    public let hostWimlib: Bool

    public init(maxCpus: Int, maxMemoryMB: Int, freeDiskMB: UInt64, linuxReady: Bool, hostWimlib: Bool) {
        self.maxCpus = maxCpus
        self.maxMemoryMB = maxMemoryMB
        self.freeDiskMB = freeDiskMB
        self.linuxReady = linuxReady
        self.hostWimlib = hostWimlib
    }

    public init?(fields: [(key: String, value: CBOR)]) {
        func number(_ key: String) -> UInt64? {
            if case .uint(let n)? = fields.first(where: { $0.key == key })?.value { return n }
            return nil
        }
        func flag(_ key: String) -> Bool {
            if case .bool(let b)? = fields.first(where: { $0.key == key })?.value { return b }
            return false
        }
        guard let cpus = number("maxCpus"), let memory = number("maxMemoryMB") else { return nil }
        self.init(
            maxCpus: Int(cpus), maxMemoryMB: Int(memory), freeDiskMB: number("freeDiskMB") ?? 0,
            linuxReady: flag("linuxReady"), hostWimlib: flag("hostWimlib"))
    }
}

extension HostTransport {
    public func hostInfo() async throws -> HostInfo {
        guard let info = HostInfo(fields: try await send("host-info", [])) else {
            throw HostError.protocolFailure("the host's reply did not say what the Mac can give a VM")
        }
        return info
    }
}
