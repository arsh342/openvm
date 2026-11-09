// SharedFolders — host directories in the guest over virtio-fs.
//
// Every VM gets one VZVirtioFileSystemDevice, tag "openvm", whose share is a
// VZMultipleDirectoryShare: one entry per configured host directory, keyed by a
// share name derived from the host path. Devices cannot be added to a running
// VM, but a running device's `share` can be replaced, so share-add/remove work
// live by swapping the share set. The guest agent mounts the tag once and
// bind-mounts `<root>/<name>` onto the requested guest path.
//
// There is no network listener and no token: the framework confines the guest to
// the shared directories.
import CryptoKit
import Foundation
import OpenVMCore
import Virtualization

nonisolated enum SharedFolders {
    /// The device tag the guest mounts (`mount -t virtiofs openvm …`).
    static let tag = "openvm"

    /// The share's name inside the device: "s" + 16 hex of SHA-256(host path).
    /// Stable for a host path, a valid directory name, and something the guest
    /// agent can validate strictly ([a-z0-9]).
    static func name(for hostPath: String) -> String {
        let digest = SHA256.hash(data: Data(hostPath.utf8))
        return "s" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The entry dragged files are staged under. Read-only, and present from boot,
    /// because replacing the device's share set breaks reads already in flight:
    /// a drop adds a folder here on the host and never touches the device.
    static let dropsName = "drops"

    /// The entry a guest sends files to the Mac through. Writable, and present from boot for the same
    /// reason as `drops`; the host vets everything that appears in it.
    static let outboxName = "outbox"

    /// The directory set for a list of configured shares.
    static func share(for shares: [VmShare], drops: URL? = nil, outbox: URL? = nil) -> VZMultipleDirectoryShare {
        var directories: [String: VZSharedDirectory] = [:]
        if let drops { directories[dropsName] = VZSharedDirectory(url: drops, readOnly: true) }
        if let outbox { directories[outboxName] = VZSharedDirectory(url: outbox, readOnly: false) }
        for share in shares {
            directories[name(for: share.hostPath)] =
                VZSharedDirectory(
                    url: URL(fileURLWithPath: share.hostPath, isDirectory: true),
                    readOnly: false)
        }
        return VZMultipleDirectoryShare(directories: directories)
    }

    /// The device every VM is configured with, carrying the shares known at boot.
    static func device(for shares: [VmShare], drops: URL? = nil, outbox: URL? = nil) -> VZVirtioFileSystemDeviceConfiguration {
        let device = VZVirtioFileSystemDeviceConfiguration(tag: tag)
        device.share = share(for: shares, drops: drops, outbox: outbox)
        return device
    }

    /// Replace the running device's share set. Must run on the main queue, like
    /// every other call into a live VZVirtualMachine.
    @MainActor
    static func apply(_ shares: [VmShare], drops: URL?, outbox: URL? = nil, to vm: VZVirtualMachine) -> Bool {
        guard
            let device = vm.directorySharingDevices.first(where: {
                ($0 as? VZVirtioFileSystemDevice)?.tag == tag
            }) as? VZVirtioFileSystemDevice
        else { return false }
        device.share = share(for: shares, drops: drops, outbox: outbox)
        return true
    }
}
