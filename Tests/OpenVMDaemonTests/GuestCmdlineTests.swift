// Tests for the kernel command line.
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
