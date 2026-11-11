// What the host tells a client about itself, and what it refuses to be asked for.
import Foundation
import OpenVMCore
import Testing

@testable import OpenVMHost

struct HostInfoTests {
    @Test func hostInfoReportsLimits() throws {
        let reply = vmOp("host-info", [], Envelope(type: .vmRequest, correlationId: 3))
        guard case .map(let body) = reply.body,
            case .map(let result)? = body.first(where: { $0.key == "result" })?.value
        else {
            Issue.record("reply was not a map")
            return
        }
        func uint(_ key: String) -> UInt64? {
            if case .uint(let n)? = result.first(where: { $0.key == key })?.value { return n }
            return nil
        }
        func flag(_ key: String) -> Bool? {
            if case .bool(let b)? = result.first(where: { $0.key == key })?.value { return b }
            return nil
        }
        #expect((uint("maxCpus") ?? 0) >= 1)
        // What it reports is what `set` accepts: the host rejects more than 32 CPUs.
        #expect((uint("maxCpus") ?? 0) <= 32)
        #expect((uint("maxMemoryMB") ?? 0) >= 1024)
        #expect(uint("freeDiskMB") != nil)
        #expect(flag("linuxReady") != nil)
        #expect(flag("hostWimlib") != nil)
    }

    @Test func valuesAboveHostLimitsAreRefused() {
        let limits = ResourceLimits(maxCpus: 8, maxMemoryMB: 16384)
        #expect(validateResources(cpus: 4, memoryMB: 8192, limits: limits) == nil)
        #expect(validateResources(cpus: nil, memoryMB: nil, limits: limits) == nil)
        #expect(validateResources(cpus: 9, memoryMB: nil, limits: limits)?.contains("8") == true)
        #expect(validateResources(cpus: 0, memoryMB: nil, limits: limits) != nil)
        #expect(validateResources(cpus: nil, memoryMB: 32768, limits: limits)?.contains("16384") == true)
        #expect(validateResources(cpus: nil, memoryMB: 64, limits: limits) != nil)
    }

    @Test func findExecutableFindsOnlyExecutableFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("exec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = dir.appendingPathComponent("tool")
        let plain = dir.appendingPathComponent("plain")
        try "#!/bin/sh\n".write(to: tool, atomically: true, encoding: .utf8)
        try "data".write(to: plain, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plain.path)
        #expect(findExecutable("tool", in: [dir.path]) == tool.path)
        #expect(findExecutable("plain", in: [dir.path]) == nil)  // present but not executable
        #expect(findExecutable("missing", in: [dir.path]) == nil)
        #expect(findExecutable("tool", in: ["/no/such/dir", dir.path]) == tool.path)
    }

    /// Windows sound needs Test Mode, which weakens driver signing. The host will not turn it on
    /// for a client that has not said so, whichever client that is.
    @Test func enablingWindowsSoundNeedsExplicitConsent() {
        #expect(audioEnableRefusal(op: "enable", testMode: nil) != nil)
        #expect(audioEnableRefusal(op: "enable", testMode: false) != nil)
        #expect(audioEnableRefusal(op: "enable", testMode: true) == nil)
        #expect(audioEnableRefusal(op: "status", testMode: nil) == nil)
        #expect(audioEnableRefusal(op: "disable", testMode: nil) == nil)  // turning it off needs no consent
    }
}

extension HostInfoTests {
    /// Whatever the VM's state, a client that has not agreed to Test Mode is told so.
    @Test func consentIsCheckedBeforeTheGuestIsLookedUp() {
        let reply = vmOp(
            "audio", [("id", .text("no-such-vm")), ("op", .text("enable"))],
            Envelope(type: .vmRequest, correlationId: 8))
        guard case .map(let body) = reply.body,
            case .map(let result)? = body.first(where: { $0.key == "result" })?.value,
            case .text(let message)? = result.first(where: { $0.key == "message" })?.value
        else {
            Issue.record("reply was not a map")
            return
        }
        #expect(message.contains("Test Mode"))  // not "not found"
    }
}

/// openVM no longer makes its own Alpine guests: a VM is Windows, or a Linux from its own ISO.
/// These refusals come before the host touches its registry or makes a disk.
struct CreateModeTests {
    private func refusal(_ args: [(key: String, value: CBOR)]) -> String? {
        let reply = vmOp("create", args, Envelope(type: .vmRequest, correlationId: 9))
        guard case .map(let body) = reply.body,
            case .text("error")? = body.first(where: { $0.key == "status" })?.value,
            case .map(let result)? = body.first(where: { $0.key == "result" })?.value,
            case .text(let message)? = result.first(where: { $0.key == "message" })?.value
        else { return nil }
        return message
    }

    @Test func createMustSayWhichSystem() {
        #expect(refusal([("name", .text("no-mode-given"))]) == "create needs --boot-mode windows or linux-iso")
    }

    @Test func anAlpineGuestIsRefusedWithWhatToDoInstead() {
        let message = refusal([("name", .text("old-style")), ("boot-mode", .text("linux"))])
        #expect(message?.contains("no longer makes Alpine guests") == true)
        #expect(message?.contains("linux-iso") == true)
    }

    @Test func anUnknownModeIsRefused() {
        #expect(refusal([("name", .text("odd")), ("boot-mode", .text("bsd"))]) == "boot-mode must be windows or linux-iso")
    }
}
