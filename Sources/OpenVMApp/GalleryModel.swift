// GalleryModel — what the gallery offers: a place to drop or choose an installer file, and a tile for
// each system in the catalog. A tile says its cost and limits before anything is downloaded, and is off,
// with the reason, when the Mac lacks the space.
import Combine
import Foundation
import OpenVMCore

/// One system in the gallery.
struct GalleryTile: Equatable, Identifiable {
    let entry: InstallerCatalog.Entry
    /// Why it cannot be chosen now, or nil when it can.
    let disabledReason: String?

    var id: String { entry.id }

    /// "3.9 GB · About 20 minutes", for a short card.
    var shortCost: String {
        "\(entry.downloadGB.formatted(.number.precision(.fractionLength(0...1)))) GB · \(entry.time)"
    }

    /// "3.9 GB download · 24 GB free space needed · About 20 minutes"
    var cost: String {
        let download = entry.downloadGB.formatted(.number.precision(.fractionLength(0...1)))
        return "\(download) GB download · \(entry.neededGB) GB free space needed · \(entry.time)"
    }
}

/// A download under way, as a card in the gallery shows it.
struct GalleryDownload: Equatable {
    /// 0 to 1, or nil while the size is not known.
    let fraction: Double?
    /// "7.1 MB of 2.99 GB", "Paused at 120 MB", "Downloaded and checked".
    let text: String

    /// From the installer cache, as the library knows it: what is downloading, and what stopped part-way.
    static func from(_ installers: [InstallerRow]) -> [String: GalleryDownload] {
        var found: [String: GalleryDownload] = [:]
        for row in installers where !row.complete {
            let fraction = DownloadText.fraction(done: row.bytes, total: row.bytesTotal)
            found[row.entry] =
                row.downloading
                ? GalleryDownload(
                    fraction: fraction,
                    text: DownloadText.progress(done: row.bytes, total: row.bytesTotal, bytesPerSecond: 0))
                : GalleryDownload(fraction: fraction ?? 0, text: "Paused at \(DownloadText.size(row.bytes))")
        }
        return found
    }
}

/// What the gallery says about a file that was dropped or chosen.
enum GalleryFileStatus: Equatable {
    case none
    case checking(String)
    case usable(String)
    case failed(FailureMessage)
}

@MainActor
final class GalleryModel: ObservableObject {
    /// A file is being dragged over the drop area.
    @Published var dropTargeted = false
    /// The Mac's free space, once the host has said.
    @Published private(set) var freeDiskMB: UInt64?
    /// The technical text of a failure is on show.
    @Published var detailsShown = false

    private let transport: any HostTransport

    init(transport: any HostTransport) { self.transport = transport }

    func load() async {
        if let info = try? await transport.hostInfo() { freeDiskMB = info.freeDiskMB }
    }

    var tiles: [GalleryTile] {
        Self.tiles(InstallerCatalog.entries, freeDiskMB: freeDiskMB, canDownload: Self.canDownload)
    }

    /// Whether this build can download a Linux installer itself.
    static let canDownload = true

    /// The tiles to show: every system in the catalog. A Linux entry needs a build that can download it;
    /// Windows is always there, because its file comes from Microsoft's page. Which entries have an
    /// install on record is in the catalog (`evidence`); the owner chose to list them all (2026-11-13).
    nonisolated static func tiles(
        _ entries: [InstallerCatalog.Entry], freeDiskMB: UInt64?, canDownload: Bool
    ) -> [GalleryTile] {
        entries.compactMap { entry in
            if entry.kind == .linux, !canDownload { return nil }
            var reason: String?
            if let free = freeDiskMB, free < UInt64(entry.neededGB) * 1024 {
                reason = "Needs \(entry.neededGB) GB of free space. This Mac has \(free / 1024) GB."
            }
            return GalleryTile(entry: entry, disabledReason: reason)
        }
    }

    /// The first installer file among what was dropped. Anything else is not for the gallery.
    nonisolated static func installerFile(in urls: [URL]) -> URL? {
        urls.first { $0.isFileURL && $0.pathExtension.lowercased() == "iso" } ?? urls.first { $0.isFileURL }
    }
}

/// How the creation window is opened: on the gallery, with a file already chosen (dropped on the
/// library or the Dock icon, or from File ▸ Open Installer File…), or with a system already picked.
enum NewVMStart: Equatable {
    case gallery
    case file(URL)
    case system(InstallerCatalog.Kind)
    /// A download tile: the catalog entry's id.
    case entry(String)
}
