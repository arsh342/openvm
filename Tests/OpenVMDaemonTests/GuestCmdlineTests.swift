// Tests for the kernel command line.
import Testing

@testable import openvmd

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
