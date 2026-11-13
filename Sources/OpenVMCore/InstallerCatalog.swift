// InstallerCatalog — the systems openVM offers to install, compiled in so the host, the app and
// openvmctl agree. An entry never holds a download link: a Linux entry names the vendor's own index
// (resolved when a download starts, so a point release does not break it), and Windows only the page
// where Microsoft gives out its installer.
//
// Every entry is listed in the gallery (the owner's choice, 2026-11-13). `evidence` records which have a
// full install through openVM on record in docs/evidence, and which are listed without one.
import Foundation

public nonisolated enum InstallerCatalog {
    public enum Kind: String, Sendable { case linux, windows }

    /// Where a Linux installer comes from, at the vendor's own host over HTTPS.
    public enum Source: Equatable, Sendable {
        /// A release folder on cdimage.ubuntu.com, with `SHA256SUMS` beside the ISOs.
        case ubuntu(release: String)
        /// fedoraproject.org/releases.json, which lists each release's link, size and SHA-256.
        case fedora(variant: String)
        /// Only a page: the person downloads the file in their browser.
        case page
    }

    public struct Entry: Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String
        /// One line on what it is for.
        public let purpose: String
        public let kind: Kind
        public let source: Source
        /// Roughly how much is downloaded, for the tile. The real size comes from the vendor at download.
        public let downloadGB: Double
        /// Free space the Mac needs for the download and a new VM's disk.
        public let neededGB: Int
        /// "About 20 minutes", all told.
        public let time: String
        /// What does not work, or needs a step, said before anything is downloaded.
        public let limits: [String]
        /// The file under docs/evidence that records a full install through openVM. Nil: none is on record.
        public let evidence: String?
        /// The vendor's own download page: the way out when a download fails, and all there is for Windows.
        public let page: URL
        /// A neutral SF Symbol, for a system with no mark of its own (SystemBrand). Windows, Ubuntu and
        /// Fedora show their marks instead (the owner's choice).
        public let symbol: String

        public init(
            id: String, name: String, purpose: String, kind: Kind, source: Source, downloadGB: Double,
            neededGB: Int,
            time: String, limits: [String], evidence: String?, page: URL, symbol: String
        ) {
            self.id = id
            self.name = name
            self.purpose = purpose
            self.kind = kind
            self.source = source
            self.downloadGB = downloadGB
            self.neededGB = neededGB
            self.time = time
            self.limits = limits
            self.evidence = evidence
            self.page = page
            self.symbol = symbol
        }
    }

    public static let windowsPage = URL(
        string: "https://www.microsoft.com/en-us/software-download/windows11arm64")!

    public static let entries: [Entry] = [
        Entry(
            id: "ubuntu-lts", name: "Ubuntu", purpose: "The place to start with Linux.", kind: .linux,
            source: .ubuntu(release: "26.04"), downloadGB: 3.9, neededGB: 24, time: "About 20 minutes",
            limits: [
                "No sound until you add the PipeWire setting from openVM’s Help.",
                "The clipboard and files are not shared with the Mac yet.",
            ],
            evidence: "linux-iso-ubuntu-2026-11-13.md",
            page: URL(string: "https://ubuntu.com/download/desktop")!,
            symbol: "circle.hexagongrid"),
        Entry(
            id: "fedora-workstation", name: "Fedora Workstation",
            purpose: "The newest Linux desktop, updated often.",
            kind: .linux, source: .fedora(variant: "Workstation"), downloadGB: 3.0, neededGB: 24,
            time: "About 20 minutes",
            limits: [
                "No sound until you add the PipeWire setting from openVM’s Help.",
                "The clipboard and files are not shared with the Mac yet.",
            ],
            // No install on record: listed because Ubuntu, which installs the same way, works (the owner).
            evidence: nil, page: URL(string: "https://fedoraproject.org/workstation/download")!,
            symbol: "hexagon"),
        Entry(
            id: "windows-11", name: "Windows 11",
            purpose: "For Windows apps. You download it from Microsoft.",
            kind: .windows, source: .page, downloadGB: 5.5, neededGB: 42, time: "15 to 30 minutes to set up",
            limits: [
                "Windows asks for a licence. openVM does not include one.",
                "The picture can be wrong at some window sizes until Windows’ display driver is updated.",
            ],
            evidence: "windows-smoke-2026-11-06.txt", page: windowsPage, symbol: "macwindow"),
    ]

    public static func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }
}

/// What kind of installer a file is, decided before the wizard goes on.
public nonisolated struct InstallerVerdict: Equatable, Sendable {
    public let kind: InstallerCatalog.Kind
    /// Why it cannot be used: a code the app turns into plain words, and the technical text.
    public let code: String?
    public let problem: String?
    /// A Linux ISO whose boot files could not be read: it may or may not start, and is still offered.
    public let unknown: Bool

    public var usable: Bool { code == nil }

    public init(
        kind: InstallerCatalog.Kind, code: String? = nil, problem: String? = nil, unknown: Bool = false
    ) {
        self.kind = kind
        self.code = code
        self.problem = problem
        self.unknown = unknown
    }
}

public nonisolated enum InstallerIdentify {
    /// What the Windows check found: it could not open the file as a disc, or it did and gave a verdict
    /// (nil: a usable Windows 11 Arm installer).
    public enum WindowsLook: Equatable, Sendable {
        case unreadable
        case looked(MediaProblem?)
    }

    /// The Windows check runs first, because a Windows Arm ISO also holds the boot file the Linux check
    /// looks for. Only a file that is not Windows at all goes on to the Linux check.
    public static func verdict(
        windows: WindowsLook, sizeProblem: String?, linux: () -> LinuxISOCheck.Verdict
    ) -> InstallerVerdict {
        if case .looked(let problem) = windows, problem != .notWindows {
            guard let problem else { return InstallerVerdict(kind: .windows) }
            return InstallerVerdict(kind: .windows, code: code(for: problem), problem: problem.description)
        }
        if let sizeProblem {
            return InstallerVerdict(kind: .linux, code: "iso-incomplete", problem: sizeProblem)
        }
        let found = linux()
        if let problem = found.problem {
            return InstallerVerdict(kind: .linux, code: "linux-intel", problem: problem)
        }
        return InstallerVerdict(kind: .linux, unknown: found == .unknown)
    }

    public static func code(for problem: MediaProblem) -> String {
        switch problem {
        case .notWindows: return "not-windows"
        case .notArm64: return "windows-intel"
        case .noInstallWim, .onlyEsd: return "windows-no-image"
        }
    }
}
