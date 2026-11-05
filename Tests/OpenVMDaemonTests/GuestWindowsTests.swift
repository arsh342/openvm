// Tests for the Windows VM configuration.
import OpenVMWindows
import Testing
import Virtualization

@testable import OpenVMHost

/// The private PMU-emulation switch that Virtualization.framework
/// holds off its documented surface. A Windows guest never leaves early boot
/// without it (one vCPU spins at 100%).
/// These tests are environmental by design — they tell this machine/macOS
/// whether the switch is still there.
@Suite
@MainActor
struct GuestWindowsTests {
    @Test("the private PMU switch exists on the generic platform class")
    func pmuSwitchExists() {
        #expect(GuestWindows.pmuSwitchPresent())
    }

    @Test("the private fine-grained-traps switch exists on the generic platform class")
    func trapsSwitchExists() {
        #expect(GuestWindows.trapsSwitchPresent())
    }

    @Test("fine-grained traps default to on, so a run is never silently different")
    func trapsDefaultOn() {
        // The default must match what every run so far used; otherwise the
        // baseline changes under the experiment without anyone noticing.
        #expect(GuestWindows.fineGrainedTrapsEnabled == true)
    }

    @Test("enabling PMU emulation is harmless on a fresh platform config")
    func enableIsHarmless() {
        let platform = VZGenericPlatformConfiguration()
        GuestWindows.enablePMUEmulation(on: platform)
        // nothing to observe: the call must simply not crash
    }

    /// Regression: the switch was "called" for 179 runs and never set,
    /// because `perform(_:with: true)` passes an NSNumber pointer to a BOOL
    /// parameter. Read the value back instead of trusting the call.
    @Test("enabling PMU emulation actually sets the flag (read back through the getter)")
    func enableActuallySetsTheFlags() throws {
        let platform = VZGenericPlatformConfiguration()
        let before = try #require(GuestWindows.readBool(platform, GuestWindows.pmuGetterName))
        #expect(before == false)
        GuestWindows.enablePMUEmulation(on: platform)
        #expect(GuestWindows.readBool(platform, GuestWindows.pmuGetterName) == true)
        if GuestWindows.fineGrainedTrapsEnabled {
            #expect(GuestWindows.readBool(platform, GuestWindows.trapsGetterName) == true)
        }
    }

    @Test("the Windows configuration carries the devices the guest agent needs")
    @available(macOS 13.0, *)
    func windowsConfigurationHasAgentDevices() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openvm-win-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let disk = dir.appendingPathComponent("disk.raw")
        FileManager.default.createFile(atPath: disk.path, contents: Data(count: 1 << 20))
        let config = try GuestWindows.configuration(
            diskURL: disk,
            variableStoreURL: dir.appendingPathComponent("nvram.bin"),
            consoleURL: dir.appendingPathComponent("console.log")
        )
        // The Windows agent binds vsock port 52. The configuration now includes
        // a virtio-vsock device so the guest agent can connect.
        #expect(!config.socketDevices.isEmpty)
    }

    @Test("the Windows configuration boots an EFI disk with a display and a NIC")
    @available(macOS 13.0, *)
    func windowsConfiguration() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openvm-win-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let disk = dir.appendingPathComponent("disk.raw")
        FileManager.default.createFile(atPath: disk.path, contents: Data(count: 1 << 20))
        let config = try GuestWindows.configuration(
            diskURL: disk,
            variableStoreURL: dir.appendingPathComponent("nvram.bin"),
            consoleURL: dir.appendingPathComponent("console.log")
        )
        #expect(config.bootLoader is VZEFIBootLoader)
        #expect(config.storageDevices.count == 1)
        #expect(config.graphicsDevices.count == 1)
        #expect(config.networkDevices.count == 1)
        #expect(config.serialPorts.count == 1)
        #expect(config.platform is VZGenericPlatformConfiguration)
    }
}
