// Virtualization.framework keeps the one switch
// every Windows guest needs off its documented surface — PMU emulation. A
// generic-platform guest whose CPU lacks an emulated PMU never leaves early
// boot (one vCPU spinning forever); Linux shrugs, Windows does not.
// It is a private selector: probed at runtime in tests, never assumed, and
// safe to call as a no-op if Apple removes it. Prior art: the tart Windows
// fork's `_setPerformanceMonitoringUnitEmulationEnabled`.
import Foundation
import Virtualization

/// Simple error type for GuestWindows operations.
nonisolated struct GuestWindowsError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
    init(message: String) {
        self.message = message
    }
}

@MainActor
/// The Virtualization.framework configuration for a Windows guest.
public enum GuestWindows {
    public static let pmuSelectorName = "_setPerformanceMonitoringUnitEmulationEnabled:"
    public static let trapsSelectorName = "_setFineGrainedTrapsEmulationEnabled:"

    /// True when this macOS still carries the private PMU setter.
    public static func pmuSwitchPresent(
        on platform: VZGenericPlatformConfiguration = VZGenericPlatformConfiguration()
    ) -> Bool {
        platform.responds(to: Selector(pmuSelectorName))
    }

    /// True when this macOS still carries the private fine-grained-traps setter.
    public static func trapsSwitchPresent(
        on platform: VZGenericPlatformConfiguration = VZGenericPlatformConfiguration()
    ) -> Bool {
        platform.responds(to: Selector(trapsSelectorName))
    }

    /// Verify that the host supports the required Virtualization.framework features for Windows guests.
    public static func checkHostSupport() throws {
        // Verify PMU emulation switch is available
        guard pmuSwitchPresent() else {
            throw GuestWindowsError(
                message: "Host does not support PMU emulation (required for Windows guests)")
        }
        // Verify fine-grained traps switch is available
        guard trapsSwitchPresent() else {
            throw GuestWindowsError(
                message: "Host does not support fine-grained traps emulation (required for Windows guests)")
        }
    }

    /// Whether fine-grained traps emulation is enabled for this process.
    ///
    /// Default ON, because that is the configuration every run so far used and
    /// the boot gets as far as it does under it. `OPENVM_TRAPS=0` turns it off
    /// so the axis can be tested; without this switch the experiment matrix has
    /// only the PMU axis and "traps are on" is an assumption rather than a
    /// variable.
    ///
    /// Read from the environment rather than a parameter so every caller
    /// (probe, tests, future daemon) picks it up without threading a flag
    /// through, and so a run's log can record which arm it was.
    public static var fineGrainedTrapsEnabled: Bool {
        guard let raw = ProcessInfo.processInfo.environment["OPENVM_TRAPS"] else {
            return true
        }
        let v = raw.trimmingCharacters(in: .whitespaces).lowercased()
        return !(v == "0" || v == "off" || v == "false" || v == "no")
    }

    public static let pmuGetterName = "_performanceMonitoringUnitEmulationEnabled"
    public static let trapsGetterName = "_fineGrainTrapsEmulationEnabled"

    /// Call a private `-(void)setX:(BOOL)` with a real BOOL.
    ///
    /// `perform(_:with:)` cannot do this: it passes an object, so the BOOL receives
    /// bits of a pointer and the setter reads NO. Without PMU emulation, Windows
    /// spins at 100% in early boot.
    private static func setBool(_ platform: VZGenericPlatformConfiguration, _ name: String, _ value: Bool) {
        let sel = Selector(name)
        guard platform.responds(to: sel), let imp = platform.method(for: sel) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(imp, to: Setter.self)(platform, sel, value)
    }

    /// Read a private `-(BOOL)x` getter; nil when the getter is gone.
    public static func readBool(_ platform: VZGenericPlatformConfiguration, _ name: String) -> Bool? {
        let sel = Selector(name)
        guard platform.responds(to: sel), let imp = platform.method(for: sel) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(imp, to: Getter.self)(platform, sel)
    }

    /// A new machine identifier, as the data a VM record stores.
    @available(macOS 13.0, *)
    public nonisolated static func newMachineIdentifier() -> Data {
        VZGenericMachineIdentifier().dataRepresentation
    }

    /// Turn PMU emulation on for a generic-platform (Linux/Windows) guest.
    /// Harmless no-op when the switch is gone; OVMC keeps working.
    public static func enablePMUEmulation(on platform: VZGenericPlatformConfiguration) {
        setBool(platform, pmuSelectorName, true)
        // Fine-grained traps emulation is a separate private switch. The prior
        // art (the tart Windows fork) found it unnecessary once PMU emulation is
        // on. OPENVM_TRAPS=0 leaves it off. No-op when the selector is gone.
        // (Neither switch was ever set at first — see setBool.)
        if fineGrainedTrapsEnabled {
            setBool(platform, trapsSelectorName, true)
        }
    }

    /// A configuration that boots Windows 11 ARM64 from an EFI disk image.
    ///
    /// Apple's firmware wants a variable store of its own (the EFI NVRAM the
    /// guest keeps its boot state in) and a display to hand the boot manager;
    /// the disk carries the installation media. The guest side still needs
    /// virtio drivers, which the installation supplies.
    @available(macOS 13.0, *)
    public static func configuration(
        diskURL: URL,
        variableStoreURL: URL,
        consoleURL: URL,
        cpuCount: Int = 4,
        memoryMB: Int = 4096,
        displayWidth: Int = 1920,
        displayHeight: Int = 1080,
        additionalDisks: [URL] = [],
        machineIdentifier: Data? = nil
    ) throws -> VZVirtualMachineConfiguration {
        let platform = VZGenericPlatformConfiguration()
        enablePMUEmulation(on: platform)
        // Windows ties its hardware identity (and activation) to the SMBIOS
        // UUID, which comes from the machine identifier. Without a persisted
        // one, every boot is a different machine.
        if let machineIdentifier, let id = VZGenericMachineIdentifier(dataRepresentation: machineIdentifier) {
            platform.machineIdentifier = id
        }

        let loader = VZEFIBootLoader()
        // A fresh store is created once; afterwards the guest keeps its NVRAM.
        if FileManager.default.fileExists(atPath: variableStoreURL.path) {
            loader.variableStore = VZEFIVariableStore(url: variableStoreURL)
        } else {
            loader.variableStore = try VZEFIVariableStore(
                creatingVariableStoreAt: variableStoreURL,
                options: [])
        }

        let console = VZVirtioConsoleDeviceSerialPortConfiguration()
        console.attachment = try VZFileSerialPortAttachment(url: consoleURL, append: false)

        let nic = VZVirtioNetworkDeviceConfiguration()
        nic.attachment = VZNATNetworkDeviceAttachment()

        let display = VZVirtioGraphicsDeviceConfiguration()
        display.scanouts = [
            VZVirtioGraphicsScanoutConfiguration(
                widthInPixels: displayWidth, heightInPixels: displayHeight)
        ]

        // A sound card with no stream is connected to nothing.
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        output.sink = VZHostAudioOutputStreamSink()
        let audio = VZVirtioSoundDeviceConfiguration()
        audio.streams = [output]

        let config = VZVirtualMachineConfiguration()

        // Dedicated OVMC channel (virtio-vsock): guest agent listens on port 52.
        let socketConfig = VZVirtioSocketDeviceConfiguration()
        config.socketDevices = [socketConfig]

        config.bootLoader = loader
        config.platform = platform
        config.cpuCount = cpuCount
        config.memorySize = UInt64(memoryMB) << 20
        config.serialPorts = [console]
        config.networkDevices = [nic]
        config.graphicsDevices = [display]
        config.audioDevices = [audio]
        // Input: Windows has inbox drivers for USB HID, so the console can be used
        // without any virtio-input driver.
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        let attachment = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]
        // The install boot attaches the install media as a second disk; the
        // install script writes its result there, so it is read-write.
        for url in additionalDisks {
            let extra = try VZDiskImageStorageDeviceAttachment(url: url, readOnly: false)
            config.storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: extra))
        }
        return config
    }
}
