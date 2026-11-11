// Installing any ARM64 Linux from its own ISO: what the checks decide, without touching a disk image.
import Foundation
import Testing

@testable import OpenVMCore

@Suite struct LinuxISOCheckTests {
    @Test func anArm64BootFileIsUsableInAnyCase() {
        #expect(LinuxISOCheck.verdict(efiBootFiles: ["bootaa64.efi", "grubaa64.efi"]) == .usable)
        #expect(LinuxISOCheck.verdict(efiBootFiles: ["BOOTAA64.EFI"]) == .usable)
    }

    @Test func anX86OnlyIsoIsRefusedWithTheReason() {
        let verdict = LinuxISOCheck.verdict(efiBootFiles: ["BOOTX64.EFI", "grubx64.efi"])
        #expect(verdict == .x86Only)
        #expect(verdict.problem?.contains("ARM64") == true)
    }

    @Test func anIsoWithBothIsUsable() {
        #expect(LinuxISOCheck.verdict(efiBootFiles: ["BOOTX64.EFI", "BOOTAA64.EFI"]) == .usable)
    }

    /// Finding neither name is not a reason to refuse an ISO: it may still boot.
    @Test func noBootFilesToSeeIsUnknownNotRefused() {
        #expect(LinuxISOCheck.verdict(efiBootFiles: []) == .unknown)
        #expect(LinuxISOCheck.Verdict.unknown.problem == nil)
    }
}

@Suite struct LinuxISOBootModeTests {
    @Test func onlyAWindowsGuestHasTheAgent() {
        #expect(BootMode.windows.hasAgent)
        #expect(!BootMode.linuxISO.hasAgent)
        #expect(!BootMode.alpine.hasAgent)  // it never runs, so it has nothing to offer
    }

    @Test func aRecordKeepsItsBootMode() throws {
        #expect(BootMode(rawValue: "linux-iso") == .linuxISO)
        let data = try JSONEncoder().encode(BootMode.linuxISO)
        #expect(try JSONDecoder().decode(BootMode.self, from: data) == .linuxISO)
    }

    @Test func aRowSaysWhetherTheInstallerIsAttached() {
        let base: [(key: String, value: CBOR)] = [
            ("name", .text("w")), ("state", .text("stopped")), ("uuid", .text("u")), ("bootMode", .text("linux-iso")),
        ]
        #expect(VmSummary(row: .map(base))?.installerAttached == false)
        #expect(VmSummary(row: .map(base + [("installerAttached", .bool(true))]))?.installerAttached == true)
    }
}

@Suite struct LinuxISOSizeTests {
    /// The framework refuses a disk image that is not whole sectors, with a message about its format.
    @Test func anIsoCutOffPartWayIsCalledThat() {
        #expect(LinuxISOCheck.sizeProblem(bytes: 338_047_968)?.contains("incomplete") == true)
        #expect(LinuxISOCheck.sizeProblem(bytes: 0)?.contains("incomplete") == true)
    }

    @Test func wholeSectorsAreFine() {
        #expect(LinuxISOCheck.sizeProblem(bytes: 92_743_680) == nil)
    }
}
