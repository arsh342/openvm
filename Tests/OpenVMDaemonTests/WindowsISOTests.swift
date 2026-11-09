// Looking inside a Windows ISO the user chose: the path is checked, the ISO is mounted
// read-only, a few file names are read, and it is detached again.
import Foundation
import OpenVMCore
import Testing

@testable import OpenVMHost

nonisolated struct WindowsISOTests {
    /// A scratch directory holding a tree of empty files.
    private func tree(_ files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iso-tree-\(UUID().uuidString)")
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        return root
    }

    /// A real ISO file made from a tree, as a Windows ISO is: read back through a real mount.
    private func makeISO(_ files: [String]) throws -> (iso: URL, cleanup: () -> Void) {
        let source = try tree(files)
        let iso = FileManager.default.temporaryDirectory.appendingPathComponent("fake-\(UUID().uuidString).iso")
        let make = Process()
        make.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        make.arguments = ["makehybrid", "-iso", "-joliet", "-udf", "-o", iso.path, source.path]
        make.standardOutput = FileHandle.nullDevice
        make.standardError = FileHandle.nullDevice
        try make.run()
        make.waitUntilExit()
        #expect(make.terminationStatus == 0, "hdiutil makehybrid failed")
        return (iso, {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: iso)
        })
    }

    @Test func listingNamesTheFilesTheVerdictNeeds() throws {
        let root = try tree(["EFI/BOOT/BOOTAA64.EFI", "sources/install.wim", "sources/boot.wim", "setup.exe", "other/deep/file"])
        defer { try? FileManager.default.removeItem(at: root) }
        let files = windowsMediaFiles(at: root)
        #expect(files.contains("efi/boot/bootaa64.efi"))  // any letter case on disk, lower case here
        #expect(files.contains("sources/install.wim"))
        #expect(files.contains("setup.exe"))
        #expect(!files.contains("other/deep/file"))  // only the places the verdict looks
    }

    @Test func aMissingDirectoryIsSimplyAbsent() throws {
        let root = try tree(["readme.txt"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(windowsMediaFiles(at: root) == ["readme.txt"])
    }

    @Test func onlyARealIsoFileIsAccepted() throws {
        let fake = FileManager.default.temporaryDirectory.appendingPathComponent("not-an-iso-\(UUID().uuidString).txt")
        try Data("hi".utf8).write(to: fake)
        defer { try? FileManager.default.removeItem(at: fake) }
        for path in ["/etc/passwd", "relative.iso", "/no/such/file.iso", "/tmp", fake.path, "", "x.iso; rm -rf /", "/etc/hosts.iso"] {
            guard case .failure = validISOPath(path) else {
                Issue.record("\(path.debugDescription) was accepted")
                continue
            }
        }
    }

    @Test func aRealIsoPathIsAccepted() throws {
        let (iso, cleanup) = try makeISO(["efi/boot/bootaa64.efi"])
        defer { cleanup() }
        guard case .success(let url) = validISOPath(iso.path) else {
            Issue.record("a real ISO was refused")
            return
        }
        #expect(url.path == iso.path)
    }

    @Test func anArm64WindowsIsoIsUsable() throws {
        let (iso, cleanup) = try makeISO(["efi/boot/bootaa64.efi", "sources/boot.wim", "sources/install.wim", "setup.exe"])
        defer { cleanup() }
        #expect(try inspectWindowsISO(iso) == nil)
    }

    @Test func anX64IsoIsRefusedWithItsReason() throws {
        let (iso, cleanup) = try makeISO(["efi/boot/bootx64.efi", "sources/boot.wim", "sources/install.wim", "setup.exe"])
        defer { cleanup() }
        #expect(try inspectWindowsISO(iso) == .notArm64)
    }

    @Test func anIsoWithoutAWindowsImageIsRefused() throws {
        let (iso, cleanup) = try makeISO(["efi/boot/bootaa64.efi", "sources/boot.wim", "setup.exe"])
        defer { cleanup() }
        #expect(try inspectWindowsISO(iso) == .noInstallWim)
    }

    /// Mounting must not leave the ISO attached: a stuck mount keeps a multi-gigabyte file busy.
    @Test func theIsoIsDetachedAfterwards() throws {
        let (iso, cleanup) = try makeISO(["efi/boot/bootaa64.efi", "sources/install.wim", "setup.exe"])
        defer { cleanup() }
        _ = try inspectWindowsISO(iso)
        let info = Process()
        info.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        info.arguments = ["info"]
        let out = Pipe()
        info.standardOutput = out
        try info.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        info.waitUntilExit()
        #expect(!text.contains(iso.lastPathComponent), "\(iso.lastPathComponent) is still attached")
    }

    @Test func theOpAnswersForAGoodAndABadIso() throws {
        let (good, cleanupGood) = try makeISO(["efi/boot/bootaa64.efi", "sources/boot.wim", "sources/install.wim", "setup.exe"])
        defer { cleanupGood() }
        func answer(_ path: String) -> (status: String, result: [(key: String, value: CBOR)]) {
            let reply = vmOp("windows-iso-check", [("iso", .text(path))], Envelope(type: .vmRequest, correlationId: 2))
            guard case .map(let body) = reply.body,
                case .text(let status)? = body.first(where: { $0.key == "status" })?.value,
                case .map(let result)? = body.first(where: { $0.key == "result" })?.value
            else { return ("?", []) }
            return (status, result)
        }
        let ok = answer(good.path)
        #expect(ok.status == "ok")
        #expect(ok.result.contains { $0.key == "usable" && $0.value == .bool(true) })
        let bad = answer("/etc/passwd")
        #expect(bad.status == "error")
    }
}
