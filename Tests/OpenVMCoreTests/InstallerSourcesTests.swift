// Finding the installer for a catalog entry in the vendor's own index, and which addresses may be fetched.
import Foundation
import Testing

@testable import OpenVMCore

@Suite struct InstallerSourcesTests {
    private let a = String(repeating: "a", count: 64)
    private let b = String(repeating: "b", count: 64)
    private let c = String(repeating: "c", count: 64)
    private let folder = URL(string: "https://cdimage.ubuntu.com/ubuntu/releases/26.04/release/")!

    /// The file names are the ones the vendor's folder held on 2026-11-13 (docs/evidence/installer-sources).
    @Test func ubuntuTakesTheNewestPointReleaseOfTheDesktopImageForArm() {
        let sums = """
            \(a) *ubuntu-26.04-desktop-arm64.iso
            \(b) *ubuntu-26.04.1-desktop-arm64.iso
            \(c) *ubuntu-26.04.1-live-server-arm64.iso
            \(c) *ubuntu-26.04.1-live-server-arm64+largemem.iso
            """
        let found = InstallerSources.ubuntu(sums: sums, release: "26.04", folder: folder)
        #expect(found?.fileName == "ubuntu-26.04.1-desktop-arm64.iso")
        #expect(found?.sha256 == b)
        #expect(
            found?.url.absoluteString
                == "https://cdimage.ubuntu.com/ubuntu/releases/26.04/release/ubuntu-26.04.1-desktop-arm64.iso"
        )
    }

    @Test func ubuntuComparesPointReleasesAsNumbers() {
        let sums = "\(a) *ubuntu-26.04.9-desktop-arm64.iso\n\(b) *ubuntu-26.04.10-desktop-arm64.iso\n"
        #expect(InstallerSources.ubuntu(sums: sums, release: "26.04", folder: folder)?.sha256 == b)
    }

    @Test func ubuntuIgnoresOtherReleasesBadHashesAndStrangeNames() {
        let sums = """
            \(a) *ubuntu-26.10-desktop-arm64.iso
            nothex *ubuntu-26.04.2-desktop-arm64.iso
            \(b) *../ubuntu-26.04.3-desktop-arm64.iso
            \(c) *ubuntu-26.04-desktop-amd64.iso
            """
        #expect(InstallerSources.ubuntu(sums: sums, release: "26.04", folder: folder) == nil)
    }

    private func fedora(_ items: [[String: Any]]) -> ResolvedInstaller? {
        InstallerSources.fedora(
            json: try! JSONSerialization.data(withJSONObject: items), variant: "Workstation")
    }

    private func item(
        _ version: String, _ file: String, hash: String, arch: String = "aarch64", size: Any = "2987100160"
    ) -> [String: Any] {
        [
            "version": version, "arch": arch, "variant": "Workstation", "subvariant": "Workstation",
            "link":
                "https://download.fedoraproject.org/pub/fedora/linux/releases/\(version)/Workstation/\(arch)/iso/\(file)",
            "sha256": hash, "size": size,
        ]
    }

    @Test func fedoraTakesTheLiveIsoOfTheHighestNumberedRelease() {
        let found = fedora([
            item("44", "Fedora-Workstation-Live-44-1.7.aarch64.iso", hash: a),
            item("45", "Fedora-Workstation-Disk-45-1.4.aarch64.raw.xz", hash: c),
            item("45", "Fedora-Workstation-Live-45-1.4.aarch64.iso", hash: b),
            item("45 Beta", "Fedora-Workstation-Live-45-1.2.aarch64.iso", hash: c),
            item("46", "Fedora-Workstation-Live-46-1.1.x86_64.iso", hash: c, arch: "x86_64"),
        ])
        #expect(found?.fileName == "Fedora-Workstation-Live-45-1.4.aarch64.iso")
        #expect(found?.sha256 == b)
        #expect(found?.size == 2_987_100_160)
        #expect(found?.url.host == "download.fedoraproject.org")
    }

    @Test func fedoraReadsASizeGivenAsANumberAndRefusesAPlainHttpLink() {
        #expect(
            fedora([item("45", "Fedora-Workstation-Live-45-1.4.aarch64.iso", hash: a, size: 123)])?.size
                == 123)
        var plain = item("45", "Fedora-Workstation-Live-45-1.4.aarch64.iso", hash: a)
        plain["link"] = "http://mirror.example/Fedora-Workstation-Live-45-1.4.aarch64.iso"
        #expect(fedora([plain]) == nil)
        #expect(InstallerSources.fedora(json: Data("not json".utf8), variant: "Workstation") == nil)
    }

    /// The index comes from the vendor's own host over HTTPS, and nowhere else.
    @Test func onlyHttpsAndOnlyTheVendorsHostForAnIndex() {
        let ubuntu = InstallerSources.indexURL(for: .ubuntu(release: "26.04"))!
        #expect(
            ubuntu.absoluteString == "https://cdimage.ubuntu.com/ubuntu/releases/26.04/release/SHA256SUMS")
        #expect(InstallerSources.indexURL(for: .fedora(variant: "Workstation"))?.host == "fedoraproject.org")
        #expect(InstallerSources.indexURL(for: .page) == nil)
        #expect(InstallerSources.indexURL(for: .ubuntu(release: "../../x")) == nil)
        #expect(InstallerSources.allowed(ubuntu, host: "cdimage.ubuntu.com"))
        #expect(!InstallerSources.allowed(ubuntu, host: "evil.example"))
        #expect(!InstallerSources.allowed(URL(string: "http://cdimage.ubuntu.com/x")!))
        #expect(!InstallerSources.allowed(URL(string: "file:///etc/passwd")!))
        #expect(InstallerSources.allowed(URL(string: "https://mirror.example/a.iso")!))  // a mirror, for the file itself
    }

    @Test func aFileNameIsOnePlainNameEndingInIso() {
        #expect(InstallerSources.validFileName("ubuntu-26.04.1-desktop-arm64.iso"))
        #expect(InstallerSources.validFileName("ubuntu-26.04-live-server-arm64+largemem.iso"))
        #expect(!InstallerSources.validFileName("../a.iso"))
        #expect(!InstallerSources.validFileName("a/b.iso"))
        #expect(!InstallerSources.validFileName(".hidden.iso"))
        #expect(!InstallerSources.validFileName("a.img"))
        #expect(!InstallerSources.validFileName("a b.iso"))
    }

    /// Every Linux entry in the catalog has an index on its vendor's host.
    @Test func everyDownloadableEntryHasAnIndex() {
        for entry in InstallerCatalog.entries where entry.kind == .linux {
            let index = InstallerSources.indexURL(for: entry.source)
            #expect(index != nil, "\(entry.id)")
            #expect(index.map { InstallerSources.allowed($0) } == true, "\(entry.id)")
        }
    }
}

@Suite struct KaliSourceTests {
    private let a = String(repeating: "a", count: 64)
    private let b = String(repeating: "b", count: 64)
    private let folder = URL(string: "https://cdimage.kali.org/current/")!

    /// The names are the ones Kali's index held on 2026-11-14.
    @Test func kaliTakesTheFullInstallerForArmAndNoOtherImage() {
        let sums = """
            \(b)  kali-linux-2026.3-installer-amd64.iso
            \(a)  kali-linux-2026.3-installer-arm64.iso
            \(b)  kali-linux-2026.3-installer-arm64.iso.torrent
            \(b)  kali-linux-2026.3-installer-netinst-arm64.iso
            \(b)  kali-linux-2026.3-installer-everything-amd64.iso
            \(b)  kali-linux-2026.3-live-arm64.iso
            \(b)  kali-linux-2026.3-qemu-amd64.7z
            """
        let found = InstallerSources.kali(sums: sums, folder: folder)
        #expect(found?.fileName == "kali-linux-2026.3-installer-arm64.iso")
        #expect(found?.sha256 == a)
        #expect(
            found?.url.absoluteString
                == "https://cdimage.kali.org/current/kali-linux-2026.3-installer-arm64.iso")
        #expect(
            InstallerSources.kali(sums: "\(b)  kali-linux-2026.3-live-arm64.iso\n", folder: folder) == nil)
    }

    @Test func kaliTakesTheNewestReleaseIfTheIndexHoldsTwo() {
        let sums =
            "\(a)  kali-linux-2026.3-installer-arm64.iso\n\(b)  kali-linux-2026.10-installer-arm64.iso\n"
        #expect(InstallerSources.kali(sums: sums, folder: folder)?.sha256 == b)
    }

    /// Kali's index is on cdimage.kali.org, which hands the request to kali.download: both are Kali's own,
    /// and no other host is.
    @Test func kalisIndexMayComeFromItsTwoHostsOnly() {
        #expect(
            InstallerSources.indexURL(for: .kali)?.absoluteString
                == "https://cdimage.kali.org/current/SHA256SUMS")
        #expect(InstallerSources.indexHosts(for: .kali) == ["cdimage.kali.org", "kali.download"])
        #expect(InstallerSources.indexHosts(for: .ubuntu(release: "26.04")) == ["cdimage.ubuntu.com"])
        #expect(InstallerSources.indexHosts(for: .fedora(variant: "Workstation")) == ["fedoraproject.org"])
        #expect(InstallerCatalog.entry("kali")?.source == .kali)
    }
}
