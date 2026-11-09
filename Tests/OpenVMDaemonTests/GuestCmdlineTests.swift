// Tests for the kernel command line.
import Foundation
import OpenVMCore
import Testing

@testable import OpenVMHost

@Suite struct GuestCmdlineTests {
    @Test func netbootUsesThePinnedModloop() {
        let line = GuestBoot.effectiveCmdline(
            rootDevice: nil, installDisk: true, vmUUID: "u",
            artifactPort: 8124, modloopPinned: true)
        #expect(line.contains("modloop=http://192.168.64.1:8124/modloop-virt"))
        #expect(!line.contains("releases/aarch64/netboot/modloop-virt"))
    }

    @Test func withoutAPinnedCopyTheMirrorIsTheFallback() {
        let line = GuestBoot.effectiveCmdline(
            rootDevice: nil, installDisk: true, vmUUID: "u",
            artifactPort: 8124, modloopPinned: false)
        #expect(line.contains("modloop=\(GuestBoot.mirrorModloop)"))
    }

    /// An installed guest has its own modules; nothing serves it the modloop.
    @Test func persistentBootsAreUnchanged() {
        let line = GuestBoot.effectiveCmdline(
            rootDevice: "/dev/vda3", installDisk: false, vmUUID: "u",
            artifactPort: 8124, modloopPinned: true)
        #expect(!line.contains("192.168.64.1"))
    }
}

/// The install overlay is what makes a first boot install Alpine and start the agent. Without it
/// a guest comes up as stock Alpine, which has no installer and no agent (measured).
@Suite struct GuestOverlayCmdlineTests {
    private let served = "apkovl=http://192.168.64.1:8124/openvm.apkovl.tar.gz"

    @Test func installBootGetsTheServedOverlay() {
        let line = GuestBoot.effectiveCmdline(
            rootDevice: nil, installDisk: true, vmUUID: "u", artifactPort: 8124, environment: [:],
            payloadOverlay: true)
        #expect(line.contains(served))
    }

    @Test func noPayloadMeansNoOverlayArgument() {
        let line = GuestBoot.effectiveCmdline(
            rootDevice: nil, installDisk: true, vmUUID: "u", artifactPort: 8124, environment: [:],
            payloadOverlay: false)
        #expect(!line.contains("apkovl="))
    }

    /// The smoke serves its own overlay and sets this; it must keep working.
    @Test func envOverlayWins() {
        let line = GuestBoot.effectiveCmdline(
            rootDevice: nil, installDisk: true, vmUUID: "u", artifactPort: 8124,
            environment: ["OPENVM_APKOVL_URL": "http://example.test/o.tar.gz"], payloadOverlay: true)
        #expect(line.contains("apkovl=http://example.test/o.tar.gz"))
        #expect(!line.contains(served))
    }

    /// An installed guest has the agent on its own disk; it must not fetch an overlay again.
    @Test func persistentBootHasNoOverlay() {
        let line = GuestBoot.effectiveCmdline(
            rootDevice: "/dev/vda3", installDisk: false, vmUUID: "u", artifactPort: 8124, environment: [:],
            payloadOverlay: true)
        #expect(!line.contains("apkovl="))
    }
}

/// What a guest installed from its own ISO needs from the host: it boots without openVM's Linux files.
@Suite struct LinuxISOHostTests {
    @Test func onlyTheAlpinePathUsesNetboot() {
        func record(_ mode: BootMode?) -> VmRecord {
            let field = mode.map { ",\"bootMode\":\"\($0.rawValue)\"" } ?? ""
            let json = "{\"uuid\":\"u\",\"name\":\"n\",\"state\":\"stopped\",\"cpus\":1,\"memoryMB\":1024,\"createdAt\":\"t\"\(field)}"
            return try! JSONDecoder().decode(VmRecord.self, from: Data(json.utf8))
        }
        #expect(record(nil).usesNetboot)
        #expect(record(.linux).usesNetboot)
        #expect(!record(.windows).usesNetboot)
        #expect(!record(.linuxISO).usesNetboot)
    }

    private func iso(_ bytes: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("iso-\(UUID().uuidString).iso")
        try Data(bytes.utf8).write(to: url)
        return url
    }

    @Test func anArm64BootFileAnywhereMakesAnIsoUsable() throws {
        for name in ["BOOTAA64.EFI", "bootaa64.efi", "BOOTAA64EFI"] {
            let url = try iso(String(repeating: "x", count: 500) + name + String(repeating: "y", count: 500))
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(inspectLinuxISO(url) == .usable, "\(name)")
        }
    }

    @Test func anX86OnlyIsoIsSeen() throws {
        for name in ["BOOTX64.EFI", "bootx64.efi", "BOOTX64 EFI"] {
            let url = try iso("xxxx" + name + "yyyy")
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(inspectLinuxISO(url) == .x86Only, "\(name)")
        }
    }

    @Test func arm64WinsWhenAnIsoHasBothAndNothingIsUnknown() throws {
        let both = try iso("BOOTX64.EFI....BOOTAA64.EFI")
        let none = try iso("nothing of note")
        defer {
            try? FileManager.default.removeItem(at: both)
            try? FileManager.default.removeItem(at: none)
        }
        #expect(inspectLinuxISO(both) == .usable)
        #expect(inspectLinuxISO(none) == .unknown)
    }

    /// The name can fall across two reads, at every possible split.
    @Test func aNameSplitAcrossChunksIsStillFound() throws {
        for offset in 0..<16 {
            let url = try iso(String(repeating: "x", count: offset) + "BOOTAA64.EFI" + String(repeating: "y", count: 40))
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(inspectLinuxISO(url, chunk: 8) == .usable, "offset \(offset)")
        }
    }

    @Test func aMissingFileIsUnknownNotACrash() {
        #expect(inspectLinuxISO(URL(fileURLWithPath: "/nonexistent/x.iso")) == .unknown)
    }
}
