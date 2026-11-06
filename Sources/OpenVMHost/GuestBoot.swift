// GuestBoot — the proven alpine netboot boot path,
// moved into the daemon for `openvmd start`. Boots the alpine ARM64
// kernel + initramfs directly (bootloaders only matter for ISO/disk installs),
// waits for a boot marker on the guest serial console, and tracks live machines for
// `stop`.
//
// Threading: Virtualization demands the main dispatch queue; all VZ work runs in
// @MainActor boot(), while supportArtifacts is plain filesystem work so the
// listener thread may call it.
import Darwin
import Foundation
import OpenVMCore
import OpenVMWindows
import Virtualization

/// A live guest held by the daemon: just the VZ machine — its dedicated OVMC
/// channel is the virtio-vsock device (guest agent listens on port 52); the
/// serial port stays the console (/dev/hvc0 on the guest).
nonisolated final class LiveVMs: @unchecked Sendable {
    private let lock = NSLock()
    private var vms: [String: LiveGuest] = [:]
    private var cancelled = Set<String>()

    func add(_ id: String, _ g: LiveGuest) {
        lock.lock()
        defer { lock.unlock() }
        vms[id] = g
    }

    /// Every VM this host holds a live guest for.
    func ids() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(vms.keys)
    }

    func peek(_ id: String) -> LiveGuest? {
        lock.lock()
        defer { lock.unlock() }
        return vms[id]
    }

    /// Removes and returns the live machine, if the daemon still holds one.
    func take(_ id: String) -> LiveGuest? {
        lock.lock()
        defer { lock.unlock() }
        let g = vms[id]
        vms[id] = nil
        return g
    }

    /// Removes the machine only if it is this boot's. Atomic, so a late report from an
    /// old boot cannot remove a newer one.
    func takeIfBoot(_ id: String, _ boot: UUID) -> LiveGuest? {
        lock.lock()
        defer { lock.unlock() }
        guard shouldReap(held: vms[id]?.boot, reported: boot) else { return nil }
        let g = vms[id]
        vms[id] = nil
        return g
    }

    /// The guest finished booting: channel operations may use it now.
    func markReady(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        vms[id]?.phase = .ready
    }

    /// A `stop` arrived while the VM was still booting. The boot reads this to say
    /// "cancelled" instead of reporting a mysterious stop.
    func markCancelled(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        cancelled.insert(id)
    }

    func takeCancelled(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled.remove(id) != nil
    }
}

struct LiveGuest {
    let vm: VZVirtualMachine
    /// Tells one boot of a VM from the next, off the main actor.
    nonisolated let boot: UUID
    nonisolated var phase: GuestPhase = .booting
    /// The framework holds its delegate weakly, so this is what keeps it alive.
    nonisolated let delegate: GuestDelegate

    /// Wraps a machine and starts listening for its end. Main actor: the delegate is
    /// set on the machine's own queue.
    @MainActor
    init(vm: VZVirtualMachine, uuid: String) {
        let boot = UUID()
        let delegate = GuestDelegate(uuid: uuid, boot: boot)
        vm.delegate = delegate
        self.vm = vm
        self.boot = boot
        self.delegate = delegate
    }
}

// Semaphore-preserving result box for hopping from the nonisolated listener
// thread onto the MainActor (Swift 6 forbids capturing mutable locals in
// @Sendable closures). "" = success; any other string = the failure message.
nonisolated final class BootWaiter: @unchecked Sendable {
    private let sem = DispatchSemaphore(value: 0)
    private(set) var value: String?

    func complete(_ v: String) {
        value = v
        sem.signal()
    }

    func wait() {
        sem.wait()
    }
}

nonisolated enum GuestBootError: Error {
    case failure(String)
}

enum GuestBoot {
    nonisolated static let markers = ["Welcome to Alpine", "OpenRC"]

    nonisolated static let cmdline =
        "console=ttyAMA0,115200n8 console=hvc0 ip=dhcp modules=loop,squashfs,sd-mod,usb-storage,ext4 "
        + "alpine_repo=https://dl-cdn.alpinelinux.org/alpine/v3.22/main " + "modloop=\(mirrorModloop)"

    nonisolated static let mirrorModloop =
        "https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/aarch64/netboot/modloop-virt"

    /// Netboot installs Alpine on first start. Persistent boots must use the
    /// matching kernel/initramfs pair exported from that installed system.
    nonisolated static func effectiveCmdline(
        rootDevice: String?, installDisk: Bool, vmUUID: String, artifactPort: UInt16,
        artifactToken: String? = nil, modloopPinned: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment, payloadOverlay: Bool = false
    ) -> String {
        let url = environment["OPENVM_APKOVL_URL"] ?? ""
        var result = cmdline
        // Only netboot uses the modloop. The mirror's copy is the fallback for a
        // support directory from before it was pinned, and works only until
        // Alpine's next kernel update.
        if rootDevice == nil, modloopPinned {
            result = result.replacingOccurrences(
                of: mirrorModloop, with: "http://192.168.64.1:\(artifactPort)/\(ArtifactReceiver.modloopName)"
            )
        }
        // The overlay is what makes a first boot install Alpine and start the agent; without it the
        // guest is stock Alpine (measured: no installer, no agent). An explicit URL wins, which is
        // how the smoke serves its own; otherwise the host serves the one shipped in its payload.
        if rootDevice == nil {
            if !url.isEmpty {
                result += " apkovl=\(url)"
            } else if payloadOverlay {
                result += " apkovl=http://192.168.64.1:\(artifactPort)/\(GuestPayload.overlayName)"
            }
        }
        if let rootDevice {
            result += " root=\(rootDevice) rootfstype=ext4 rw"
        } else if installDisk {
            result += " openvm.install=1 openvm.uuid=\(vmUUID) openvm.artifact-port=\(artifactPort)"
            // The guest presents this in X-OpenVM-Token when it uploads the
            // installed kernel/initramfs; ArtifactReceiver refuses anything else.
            if let artifactToken { result += " openvm.artifact-token=\(artifactToken)" }
        }
        return result
    }

    /// The modloop tools/build/fetch-linux.sh pinned with the kernel, if it did.
    nonisolated static func pinnedModloop() -> URL? {
        guard let kernel = supportArtifacts()?.kernel else { return nil }
        let file = kernel.deletingLastPathComponent().appendingPathComponent(ArtifactReceiver.modloopName)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// Where the fetched Linux guest files live: `OPENVM_SUPPORT`, else `~/openvm-support`.
    nonisolated static func supportBase() -> URL {
        let env = ProcessInfo.processInfo.environment["OPENVM_SUPPORT"] ?? ""
        return env.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("openvm-support")
            : URL(fileURLWithPath: env)
    }

    /// nil when the alpine support artifacts are absent, so callers may fall
    /// back to a registry-only transition (openvmctl stays usable without the
    /// guest bits installed).
    nonisolated static func supportArtifacts() -> (kernel: URL, initramfs: URL)? {
        let dir = supportBase().appendingPathComponent("linux-arm64")
        let kernel = dir.appendingPathComponent("vmlinuz")
        let initramfs = dir.appendingPathComponent("initrd.gz")
        guard FileManager.default.fileExists(atPath: kernel.path),
            FileManager.default.fileExists(atPath: initramfs.path)
        else { return nil }
        return (kernel, initramfs)
    }

    /// Boots Alpine and returns the live machine after its first disk install
    /// completes, or after persistent-root boot, with the agent listening. On marker
    /// timeout the guest is stopped before throwing, so nothing keeps running.
    /// The console file is truncated per boot.
    @MainActor
    static func boot(
        cpus: Int, memoryMB: Int, consoleURL: URL, diskURL: URL?, vmUUID: String, artifactPort: UInt16,
        timezone: String? = nil, bootMode: BootMode = .linux, variableStorePath: String? = nil,
        artifactToken: String? = nil, shares: [VmShare] = [], installMediaPath: String? = nil,
        machineIdentifier: Data? = nil,
        publish: @MainActor (LiveGuest?) -> Void = { _ in }
    ) async throws -> LiveGuest {
        if bootMode == .windows {
            if #available(macOS 13.0, *) {
                return try await bootWindows(
                    cpus: cpus, memoryMB: memoryMB, consoleURL: consoleURL, diskURL: diskURL, vmUUID: vmUUID,
                    artifactPort: artifactPort, timezone: timezone, variableStorePath: variableStorePath,
                    shares: shares, installMediaPath: installMediaPath, machineIdentifier: machineIdentifier,
                    publish: publish)
            } else {
                throw GuestBootError.failure("Windows boot requires macOS 13.0 or newer")
            }
        }
        guard let artifacts = supportArtifacts() else {
            throw GuestBootError.failure("run tools/build/fetch-linux.sh")
        }
        try? FileManager.default.removeItem(at: consoleURL)

        let installRecordURL = diskURL?.appendingPathExtension("openvm-installed")
        let installedRoot = installRecordURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.hasPrefix("/dev/") ? $0 : nil }

        let kernelURL: URL
        let initramfsURL: URL
        if installedRoot != nil, let diskURL {
            let installedKernel = diskURL.appendingPathExtension("openvm-kernel")
            let installedInitramfs = diskURL.appendingPathExtension("openvm-initramfs")
            guard FileManager.default.fileExists(atPath: installedKernel.path),
                FileManager.default.fileExists(atPath: installedInitramfs.path)
            else {
                throw GuestBootError.failure(
                    "persistent boot artifacts are missing for this disk; first-boot mkinitfs export is required"
                )
            }
            kernelURL = installedKernel
            initramfsURL = installedInitramfs
        } else {
            kernelURL = artifacts.kernel
            initramfsURL = artifacts.initramfs
        }

        let modloopPinned = pinnedModloop() != nil
        if !modloopPinned, installedRoot == nil {
            FileHandle.standardError.write(
                Data(
                    "openvmd: no pinned modloop; using Alpine's mirror, which breaks at its next kernel update (run tools/build/fetch-linux.sh)\n"
                        .utf8))
        }
        let loader = VZLinuxBootLoader(kernelURL: kernelURL)
        loader.initialRamdiskURL = initramfsURL
        loader.commandLine = effectiveCmdline(
            rootDevice: installedRoot,
            installDisk: diskURL != nil && installedRoot == nil,
            vmUUID: vmUUID, artifactPort: artifactPort,
            artifactToken: artifactToken,
            modloopPinned: modloopPinned, payloadOverlay: GuestPayload.overlay != nil)

        let console = VZVirtioConsoleDeviceSerialPortConfiguration()
        console.attachment = try VZFileSerialPortAttachment(url: consoleURL, append: false)

        let nic = VZVirtioNetworkDeviceConfiguration()
        nic.attachment = VZNATNetworkDeviceAttachment()

        let config = VZVirtualMachineConfiguration()
        config.bootLoader = loader
        config.cpuCount = cpus
        config.memorySize = UInt64(memoryMB) << 20
        config.serialPorts = [console]
        // Dedicated OVMC channel, on vsock rather than virtio-console:
        // VZ never activates a FileHandle-attached second serial port — the guest
        // sees both vports host-disconnected (ENXIO on open) — so the channel rides
        // the first-class virtio-vsock device; the guest agent listens on port 52.
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        if let diskURL {
            let attachment = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
            config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]
        }
        config.networkDevices = [nic]
        config.platform = VZGenericPlatformConfiguration()
        // Shared folders ride virtio-fs (tag "openvm"); the share set can be
        // replaced while the VM runs (SharedFolders.apply).
        config.directorySharingDevices = [
            SharedFolders.device(
                for: shares, drops: try dropRoot(vmUUID, create: true), outbox: try outboxRoot(vmUUID, create: true))
        ]
        // The display dynamic resolution acts on (DisplayControl.swift).
        if #available(macOS 13.0, *) {
            let display = VZVirtioGraphicsDeviceConfiguration()
            display.scanouts = [
                VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1920, heightInPixels: 1080)
            ]
            config.graphicsDevices = [display]
            config.keyboards = [VZUSBKeyboardConfiguration()]
            config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        }
        config.audioDevices = [HostAudio.device()]
        try config.validate()

        let vm = VZVirtualMachine(configuration: config)
        // Published before it starts, so a window can show the boot from its first frame.
        let guest = LiveGuest(vm: vm, uuid: vmUUID)
        publish(guest)
        try await vm.start()

        let timeoutSeconds = installedRoot == nil && diskURL != nil ? 1800 : 120
        let deadline = Date().addingTimeInterval(Double(timeoutSeconds))
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 500_000_000)
            guard vm.state == .running || vm.state == .starting else {
                throw GuestBootError.failure("the guest stopped during boot (state \(vm.state.rawValue))")
            }
            if let data = try? Data(contentsOf: consoleURL) {
                let text = String(decoding: data, as: UTF8.self)
                if installedRoot == nil, diskURL != nil,
                    let root = installedRootMarker(in: text)
                {
                    guard let diskURL,
                        FileManager.default.fileExists(
                            atPath: diskURL.appendingPathExtension("openvm-kernel").path),
                        FileManager.default.fileExists(
                            atPath: diskURL.appendingPathExtension("openvm-initramfs").path)
                    else {
                        continue
                    }
                    guard await GuestChannel.responds(guest) else { continue }
                    try Data(root.utf8).write(to: installRecordURL!, options: .atomic)
                    await syncClock(guest, timezone: timezone)
                    return guest
                }
                if installedRoot != nil,
                    markers.contains(where: { text.contains($0) }),
                    await GuestChannel.responds(guest)
                {
                    await syncClock(guest, timezone: timezone)
                    return guest
                }
                if diskURL == nil,
                    markers.contains(where: { text.contains($0) })
                {
                    await syncClock(guest, timezone: timezone)
                    return guest
                }
            }
        }

        // Marker timeout: stop the guest so nothing keeps running, then fail.
        try await GuestShutdown.stop(
            isStopped: { vm.state == .stopped },
            requestStop: { try vm.requestStop() },
            forceStop: { try await vm.stop() })
        let text = String(decoding: (try? Data(contentsOf: consoleURL)) ?? Data(), as: UTF8.self)
        let reason =
            text.contains("emergency recovery shell")
            ? "guest is in the initramfs emergency recovery shell (boot media not mounted)"
            : "guest did not reach boot readiness with a responding openvm-tools agent"
        throw GuestBootError.failure("\(reason); console tail:\n\(String(text.suffix(400)))")
    }

    /// Boots a Windows guest. A disk that is not installed yet first runs the
    /// install boot: the target disk plus the install media, WinPE running
    /// tools/windows/install.cmd, until the guest shuts itself down. The result
    /// is read off the media; then the installed disk boots on its own.
    @available(macOS 13.0, *)
    @MainActor
    static func bootWindows(
        cpus: Int, memoryMB: Int, consoleURL: URL, diskURL: URL?, vmUUID: String, artifactPort: UInt16,
        timezone: String? = nil, variableStorePath: String? = nil, shares: [VmShare] = [],
        installMediaPath: String? = nil, machineIdentifier: Data? = nil,
        publish: @MainActor (LiveGuest?) -> Void = { _ in }
    ) async throws -> LiveGuest {
        guard let diskURL else {
            throw GuestBootError.failure("Windows boot requires a disk image")
        }
        let vmDir = diskURL.deletingLastPathComponent()
        let variableStoreURL =
            variableStorePath.map { URL(fileURLWithPath: $0) } ?? vmDir.appendingPathComponent("nvram.bin")
        let installRecord = diskURL.appendingPathExtension("openvm-installed")

        if !FileManager.default.fileExists(atPath: installRecord.path) {
            guard let installMediaPath else {
                throw GuestBootError.failure(
                    "this Windows disk is not installed yet; create the VM with --install-media <media.raw> (tools/build/mk-windows-media.sh builds it)"
                )
            }
            try await installWindows(
                cpus: cpus, memoryMB: memoryMB, consoleURL: consoleURL,
                diskURL: diskURL, mediaURL: URL(fileURLWithPath: installMediaPath),
                vmDir: vmDir, vmUUID: vmUUID, publish: publish)
            try Data("windows\n".utf8).write(to: installRecord, options: .atomic)
            // The install is done, so the 22 GB of media (if openVM built it) is no longer needed.
            if removeOwnedMedia(installMediaPath, mediaRoot: mediaFolder) {
                try? registry.clearInstallMedia(vmUUID)
            }
            // The installed system boots through the firmware's removable-media
            // path (our chainloader on the new ESP); start from a clean store.
            try? FileManager.default.removeItem(at: variableStoreURL)
        }

        let config = try GuestWindows.configuration(
            diskURL: diskURL, variableStoreURL: variableStoreURL, consoleURL: consoleURL,
            cpuCount: cpus, memoryMB: memoryMB, machineIdentifier: machineIdentifier)
        // Shared folders: virtio-fs, served in the guest by virtio-win's viofs
        // driver and the WinFsp-based VirtIO-FS service.
        config.directorySharingDevices = [
            SharedFolders.device(
                for: shares, drops: try dropRoot(vmUUID, create: true), outbox: try outboxRoot(vmUUID, create: true))
        ]
        try config.validate()
        let vm = VZVirtualMachine(configuration: config)
        let guest = LiveGuest(vm: vm, uuid: vmUUID)
        publish(guest)
        try await vm.start()

        // The guest agent answers once it is installed and running. Until the
        // Windows agent can be built, a running VM without one is still a
        // booted guest: the lifecycle ops work, the channel ops report that no
        // agent answers.
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            guard vm.state == .running else {
                throw GuestBootError.failure("Windows guest stopped during boot (state \(vm.state.rawValue))")
            }
            if await GuestChannel.responds(guest) {
                await GuestBoot.syncClock(guest, timezone: timezone)
                return guest
            }
        }
        FileHandle.standardError.write(
            Data("openvmd: Windows guest is running; no openvm-tools agent answered yet\n".utf8))
        return guest
    }

    /// The install boot: target + media, a throwaway variable store, and a wait
    /// for WinPE to shut the VM down. Applying install.wim takes minutes.
    @available(macOS 13.0, *)
    @MainActor
    static func installWindows(
        cpus: Int, memoryMB: Int, consoleURL: URL, diskURL: URL, mediaURL: URL,
        vmDir: URL, vmUUID: String, publish: @MainActor (LiveGuest?) -> Void
    ) async throws {
        guard FileManager.default.fileExists(atPath: mediaURL.path) else {
            throw GuestBootError.failure("install media not found: \(mediaURL.path)")
        }
        installs.begin(vmUUID)
        defer { installs.end(vmUUID) }
        let installStore = vmDir.appendingPathComponent("nvram-install.bin")
        try? FileManager.default.removeItem(at: installStore)
        defer { try? FileManager.default.removeItem(at: installStore) }
        let config = try GuestWindows.configuration(
            diskURL: diskURL, variableStoreURL: installStore, consoleURL: consoleURL,
            cpuCount: cpus, memoryMB: max(memoryMB, 4096), additionalDisks: [mediaURL])
        try config.validate()
        let vm = VZVirtualMachine(configuration: config)
        // The install is visible too: a window shows WinPE working, and a stop cancels it.
        publish(LiveGuest(vm: vm, uuid: vmUUID))
        defer { publish(nil) }
        FileHandle.standardError.write(
            Data("openvmd: Windows install boot started (WinPE applies the image)\n".utf8))
        try await vm.start()
        let deadline = Date().addingTimeInterval(75 * 60)
        while vm.state != .stopped && vm.state != .error && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        if vm.state != .stopped && vm.state != .error {
            try? await vm.stop()
            throw GuestBootError.failure("Windows install did not finish within 75 minutes")
        }
        if vm.state == .error {
            throw GuestBootError.failure("Windows install VM stopped with an error")
        }
        let result = try WindowsInstallMedia.readResult(mediaURL)
        guard result.ok else {
            throw GuestBootError.failure(
                "Windows install failed; install.log tail:\n"
                    + String(result.log.suffix(1500)))
        }
        FileHandle.standardError.write(Data("openvmd: Windows install finished OK\n".utf8))
    }

    /// Best-effort clock push right before the guest is handed back; a sync
    /// failure never blocks boot or resume (the host is the
    /// time authority). The exchange runs off the main actor — it waits for
    /// a VZ callback that is delivered there.
    @MainActor
    static func syncClock(_ guest: LiveGuest, timezone: String? = nil) async {
        do {
            try await GuestChannel.offMainActor { try GuestChannel.timesync(guest, timezone: timezone) }
        } catch {
            FileHandle.standardError.write("openvmd: guest timesync skipped: \(error)\n".data(using: .utf8)!)
        }
    }

    private static func installedRootMarker(in console: String) -> String? {
        for line in console.split(separator: "\n").reversed() {
            guard let range = line.range(of: "OPENVM_DISK_READY=/dev/") else { continue }
            let candidate = line[range.upperBound...].prefix { $0.isLetter || $0.isNumber }
            if !candidate.isEmpty { return "/dev/\(candidate)" }
        }
        return nil
    }
}
