// SystemLogos — the marks shown beside a system: Windows drawn in code, Ubuntu and Fedora from their
// makers' own artwork, and a neutral glyph for anything else. They say what a tile installs and what a VM runs (the owner's choice,
// 2026-11-13). Each is its maker's trademark, and its usage rules are to be checked before a public
// release (docs/gui-notes.md).
import AppKit
import OpenVMCore
import SwiftUI

/// Which mark a system gets.
enum SystemBrand: Equatable {
    case windows, ubuntu, fedora
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

    private static func named(_ name: String) -> SystemBrand? {
        let lower = name.lowercased()
        if lower.contains("ubuntu") { return .ubuntu }
        if lower.contains("fedora") { return .fedora }
        return nil
    }
}

/// A system's mark, filling the square it is given.
struct SystemLogo: View {
    let brand: SystemBrand

    var body: some View {
        switch brand {
        case .windows: WindowsLogo()
        case .ubuntu: UbuntuLogo()
        case .fedora: FedoraLogo()
        case .other(let symbol):
            GeometryReader { proxy in
                Image(systemName: symbol).font(.system(size: min(proxy.size.width, proxy.size.height) * 0.8))
                    .foregroundStyle(.secondary).frame(width: proxy.size.width, height: proxy.size.height)
            }
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
/// Both are trademarks of their makers. Their usage rules are to be checked before a public release.
enum OfficialArtwork {
    static let ubuntu = #"""
        <svg id="Layer_1" data-name="Layer 1" xmlns="http://www.w3.org/2000/svg" viewBox="0 561.09509 1038.90491 1038.90491"><defs><style>.cls-1{fill:#e9500e;}.cls-2{fill:#fff;}</style></defs><rect class="cls-1" width="1038.90491" height="1600"/><circle class="cls-2" cx="226.58835" cy="1056.07411" r="109.02696"/><circle class="cls-2" cx="680.64509" cy="817.00695" r="109.02696"/><path class="cls-2" d="M472.48179,1336.66575a265.525,265.525,0,0,1-181.07121-138.09821,156.94811,156.94811,0,0,1-93.21911,11.45831,354.9352,354.9352,0,0,0,255.53721,214.16456,359.21054,359.21054,0,0,0,77.41948,7.967,156.00315,156.00315,0,0,1-31.92236-91.15471C490.24607,1340.00523,481.27719,1338.548,472.48179,1336.66575Z" transform="translate(0)"/><circle class="cls-2" cx="656.08182" cy="1337.26719" r="109.02696"/><path class="cls-2" d="M807.7978,1297.22089A356.70056,356.70056,0,0,0,825.67268,878.702a157.14405,157.14405,0,0,1-61.30976,71.80309,267.293,267.293,0,0,1-8.73685,265.48842A156.34662,156.34662,0,0,1,807.7978,1297.22089Z" transform="translate(0)"/><path class="cls-2" d="M218.17628,899.71905q4.1505-.2277,8.30533-.22553A157.3464,157.3464,0,0,1,309.164,923.039,265.90648,265.90648,0,0,1,523.2722,808.52964a158.08773,158.08773,0,0,1,33.076-88.42024C419.24532,709.25176,286.02405,780.001,218.17628,899.71905Z" transform="translate(0)"/></svg>
        """#

    static let fedora = #"""
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="30.95 15.55 39.6 39.6"><circle cx="50.75" cy="35.35" r="17.8" fill="#ffffff"/><g transform="translate(-550)"><g transform="matrix(1.1600518,0,0,1.1600518,654.47677,-112.84527)"><path fill="#51a2da" d="m -46.297501,110.68027 c -9.409465,0 -17.035254,7.62317 -17.041392,17.03049 h -0.0033 v 13.19147 h 0.0033 c 0.0033,2.13569 1.734951,3.86445 3.871731,3.86445 h 0.01859 0.0033 13.155147 c 9.410518,-0.005 17.034119,-7.63167 17.034119,-17.0414 0,-9.4137 -7.627665,-17.04501 -17.041376,-17.04501 z m 3.454039,7.0134 c 2.862013,0 5.564243,2.19299 5.564243,5.21559 0,0.28031 -0.0014,0.56098 -0.04723,0.87894 -0.07915,0.80419 -0.812415,1.38091 -1.61262,1.26756 -0.800171,-0.11469 -1.342977,-0.87224 -1.194926,-1.66709 0.01316,-0.0908 0.01859,-0.23457 0.01859,-0.47941 0,-1.71374 -1.401445,-2.37534 -2.727621,-2.37534 -1.325402,0 -2.521086,1.11449 -2.524262,2.37534 0.02287,1.45848 0,2.90649 0,4.36203 l 2.458868,-0.0186 c 1.920471,-0.0398 1.941995,2.85491 0.02172,2.84022 l -2.480671,0.0186 c -0.0083,1.17308 0.0099,0.96006 0.0033,1.55086 0,0 0.02122,1.43289 -0.02172,2.52063 -0.296877,3.19461 -3.015923,5.74945 -6.283371,5.74945 -3.463237,0 -6.319706,-2.8334 -6.319706,-6.30516 0.104,-3.57153 2.954791,-6.37845 6.541248,-6.34511 l 1.997599,-0.0148 v 2.83659 l -1.997599,0.0186 h -0.01481 c -1.971155,0.0581 -3.657825,1.39399 -3.690111,3.50487 0,1.9234 1.554366,3.46496 3.483082,3.46496 1.925524,0 3.464932,-1.40243 3.464932,-3.46131 0.02188,-3.41443 -0.01481,-7.18616 -0.0033,-10.73259 0.0011,-0.19925 0.01152,-0.3577 0.03274,-0.57748 0.325147,-2.6257 2.673827,-4.6272 5.331808,-4.6272 z"/></g></g></svg>
        """#

    static let ubuntuImage = NSImage(data: Data(ubuntu.utf8))
    static let fedoraImage = NSImage(data: Data(fedora.utf8))
}

/// The Ubuntu mark: Canonical's Circle of Friends.
struct UbuntuLogo: View {
    var body: some View { ArtworkView(image: OfficialArtwork.ubuntuImage, fallback: "circle.hexagongrid") }
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
