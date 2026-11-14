// InstallerSources — finding the file to download for a catalog entry, from the vendor's own index.
//
// Nothing here holds a link to an installer. Ubuntu publishes `SHA256SUMS` beside its images, and Fedora
// publishes `releases.json` with each release's link, size and SHA-256; both are read when a download
// starts, so a point release or a new Fedora does not break the entry. The index must come from the
// vendor's own host over HTTPS. The installer itself may come from a mirror the vendor redirects to,
// because it is checked against the hash from that index before it is ever used.
//
// What this does not do: check the vendor's signature on the index. It trusts HTTPS to the vendor's host.
import Foundation

/// The file a catalog entry resolves to, today.
public nonisolated struct ResolvedInstaller: Equatable, Sendable {
    public let url: URL
    public let fileName: String
    /// Lower-case hex, 64 characters.
    public let sha256: String
    /// In bytes, when the index says.
    public let size: UInt64?

    public init(url: URL, fileName: String, sha256: String, size: UInt64?) {
        self.url = url
        self.fileName = fileName
        self.sha256 = sha256
        self.size = size
    }
}

public nonisolated enum InstallerSources {
    /// The vendor's index for a source, or nil for one that is only a page.
    public static func indexURL(for source: InstallerCatalog.Source) -> URL? {
        switch source {
        case .ubuntu(let release):
            guard release.allSatisfy({ $0.isNumber || $0 == "." }), !release.isEmpty else { return nil }
            return URL(string: "https://cdimage.ubuntu.com/ubuntu/releases/\(release)/release/SHA256SUMS")
        case .fedora: return URL(string: "https://fedoraproject.org/releases.json")
        case .kali: return URL(string: "https://cdimage.kali.org/current/SHA256SUMS")
        case .page: return nil
        }
    }

    /// The hosts a source's index may come from: the vendor's own, and nowhere else. An index that
    /// redirects is followed only to another of these. Kali has two: `cdimage.kali.org` hands every request
    /// to its own download host, `kali.download`.
    public static func indexHosts(for source: InstallerCatalog.Source) -> [String] {
        switch source {
        case .ubuntu: return ["cdimage.ubuntu.com"]
        case .fedora: return ["fedoraproject.org"]
        case .kali: return ["cdimage.kali.org", "kali.download"]
        case .page: return []
        }
    }

    /// Whether an address may be fetched: HTTPS only. `host`, when given, must be exactly the address's
    /// host: the index comes from the vendor and nowhere else.
    public static func allowed(_ url: URL, host: String? = nil) -> Bool {
        guard url.scheme == "https", let found = url.host, !found.isEmpty else { return false }
        return host == nil || host == found
    }

    public static func validSHA256(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isHexDigit }
    }

    /// A file name the host will write: one plain name, ending in .iso, with nothing that names another place.
    public static func validFileName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 128, name.lowercased().hasSuffix(".iso"), !name.hasPrefix(".")
        else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || "._-+".contains($0) }
    }

    /// Resolves an entry from its index. Nil when the index names no installer for this Mac.
    public static func resolve(_ source: InstallerCatalog.Source, index: Data, indexURL: URL)
        -> ResolvedInstaller?
    {
        switch source {
        case .ubuntu(let release):
            guard let text = String(data: index, encoding: .utf8) else { return nil }
            return ubuntu(sums: text, release: release, folder: indexURL.deletingLastPathComponent())
        case .fedora(let variant): return fedora(json: index, variant: variant)
        case .kali:
            guard let text = String(data: index, encoding: .utf8) else { return nil }
            return kali(sums: text, folder: indexURL.deletingLastPathComponent())
        case .page: return nil
        }
    }

    /// `SHA256SUMS` lists "<hash> *<file>". The desktop image for Arm is `ubuntu-<version>-desktop-arm64.iso`;
    /// a release folder holds every point release, and the newest is taken.
    static func ubuntu(sums: String, release: String, folder: URL) -> ResolvedInstaller? {
        var best: (version: [Int], name: String, hash: String)?
        for line in sums.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let hash = parts[0].lowercased()
            let name = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " *"))
            guard validSHA256(hash), validFileName(name), name.hasPrefix("ubuntu-"),
                name.hasSuffix("-desktop-arm64.iso")
            else { continue }
            let version = String(name.dropFirst("ubuntu-".count).dropLast("-desktop-arm64.iso".count))
            guard version == release || version.hasPrefix(release + ".") else { continue }
            let numbers = version.split(separator: ".").map { Int($0) ?? -1 }
            guard !numbers.contains(-1) else { continue }
            if best == nil
                || numbers.lexicographicallyPrecedes(best!.version) == false && numbers != best!.version
            {
                best = (numbers, name, hash)
            }
        }
        guard let best else { return nil }
        return ResolvedInstaller(
            url: folder.appendingPathComponent(best.name), fileName: best.name, sha256: best.hash, size: nil)
    }

    /// Kali's `SHA256SUMS` lists "<hash>  <file>" for every image of the current release. The one for a
    /// Mac is `kali-linux-<version>-installer-arm64.iso`: the full installer, which needs no network to
    /// install, and not the netinst, everything, purple or live images.
    static func kali(sums: String, folder: URL) -> ResolvedInstaller? {
        var best: (version: [Int], name: String, hash: String)?
        for line in sums.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let hash = parts[0].lowercased()
            let name = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " *"))
            guard validSHA256(hash), validFileName(name), name.hasPrefix("kali-linux-"),
                name.hasSuffix("-installer-arm64.iso")
            else { continue }
            let version = String(name.dropFirst("kali-linux-".count).dropLast("-installer-arm64.iso".count))
            // "2026.3", or "2026.3a" for a respin: digits and dots, with at most a letter at the end.
            let numbers = version.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? -1 }
            guard !numbers.isEmpty, !numbers.contains(-1),
                version.allSatisfy({ $0.isNumber || $0 == "." || $0.isLetter })
            else { continue }
            if best == nil || (numbers != best!.version && !numbers.lexicographicallyPrecedes(best!.version))
            {
                best = (numbers, name, hash)
            }
        }
        guard let best else { return nil }
        return ResolvedInstaller(
            url: folder.appendingPathComponent(best.name), fileName: best.name, sha256: best.hash, size: nil)
    }

    /// `releases.json` is a list of files, each with `version`, `arch`, `variant`, `link`, `sha256` and
    /// `size`. The Live ISO for Arm of the highest numbered release is taken; a Beta is never.
    static func fedora(json: Data, variant: String) -> ResolvedInstaller? {
        guard let list = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else { return nil }
        var best: (version: Int, installer: ResolvedInstaller)?
        for item in list {
            guard item["arch"] as? String == "aarch64", item["variant"] as? String == variant,
                let versionText = item["version"] as? String, let version = Int(versionText),
                let link = item["link"] as? String, let url = URL(string: link), allowed(url),
                let hash = (item["sha256"] as? String)?.lowercased(), validSHA256(hash)
            else { continue }
            let name = url.lastPathComponent
            guard validFileName(name) else { continue }
            let size =
                (item["size"] as? String).flatMap(UInt64.init) ?? (item["size"] as? NSNumber)?.uint64Value
            if best == nil || version > best!.version {
                best = (version, ResolvedInstaller(url: url, fileName: name, sha256: hash, size: size))
            }
        }
        return best?.installer
    }
}
