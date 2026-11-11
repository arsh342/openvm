// WimHelperVM — runs one job inside a throwaway Alpine VM.
//
// Building Windows media needs wimlib, which is GPL and so cannot ship with openVM, and a Mac
// cannot be assumed to have it. Alpine packages it, so this boots a short-lived Alpine guest,
// lets the overlay's job script install wimlib there, and has it run a script on two shared
// folders: the job folder (read-write: the script, its inputs and outputs) and the mounted
// install ISO (read-only). The guest powers itself off and leaves `status` in the job folder.
// Nothing is installed on the Mac, and nothing GPL is distributed.
import Foundation
import OpenVMCore
import Virtualization

nonisolated enum HelperJobError: Error, CustomStringConvertible {
    case notReady(String)
    case failed(String)
    case noReport(String)
    case timedOut
    case cannotStart(String)

    var description: String {
        switch self {
        case .notReady(let why): return why
        case .failed(let message): return message
        case .noReport(let console):
            return "the helper VM stopped without reporting a result"
                + (console.isEmpty ? "" : "; its console ended:\n\(console)")
        case .timedOut: return "the helper VM did not finish in time"
        case .cannotStart(let why): return "could not start the helper VM: \(why)"
        }
    }
}

/// What the helper left in its status file: nil for success, otherwise why not. Anything but
/// exactly "ok" or an "error: …" line is a missing report, and the console goes with it,
/// because it is the only evidence of what happened.
nonisolated func interpretJobStatus(_ text: String?, consoleTail: String) -> HelperJobError? {
    let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if trimmed == "ok" { return nil }
    if trimmed.hasPrefix("error:"), !trimmed.contains("\n") {
        return .failed(String(trimmed.dropFirst("error:".count)).trimmingCharacters(in: .whitespaces))
    }
    return .noReport(consoleTail)
}

enum WimHelperVM {
    /// Enough for Alpine, wimlib and its libraries in RAM; the big files live on the shared folders.
    nonisolated static let memoryMB = 2048

    /// The kernel command line for a job boot. The guest fetches the overlay and the modules
    /// from this process's own endpoint, which is on its own port: the host that spawned this
    /// process may already hold 8124.
    nonisolated static func commandLine(
        artifactPort: UInt16, modloopPinned: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        GuestBoot.netbootCmdline(
            artifactPort: artifactPort, modloopPinned: modloopPinned, environment: environment,
            payloadOverlay: true)
            + " openvm.job=wim"
    }

    /// Boots the helper, waits for it to power off, and returns when its job succeeded.
    @MainActor
    static func run(jobDir: URL, isoRoot: URL, timeout: TimeInterval = 30 * 60) async throws {
        guard let artifacts = GuestBoot.supportArtifacts() else {
            throw HelperJobError.notReady(
                "the helper VM's files are not fetched yet (run: openvmctl task start fetch-linux)")
        }
        guard GuestPayload.overlay != nil else {
            throw HelperJobError.notReady("this build has no overlay to boot the helper VM with")
        }
        let status = jobDir.appendingPathComponent("status")
        let console = jobDir.appendingPathComponent("console.log")
        try? FileManager.default.removeItem(at: status)

        let receiver = ArtifactReceiver(port: 0)
        do { try receiver.start() } catch { throw HelperJobError.cannotStart("\(error)") }

        let loader = VZLinuxBootLoader(kernelURL: artifacts.kernel)
        loader.initialRamdiskURL = artifacts.initramfs
        loader.commandLine = commandLine(
            artifactPort: receiver.boundPort, modloopPinned: GuestBoot.pinnedModloop() != nil)

        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = try VZFileSerialPortAttachment(url: console, append: false)
        let nic = VZVirtioNetworkDeviceConfiguration()
        nic.attachment = VZNATNetworkDeviceAttachment()
        let folders = VZVirtioFileSystemDeviceConfiguration(tag: "job")
        folders.share = VZMultipleDirectoryShare(directories: [
            "job": VZSharedDirectory(url: jobDir, readOnly: false),
            "iso": VZSharedDirectory(url: isoRoot, readOnly: true),
        ])

        let config = VZVirtualMachineConfiguration()
        config.bootLoader = loader
        config.cpuCount = 2
        config.memorySize = UInt64(memoryMB) << 20
        config.serialPorts = [serial]
        config.networkDevices = [nic]
        config.directorySharingDevices = [folders]
        config.platform = VZGenericPlatformConfiguration()
        do { try config.validate() } catch { throw HelperJobError.cannotStart("\(error)") }

        let vm = VZVirtualMachine(configuration: config)
        do { try await vm.start() } catch { throw HelperJobError.cannotStart("\(error)") }

        let deadline = Date().addingTimeInterval(timeout)
        while vm.state != .stopped && vm.state != .error && Date() < deadline {
            try await Task.sleep(for: .seconds(1))
        }
        if vm.state != .stopped && vm.state != .error {
            try? await vm.stop()
            throw HelperJobError.timedOut
        }
        let tail = String(((try? String(contentsOf: console, encoding: .utf8)) ?? "").suffix(600))
        if let error = interpretJobStatus(try? String(contentsOf: status, encoding: .utf8), consoleTail: tail) {
            throw error
        }
    }
}

extension OpenVMHost {
    /// `--wim-job <job-dir> <iso-root>` runs one helper job and exits, instead of hosting VMs.
    /// Both the app and openvmd call this first, so a shell script (mk-windows-media.sh) can run
    /// the job through either. It takes no host lock: it is a child of a host, not another host.
    public static func runJobCommandIfRequested(_ arguments: [String]) {
        guard arguments.count == 4, arguments[1] == "--wim-job" else { return }
        let job = URL(fileURLWithPath: arguments[2])
        let iso = URL(fileURLWithPath: arguments[3])
        Task { @MainActor in
            do {
                try await WimHelperVM.run(jobDir: job, isoRoot: iso)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("openvm: helper job failed: \(error)\n".utf8))
                exit(1)
            }
        }
        RunLoop.main.run()  // Virtualization needs the main queue; the task above ends the process
    }
}
