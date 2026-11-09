// Is this ISO something openVM can build a Windows guest from? Decided from its file names alone,
// so the person is told at once, in words, instead of after a long build.
import Foundation
import Testing

@testable import OpenVMCore

@Suite struct WindowsMediaCheckTests {
    private let arm64: Set<String> = [
        "efi/boot/bootaa64.efi", "sources/boot.wim", "sources/install.wim", "setup.exe", "bootmgr",
    ]

    @Test func arm64IsoPasses() {
        #expect(WindowsMediaCheck.problem(files: arm64) == nil)
    }

    @Test func x64IsoIsRefused() {
        let x64: Set<String> = ["efi/boot/bootx64.efi", "sources/boot.wim", "sources/install.wim", "setup.exe"]
        #expect(WindowsMediaCheck.problem(files: x64) == .notArm64)
    }

    @Test func esdOnlyIsoIsReported() {
        let esd: Set<String> = ["efi/boot/bootaa64.efi", "sources/boot.wim", "sources/install.esd", "setup.exe"]
        #expect(WindowsMediaCheck.problem(files: esd) == .onlyEsd)
    }

    @Test func anIsoWithNoInstallImageIsReported() {
        let none: Set<String> = ["efi/boot/bootaa64.efi", "sources/boot.wim", "setup.exe"]
        #expect(WindowsMediaCheck.problem(files: none) == .noInstallWim)
    }

    @Test func randomIsoIsRefused() {
        let ubuntu: Set<String> = ["casper/vmlinuz", "casper/initrd", "boot/grub/grub.cfg", "efi/boot/bootaa64.efi"]
        #expect(WindowsMediaCheck.problem(files: ubuntu) == .notWindows)
        #expect(WindowsMediaCheck.problem(files: []) == .notWindows)
    }

    @Test func caseDoesNotMatter() {
        let shouting: Set<String> = ["EFI/BOOT/BOOTAA64.EFI", "SOURCES/BOOT.WIM", "SOURCES/INSTALL.WIM", "SETUP.EXE"]
        #expect(WindowsMediaCheck.problem(files: shouting) == nil)
    }

    @Test func everyProblemHasWordsForAPerson() {
        for problem in [MediaProblem.notWindows, .notArm64, .noInstallWim, .onlyEsd] {
            #expect(problem.description.count > 30, "\(problem)")
            #expect(!problem.description.contains("MediaProblem"))
        }
        #expect(MediaProblem.notArm64.description.contains("ARM64"))
        #expect(MediaProblem.onlyEsd.description.contains("install.esd"))
    }
}
