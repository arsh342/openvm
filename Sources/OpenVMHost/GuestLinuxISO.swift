// GuestLinuxISO — any ARM64 Linux, installed from its own ISO with its own installer.
//
// This is the machine a PC would be: UEFI firmware, a blank disk, and the ISO on a USB stick. It has no
// openVM agent, so a boot is done when the firmware has been handed the machine, not when an agent
// answers. Resizing is the framework's own: the view asks the guest's display driver directly.
import Darwin
import Foundation
import OpenVMCore
import OpenVMWindows
import Virtualization

enum GuestLinuxISO {
    /// `iso` is nil once the person has ejected it: the installed system then boots from the disk.
    @available(macOS 13.0, *)
    @MainActor
    static func configuration(
        diskURL: URL, iso: URL?, variableStoreURL: URL, consoleURL: URL, cpus: Int, memoryMB: Int,
        machineIdentifier: Data?, directorySharing: VZDirectorySharingDeviceConfiguration
    ) throws -> VZVirtualMachineConfiguration {
        let platform = VZGenericPlatformConfiguration()
        if let machineIdentifier, let id = VZGenericMachineIdentifier(dataRepresentation: machineIdentifier) {
            platform.machineIdentifier = id
        }
        let loader = VZEFIBootLoader()
        // The installer records the installed system here, so it has to survive between boots.
        loader.variableStore =
            FileManager.default.fileExists(atPath: variableStoreURL.path)
            ? VZEFIVariableStore(url: variableStoreURL)
            : try VZEFIVariableStore(creatingVariableStoreAt: variableStoreURL, options: [])

        let console = VZVirtioConsoleDeviceSerialPortConfiguration()
        console.attachment = try VZFileSerialPortAttachment(url: consoleURL, append: false)
        let nic = VZVirtioNetworkDeviceConfiguration()
        nic.attachment = VZNATNetworkDeviceAttachment()
        let display = VZVirtioGraphicsDeviceConfiguration()
        display.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1920, heightInPixels: 1200)]
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        output.sink = VZHostAudioOutputStreamSink()
        let audio = VZVirtioSoundDeviceConfiguration()
        audio.streams = [output]

        let config = VZVirtualMachineConfiguration()
        config.bootLoader = loader
        config.platform = platform
        config.cpuCount = cpus
        config.memorySize = UInt64(memoryMB) << 20
        config.serialPorts = [console]
        config.networkDevices = [nic]
        config.graphicsDevices = [display]
        config.audioDevices = [audio]
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        config.directorySharingDevices = [directorySharing]
        let disk = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]
        if let iso {
            let attachment = try VZDiskImageStorageDeviceAttachment(url: iso, readOnly: true)
            config.storageDevices.append(VZUSBMassStorageDeviceConfiguration(attachment: attachment))
        }
        return config
    }

    @available(macOS 13.0, *)
    @MainActor
    static func boot(
        cpus: Int, memoryMB: Int, consoleURL: URL, diskURL: URL?, vmUUID: String, variableStorePath: String?,
        shares: [VmShare], installMediaPath: String?, machineIdentifier: Data?,
        publish: @MainActor (LiveGuest?) -> Void
    ) async throws -> LiveGuest {
        guard let diskURL else { throw GuestBootError.failure("this VM has no disk") }
        var iso: URL?
        if let installMediaPath {
            guard FileManager.default.fileExists(atPath: installMediaPath) else {
                throw GuestBootError.failure(
                    "the installer ISO is gone (\(installMediaPath)): put it back, or eject it if the install is finished")
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: installMediaPath)[.size] as? UInt64) ?? 0
            if let problem = LinuxISOCheck.sizeProblem(bytes: size) { throw GuestBootError.failure(problem) }
            iso = URL(fileURLWithPath: installMediaPath)
        }
        let store = variableStorePath.map { URL(fileURLWithPath: $0) }
            ?? diskURL.deletingLastPathComponent().appendingPathComponent("nvram.bin")
        let config = try configuration(
            diskURL: diskURL, iso: iso, variableStoreURL: store, consoleURL: consoleURL, cpus: cpus,
            memoryMB: memoryMB, machineIdentifier: machineIdentifier,
            directorySharing: SharedFolders.device(
                for: shares, drops: try dropRoot(vmUUID, create: true), outbox: try outboxRoot(vmUUID, create: true)))
        try config.validate()
        let vm = VZVirtualMachine(configuration: config)
        let guest = LiveGuest(vm: vm, uuid: vmUUID, hasAgent: false)
        publish(guest)
        try await vm.start()
        return guest
    }
}

// MARK: checking an ISO

/// The architectures' removable-media boot files, as a directory on the ISO names them, and as an
/// embedded FAT image does. Most Linux ISOs are hybrids macOS cannot mount (measured), so the bytes are
/// read instead: an ARM64 Alpine ISO held only the first three, its x86_64 build only the last three.
private nonisolated let arm64BootNames = ["BOOTAA64.EFI", "bootaa64.efi", "BOOTAA64EFI"]
private nonisolated let x86BootNames = ["BOOTX64.EFI", "bootx64.efi", "BOOTX64 EFI"]

/// Reads the whole file in chunks, because a boot image can sit anywhere in an ISO. `chunk` is for tests.
nonisolated func inspectLinuxISO(_ iso: URL, chunk: Int = 8 << 20) -> LinuxISOCheck.Verdict {
    guard let handle = try? FileHandle(forReadingFrom: iso) else { return .unknown }
    defer { try? handle.close() }
    let longest = (arm64BootNames + x86BootNames).map(\.utf8.count).max() ?? 0
    var carried = Data()  // the end of the last chunk, so a name split across two chunks is still found
    var sawX86 = false
    while let piece = try? handle.read(upToCount: chunk), !piece.isEmpty {
        let window = carried + piece
        func holds(_ name: String) -> Bool {
            let needle = Array(name.utf8)
            return window.withUnsafeBytes { memmem($0.baseAddress, $0.count, needle, needle.count) != nil }
        }
        if arm64BootNames.contains(where: holds) { return .usable }
        sawX86 = sawX86 || x86BootNames.contains(where: holds)
        carried = window.suffix(longest - 1)
    }
    return LinuxISOCheck.verdict(efiBootFiles: sawX86 ? ["bootx64.efi"] : [])
}

nonisolated func linuxISOCheckOp(_ r: VmRequest) throws -> Envelope {
    guard case .text(let path)? = r.arg("iso") else { return r.fail("linux-iso-check needs an iso") }
    switch validISOPath(path) {
    case .failure(let error): return r.fail(error.description)
    case .success(let url):
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        if let problem = LinuxISOCheck.sizeProblem(bytes: size) {
            return r.ok([("usable", .bool(false)), ("problem", .text(problem))])
        }
        let verdict = inspectLinuxISO(url)
        var fields: [(key: String, value: CBOR)] = [("usable", .bool(verdict.problem == nil))]
        if let problem = verdict.problem { fields.append(("problem", .text(problem))) }
        if verdict == .unknown { fields.append(("unknown", .bool(true))) }
        return r.ok(fields)
    }
}

/// Takes the installer ISO out of a stopped VM, so it starts from its disk. The ISO is the person's own
/// file: only the VM forgets it.
nonisolated func ejectInstaller(_ r: VmRequest) throws -> Envelope {
    let record = try r.record()
    guard record.bootMode == .linuxISO, record.installMediaPath != nil else {
        return r.fail("\(record.name) has no installer ISO attached")
    }
    guard record.state == .stopped else { return r.fail("shut \(record.name) down to eject its installer ISO") }
    try registry.clearInstallMedia(record.uuid)
    return r.ok([("message", .text("ejected the installer ISO from \(record.name)"))])
}
