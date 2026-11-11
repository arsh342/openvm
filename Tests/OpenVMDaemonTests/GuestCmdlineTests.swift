// Tests for the kernel command line.
import Foundation
import OpenVMCore
import Testing

@testable import OpenVMHost

/// The helper VM is the only netboot left: Alpine from RAM, with the overlay that carries its job.
@Suite struct NetbootCmdlineTests {
    private let served = "apkovl=http://192.168.64.1:8124/openvm.apkovl.tar.gz"

    @Test func netbootUsesThePinnedModloop() {
        let line = GuestBoot.netbootCmdline(artifactPort: 8124, modloopPinned: true, environment: [:])
        #expect(line.contains("modloop=http://192.168.64.1:8124/modloop-virt"))
        #expect(!line.contains("releases/aarch64/netboot/modloop-virt"))
    }

    @Test func withoutAPinnedCopyTheMirrorIsTheFallback() {
        let line = GuestBoot.netbootCmdline(artifactPort: 8124, modloopPinned: false, environment: [:])
        #expect(line.contains("modloop=\(GuestBoot.mirrorModloop)"))
    }

    @Test func thePayloadOverlayIsServedByTheHost() {
        let line = GuestBoot.netbootCmdline(artifactPort: 8124, environment: [:], payloadOverlay: true)
        #expect(line.contains(served))
    }

    @Test func noPayloadMeansNoOverlayArgument() {
        let line = GuestBoot.netbootCmdline(artifactPort: 8124, environment: [:], payloadOverlay: false)
        #expect(!line.contains("apkovl="))
    }

    /// A test serves its own overlay and sets this; it must keep working.
    @Test func envOverlayWins() {
        let line = GuestBoot.netbootCmdline(
            artifactPort: 8124, environment: ["OPENVM_APKOVL_URL": "http://example.test/o.tar.gz"],
            payloadOverlay: true)
        #expect(line.contains("apkovl=http://example.test/o.tar.gz"))
        #expect(!line.contains(served))
    }

    /// Nothing is installed from a netboot any more, so nothing asks a guest to install or upload.
    @Test func noInstallArgumentsAreLeft() {
        let line = GuestBoot.netbootCmdline(artifactPort: 8124, modloopPinned: true, environment: [:], payloadOverlay: true)
        for gone in ["openvm.install", "openvm.uuid", "openvm.artifact-token", "root=/dev"] {
            #expect(!line.contains(gone), "\(gone)")
        }
    }
}

/// What a guest installed from its own ISO needs from the host.
@Suite struct LinuxISOHostTests {
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
