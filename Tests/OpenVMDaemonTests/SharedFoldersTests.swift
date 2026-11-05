// Tests for the virtio-fs share set.
import Foundation
import OpenVMCore
import Testing
import Virtualization

@testable import openvmd

/// Shared folders over virtio-fs: the names the guest agent validates and the
/// device every VM is configured with.
@Suite
@MainActor
struct SharedFoldersTests {
    @Test("share names are stable, distinct per path, and what the guest agent accepts")
    func shareNames() {
        let a = SharedFolders.name(for: "/Users/me/Projects")
        #expect(a == SharedFolders.name(for: "/Users/me/Projects"))
        #expect(a != SharedFolders.name(for: "/Users/me/Other"))
        // openvm-tools.c valid_share_name: [a-z0-9], 1..40 chars.
        #expect(a.count == 17 && a.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) })
    }

    @Test("the device tag is valid and the share set carries every configured folder")
    func deviceCarriesShares() throws {
        try VZVirtioFileSystemDeviceConfiguration.validateTag(SharedFolders.tag)
        let dir = FileManager.default.temporaryDirectory
        let shares = [
            VmShare(hostPath: dir.path, guestPath: "/mnt/openvm/tmp"),
            VmShare(hostPath: "/", guestPath: "/mnt/openvm/root"),
        ]
        let device = SharedFolders.device(for: shares)
        #expect(device.tag == SharedFolders.tag)
        let share = try #require(device.share as? VZMultipleDirectoryShare)
        #expect(Set(share.directories.keys) == Set(shares.map { SharedFolders.name(for: $0.hostPath) }))
        for name in share.directories.keys {
            try VZMultipleDirectoryShare.validateName(name)
        }
        #expect(share.directories.values.allSatisfy { !$0.isReadOnly })
    }

    @Test("a VM with no shares still gets the device, so shares can be added live")
    func emptyShareSetIsValid() throws {
        let device = SharedFolders.device(for: [])
        let share = try #require(device.share as? VZMultipleDirectoryShare)
        #expect(share.directories.isEmpty)
    }
}
