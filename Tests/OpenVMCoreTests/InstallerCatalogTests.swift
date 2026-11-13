// The catalog of systems openVM offers, and telling what kind of installer a file is.
import Foundation
import Testing

@testable import OpenVMCore

@Suite struct InstallerCatalogTests {
    @Test func everyEntryIsComplete() {
        #expect(!InstallerCatalog.entries.isEmpty)
        #expect(Set(InstallerCatalog.entries.map(\.id)).count == InstallerCatalog.entries.count)
        for entry in InstallerCatalog.entries {
            #expect(!entry.name.isEmpty && !entry.purpose.isEmpty && !entry.time.isEmpty, "\(entry.id)")
            #expect(entry.downloadGB > 0 && entry.neededGB > Int(entry.downloadGB), "\(entry.id)")
            #expect(entry.page.scheme == "https", "\(entry.id)")
            #expect(!entry.limits.isEmpty, "\(entry.id): every system has something to say up front")
            #expect(InstallerCatalog.entry(entry.id) == entry)
        }
    }

    /// The screens say Ubuntu and Windows 11, not ARM64, aarch64 or UEFI, and never "test-signed".
    @Test func tilesUsePlainWords() {
        for entry in InstallerCatalog.entries {
            let text = ([entry.name, entry.purpose, entry.time] + entry.limits).joined(separator: " ")
                .lowercased()
            for word in ["arm64", "aarch64", "uefi", "test-signed", "test mode", "iso"] {
                #expect(!text.contains(word), "\(entry.id) says \(word)")
            }
        }
    }

    /// Windows comes only from Microsoft's page: openVM never fetches it.
    @Test func windowsIsAPageOnly() {
        let windows = InstallerCatalog.entry("windows-11")
        #expect(windows?.source == .page)
        #expect(windows?.page.host == "www.microsoft.com")
        #expect(InstallerCatalog.entries.filter { $0.kind == .windows }.count == 1)
    }

    /// A listed entry's evidence file exists in docs/evidence.
    @Test func evidenceNamesARealFile() {
        let docs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/evidence")
        for entry in InstallerCatalog.entries {
            guard let evidence = entry.evidence else { continue }
            #expect(
                FileManager.default.fileExists(atPath: docs.appendingPathComponent(evidence).path),
                "\(entry.id)")
        }
    }
}

@Suite struct InstallerIdentifyTests {
    private func verdict(
        _ windows: InstallerIdentify.WindowsLook, size: String? = nil, linux: LinuxISOCheck.Verdict = .usable
    ) -> InstallerVerdict {
        InstallerIdentify.verdict(windows: windows, sizeProblem: size, linux: { linux })
    }

    /// A Windows Arm installer also holds the boot file the Linux check looks for, so it must never
    /// reach that check.
    @Test func aWindowsInstallerIsWindowsWhateverTheLinuxCheckWouldSay() {
        var askedLinux = false
        let found = InstallerIdentify.verdict(windows: .looked(nil), sizeProblem: nil) {
            askedLinux = true
            return .usable
        }
        #expect(found == InstallerVerdict(kind: .windows))
        #expect(found.usable)
        #expect(!askedLinux)
    }

    @Test func aWindowsInstallerForIntelIsRefusedAsWindows() {
        let found = verdict(.looked(.notArm64))
        #expect(found.kind == .windows)
        #expect(found.code == "windows-intel")
        #expect(!found.usable)
        #expect(verdict(.looked(.onlyEsd)).code == "windows-no-image")
        #expect(verdict(.looked(.noInstallWim)).code == "windows-no-image")
    }

    @Test func aFileThatIsNotWindowsGoesToTheLinuxCheck() {
        #expect(verdict(.looked(.notWindows)) == InstallerVerdict(kind: .linux))
        // Most Linux ISOs are hybrids macOS cannot open as a disc at all.
        #expect(verdict(.unreadable) == InstallerVerdict(kind: .linux))
        #expect(verdict(.unreadable, linux: .x86Only).code == "linux-intel")
        #expect(verdict(.unreadable, linux: .unknown) == InstallerVerdict(kind: .linux, unknown: true))
        #expect(verdict(.unreadable, linux: .unknown).usable)
    }

    @Test func aCutOffFileIsIncomplete() {
        let found = verdict(.unreadable, size: "This ISO looks incomplete")
        #expect(found.code == "iso-incomplete")
        #expect(found.kind == .linux)
    }
}
