// HostInfoOp — what this Mac can give a VM, and what is ready, so a client can offer only
// choices that will work.
import Foundation
import OpenVMCore
import Virtualization

/// The most a VM may be given on this host.
nonisolated struct ResourceLimits: Equatable {
    let maxCpus: Int
    let maxMemoryMB: Int

    /// The most CPUs `create` and `set` accept, whatever the framework would allow.
    static let cpuCeiling = 32

    /// What Virtualization.framework says this Mac allows, within what the host accepts.
    static var current: ResourceLimits {
        ResourceLimits(
            maxCpus: min(cpuCeiling, Int(VZVirtualMachineConfiguration.maximumAllowedCPUCount)),
            maxMemoryMB: Int(VZVirtualMachineConfiguration.maximumAllowedMemorySize / (1 << 20)))
    }
}

/// Why a CPU or memory choice cannot be used, or nil when it can.
nonisolated func validateResources(cpus: Int?, memoryMB: Int?, limits: ResourceLimits) -> String? {
    if let cpus, cpus < 1 || cpus > limits.maxCpus {
        return "cpus must be between 1 and \(limits.maxCpus) on this Mac"
    }
    if let memoryMB, memoryMB < 128 || memoryMB > limits.maxMemoryMB {
        return "memoryMB must be between 128 and \(limits.maxMemoryMB) on this Mac"
    }
    return nil
}

/// The first executable file with this name in the given directories. A Mac app starts with a
/// minimal PATH, which leaves out Homebrew, so the places to look are passed in.
nonisolated func findExecutable(_ name: String, in directories: [String]) -> String? {
    for directory in directories {
        let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
            FileManager.default.isExecutableFile(atPath: path)
        {
            return path
        }
    }
    return nil
}

/// Turning Windows sound on enables Test Mode, which weakens driver signature checks. The
/// host refuses unless the client says it has the person's consent; turning it off needs none.
nonisolated func audioEnableRefusal(op: String, testMode: Bool?) -> String? {
    guard op == "enable", testMode != true else { return nil }
    return "enabling Windows sound turns on Test Mode, which weakens driver signature checks; send testMode: true"
}

/// Free space where the VMs live, in MiB. Walks up to the nearest directory that exists.
nonisolated func freeDiskMB(at url: URL) -> UInt64 {
    var directory = url
    while !FileManager.default.fileExists(atPath: directory.path), directory.path != "/" {
        directory = directory.deletingLastPathComponent()
    }
    let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return UInt64(max(0, values?.volumeAvailableCapacityForImportantUsage ?? 0)) >> 20
}

nonisolated func hostInfoOp(_ r: VmRequest) throws -> Envelope {
    let limits = ResourceLimits.current
    let wimlib = findExecutable(
        "wimlib-imagex",
        in: (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin"])
    return r.ok([
        ("maxCpus", .uint(UInt64(limits.maxCpus))),
        ("maxMemoryMB", .uint(UInt64(limits.maxMemoryMB))),
        ("freeDiskMB", .uint(freeDiskMB(at: home))),
        ("linuxReady", .bool(GuestBoot.supportArtifacts() != nil)),
        ("hostWimlib", .bool(wimlib != nil)),
    ])
}
