// SystemLogos — the marks shown beside a system: Windows drawn in code, Ubuntu and Fedora from their
// makers' own artwork, and a neutral glyph for anything else. They say what a tile installs and what a VM runs (the owner's choice,
// 2026-11-13). Each is its maker's trademark, and its usage rules are to be checked before a public
// release (docs/gui-notes.md).
import AppKit
import OpenVMCore
import SwiftUI

/// Which mark a system gets.
enum SystemBrand: Equatable {
    case windows, ubuntu, fedora, kali
    /// No mark of its own: a neutral SF Symbol.
    case other(String)

    /// For a catalog entry.
    static func of(_ entry: InstallerCatalog.Entry) -> SystemBrand {
        entry.kind == .windows ? .windows : named(entry.name) ?? .other(entry.symbol)
    }

    /// For a VM: Windows by its kind, a Linux by the name recorded when it was made (a catalog name such
    /// as "Ubuntu", or the installer file's name).
    static func of(_ vm: VmSummary) -> SystemBrand {
        if vm.bootMode == .windows { return .windows }
        return vm.systemName.flatMap(named) ?? .other("terminal")
    }

    /// For an installer in the cache, downloading or downloaded: its catalog entry's mark.
    static func of(_ installer: InstallerRow) -> SystemBrand {
        InstallerCatalog.entry(installer.entry).map(of) ?? named(installer.name) ?? .other("opticaldisc")
    }

    private static func named(_ name: String) -> SystemBrand? {
        let lower = name.lowercased()
        if lower.contains("ubuntu") { return .ubuntu }
        if lower.contains("fedora") { return .fedora }
        if lower.contains("kali") { return .kali }
        return nil
    }
}

/// A system's mark on a background, as an app icon has one: a rounded square that fills the square it is
/// given. Ubuntu's is its own orange; Windows and Fedora sit on white, which their marks are made for. So
/// the three read as one set, in light and in dark. A system with no mark of its own is a plain glyph.
struct SystemLogo: View {
    let brand: SystemBrand

    /// How far a mark is set in from the edge of its background, as a share of the side.
    static func inset(for brand: SystemBrand) -> CGFloat {
        switch brand {
        case .windows: return 0.2
        case .fedora: return 0.11
        case .kali: return 0.04
        case .ubuntu, .other: return 0  // Ubuntu's artwork is its background
        }
    }

    var body: some View {
        switch brand {
        case .windows: plate(WindowsLogo(), fill: .white)
        case .ubuntu: plate(UbuntuLogo(), fill: Color(red: 0.914, green: 0.314, blue: 0.055))
        case .fedora: plate(FedoraLogo(), fill: .white)
        // Kali's dragon is white and reaches past its blue disc, so it sits on a dark ground.
        case .kali: plate(KaliLogo(), fill: Color(red: 0.07, green: 0.09, blue: 0.15))
        case .other(let symbol):
            GeometryReader { proxy in
                Image(systemName: symbol).font(.system(size: min(proxy.size.width, proxy.size.height) * 0.8))
                    .foregroundStyle(.secondary).frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }
}

extension SystemLogo {
    private func plate<Mark: View>(_ mark: Mark, fill: Color) -> some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let shape = RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
            mark.padding(side * Self.inset(for: brand))
                .frame(width: side, height: side)
                .background(fill)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.black.opacity(0.12), lineWidth: max(0.5, side / 64)))
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

/// The Windows mark: four squares in Windows blue.
struct WindowsLogo: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let gap = side * 0.06
            let square = (side - gap) / 2
            VStack(spacing: gap) {
                ForEach(0..<2, id: \.self) { _ in
                    HStack(spacing: gap) {
                        ForEach(0..<2, id: \.self) { _ in
                            Rectangle().fill(Color(red: 0, green: 0.47, blue: 0.83)).frame(
                                width: square, height: square)
                        }
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

/// The makers' own artwork for the Ubuntu and Fedora marks, kept here as SVG text so the app needs no
/// resource files (its bundle is put together by hand, and the tests have no bundle at all).
///
/// * Ubuntu: Canonical's Circle of Friends, https://assets.ubuntu.com/v1/5924f0b8-CoF-2022.svg (fetched
///   2026-11-13). The file is a tall orange tag; only its `viewBox` is changed, to show the square that
///   holds the mark.
/// * Fedora: the mark from the Fedora design team's `fedora_default-vertical.svg`,
///   https://gitlab.com/fedora/design/team/logos/fedora-project-logos (fetched 2026-11-13): the logo's
///   own path and transforms, without the wordmark, on a white disc so the "f" stays white on any
///   background.
///
/// * Kali: the dragon mark from Kali's own `kali-dragon-icon.svg`, https://www.kali.org/images/ (fetched
///   2026-11-14): the file's blue disc and white dragon, with their own transforms, without its blurred glow
///   and shadow layers, which do not draw cleanly at the sizes used here.
///
/// All are trademarks of their makers. Their usage rules are to be checked before a public release.
enum OfficialArtwork {
    static let ubuntu = #"""
        <svg id="Layer_1" data-name="Layer 1" xmlns="http://www.w3.org/2000/svg" viewBox="0 561.09509 1038.90491 1038.90491"><defs><style>.cls-1{fill:#e9500e;}.cls-2{fill:#fff;}</style></defs><rect class="cls-1" width="1038.90491" height="1600"/><circle class="cls-2" cx="226.58835" cy="1056.07411" r="109.02696"/><circle class="cls-2" cx="680.64509" cy="817.00695" r="109.02696"/><path class="cls-2" d="M472.48179,1336.66575a265.525,265.525,0,0,1-181.07121-138.09821,156.94811,156.94811,0,0,1-93.21911,11.45831,354.9352,354.9352,0,0,0,255.53721,214.16456,359.21054,359.21054,0,0,0,77.41948,7.967,156.00315,156.00315,0,0,1-31.92236-91.15471C490.24607,1340.00523,481.27719,1338.548,472.48179,1336.66575Z" transform="translate(0)"/><circle class="cls-2" cx="656.08182" cy="1337.26719" r="109.02696"/><path class="cls-2" d="M807.7978,1297.22089A356.70056,356.70056,0,0,0,825.67268,878.702a157.14405,157.14405,0,0,1-61.30976,71.80309,267.293,267.293,0,0,1-8.73685,265.48842A156.34662,156.34662,0,0,1,807.7978,1297.22089Z" transform="translate(0)"/><path class="cls-2" d="M218.17628,899.71905q4.1505-.2277,8.30533-.22553A157.3464,157.3464,0,0,1,309.164,923.039,265.90648,265.90648,0,0,1,523.2722,808.52964a158.08773,158.08773,0,0,1,33.076-88.42024C419.24532,709.25176,286.02405,780.001,218.17628,899.71905Z" transform="translate(0)"/></svg>
        """#

    static let fedora = #"""
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="30.95 15.55 39.6 39.6"><circle cx="50.75" cy="35.35" r="17.8" fill="#ffffff"/><g transform="translate(-550)"><g transform="matrix(1.1600518,0,0,1.1600518,654.47677,-112.84527)"><path fill="#51a2da" d="m -46.297501,110.68027 c -9.409465,0 -17.035254,7.62317 -17.041392,17.03049 h -0.0033 v 13.19147 h 0.0033 c 0.0033,2.13569 1.734951,3.86445 3.871731,3.86445 h 0.01859 0.0033 13.155147 c 9.410518,-0.005 17.034119,-7.63167 17.034119,-17.0414 0,-9.4137 -7.627665,-17.04501 -17.041376,-17.04501 z m 3.454039,7.0134 c 2.862013,0 5.564243,2.19299 5.564243,5.21559 0,0.28031 -0.0014,0.56098 -0.04723,0.87894 -0.07915,0.80419 -0.812415,1.38091 -1.61262,1.26756 -0.800171,-0.11469 -1.342977,-0.87224 -1.194926,-1.66709 0.01316,-0.0908 0.01859,-0.23457 0.01859,-0.47941 0,-1.71374 -1.401445,-2.37534 -2.727621,-2.37534 -1.325402,0 -2.521086,1.11449 -2.524262,2.37534 0.02287,1.45848 0,2.90649 0,4.36203 l 2.458868,-0.0186 c 1.920471,-0.0398 1.941995,2.85491 0.02172,2.84022 l -2.480671,0.0186 c -0.0083,1.17308 0.0099,0.96006 0.0033,1.55086 0,0 0.02122,1.43289 -0.02172,2.52063 -0.296877,3.19461 -3.015923,5.74945 -6.283371,5.74945 -3.463237,0 -6.319706,-2.8334 -6.319706,-6.30516 0.104,-3.57153 2.954791,-6.37845 6.541248,-6.34511 l 1.997599,-0.0148 v 2.83659 l -1.997599,0.0186 h -0.01481 c -1.971155,0.0581 -3.657825,1.39399 -3.690111,3.50487 0,1.9234 1.554366,3.46496 3.483082,3.46496 1.925524,0 3.464932,-1.40243 3.464932,-3.46131 0.02188,-3.41443 -0.01481,-7.18616 -0.0033,-10.73259 0.0011,-0.19925 0.01152,-0.3577 0.03274,-0.57748 0.325147,-2.6257 2.673827,-4.6272 5.331808,-4.6272 z"/></g></g></svg>
        """#

    static let kali = #"""
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 -41.945 451.14 451.14"><defs><linearGradient id="e" x1="165.32" x2="320.01" y1="151.05" y2="300.71" gradientUnits="userSpaceOnUse"><stop stop-color="#23bac2" offset="0"/><stop stop-color="#2777ff" offset="1"/></linearGradient></defs><g transform="translate(-4.7508 -89.176)"><circle cx="282.31" cy="262.76" r="125.42" fill="url(#e)"/></g><g transform="translate(11.028 -89.023)" fill="#fff"><path d="m69.929 127.71c-29.464.0337-48.949 2.4206-48.949 2.4206s107.73-5.1706 194.03 29.769c2.9338 13.122 11.759 34.976 16.513 45.481-13.602 9.4041-28.94 18.249-31.328 49.612-2.3877 31.362 24.576 58.947 58.013 59.798 31.751 1.6913 53.688 1.9323 80.277 15.718 25.38 14.034 46.192 56.794 48.251 95.252 2.2244-28.534-8.4845-89.895-58.453-108.53 69.826 12.219 75.982 63.973 75.984 63.994 0 0 5.2056-59.754-88.677-73.531-11.899-1.7458-26.947-3.0899-42.168-3.1283-75.246.99487-77.989-86.786-21.288-91.218 23.499-1.9389 51.556 10.738 78.986 23.512-.10182 3.4068.0404 6.4339 2.2787 9.2314 2.2375 2.7966 10.832 5.8474 13.579 7.4233 2.7464 1.5764 11.545 7.1715 16.937 14.189 1.1692-2.1872 10.933-8.5432 10.933-8.5432s-2.3391.0507-7.781-1.9832c-5.4426-2.0339-11.9-8.1876-12.053-8.5432-.15246-.35625-.25501-.91601 1.0169-1.1705.96572-.81305-1.2209-3.4575-2.1873-4.4232-.96572-.96636-7.4247-11.95-7.5769-12.204-.15245-.25447-.20376-.50931-.66105-.81465-1.4244-.45805-7.6799.66106-7.6799.66106s-9.6211-4.7252-12.937-14.913c.0482 1.7844-1.6497 3.734 0 7.8335-5.0162-2.122-9.325-5.7416-12.723-14.685-2.0227 5.0868 0 8.3215 0 8.3215s-11.811-3.3016-13.701-14.195c-2.0742 4.8902 0 7.8316 0 7.8316s-19.258-10.048-51.255-10.194c-21.422-1.965-25.882-39.65-23.897-45.994 0 0-30.899-16.285-91.723-23.479-22.809-2.6982-44.081-3.5238-61.76-3.5036zm71.276 32.521c-9.2697.0699-19.22.41577-29.674 1.1588-55.751 3.9628-112.04 23.477-112.04 23.477s115.18-28.98 211.77-11.971h.002l-2.512-8.1057s-27.373-4.5594-67.542-4.5594zm68.293 17.263c-9.75-.0412-40.02 1.1848-85.564 15.436-57.124 17.874-89.522 43.21-89.522 43.21s85.141-47.539 181.24-50.24l-2.7492-8.3176s-1.1564-.0779-3.4064-.0875zm62.559-.13932c26.38 10.723 49.34 24.931 67.165 44.514l.002.002 4.2794-.27998s-24.518-29.746-71.446-44.236zm74.662 61.731c.85796.17286 2.4779 3.3567 3.9644 5.6306.13054.18477.26356.38112.38886.53662.002.0138.003.0234.006.037.16796.23967.33693.4887.49774.68826.0812.47558.21641.76558-.89631.53663-.0936-.48886-.25471-.62995-.25471-.62995s-2.686-1.5982-3.5094-2.7317c-.82408-1.1335-.96948-3.1153-.56774-3.8672.0978-.16967.2236-.23004.37137-.20027z"/></g></svg>
        """#

    static let ubuntuImage = NSImage(data: Data(ubuntu.utf8))
    static let kaliImage = NSImage(data: Data(kali.utf8))
    static let fedoraImage = NSImage(data: Data(fedora.utf8))
}

/// The Ubuntu mark: Canonical's Circle of Friends.
struct UbuntuLogo: View {
    var body: some View { ArtworkView(image: OfficialArtwork.ubuntuImage, fallback: "circle.hexagongrid") }
}

/// The Kali mark: the dragon.
struct KaliLogo: View {
    var body: some View { ArtworkView(image: OfficialArtwork.kaliImage, fallback: "shield") }
}

/// The Fedora mark.
struct FedoraLogo: View {
    var body: some View { ArtworkView(image: OfficialArtwork.fedoraImage, fallback: "hexagon") }
}

/// Draws artwork to fill its square, or a neutral glyph if the artwork could not be read.
private struct ArtworkView: View {
    let image: NSImage?
    let fallback: String

    var body: some View {
        if let image {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: fallback).resizable().aspectRatio(contentMode: .fit).foregroundStyle(.secondary)
        }
    }
}
