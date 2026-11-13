// SystemLogos — the marks shown beside a system: Windows, Ubuntu and Fedora, drawn in code, and a neutral
// glyph for anything else. They say what a tile installs and what a VM runs (the owner's choice,
// 2026-11-13). Each is its maker's trademark, and its usage rules are to be checked before a public
// release (docs/gui-notes.md).
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

/// The Ubuntu mark, the Circle of Friends: an orange disc with a white ring in three arcs, and a white
/// dot at each gap.
struct UbuntuLogo: View {
    private static let orange = Color(red: 0.914, green: 0.329, blue: 0.125)
    /// Where the three dots sit, in degrees, clockwise from the right.
    private static let heads: [Double] = [180, 300, 60]

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            ZStack {
                Circle().fill(Self.orange).frame(width: side, height: side).position(center)
                // The arms: three arcs of one ring, each stopping short of a dot.
                ForEach(Self.heads, id: \.self) { head in
                    Path { path in
                        path.addArc(
                            center: center, radius: side * 0.245, startAngle: .degrees(head + 27),
                            endAngle: .degrees(head + 93), clockwise: false)
                    }
                    .stroke(Color.white, style: StrokeStyle(lineWidth: side * 0.105, lineCap: .butt))
                }
                // The heads, a little outside the ring.
                ForEach(Self.heads, id: \.self) { head in
                    let angle = head * .pi / 180
                    Circle().fill(Color.white).frame(width: side * 0.15, height: side * 0.15)
                        .position(
                            x: center.x + cos(angle) * side * 0.335, y: center.y + sin(angle) * side * 0.335)
                }
            }
        }
    }
}

/// The Fedora mark: a blue disc with a white "f" whose foot curls into a loop.
struct FedoraLogo: View {
    private static let blue = Color(red: 0.318, green: 0.635, blue: 0.855)

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let origin = CGPoint(x: (proxy.size.width - side) / 2, y: (proxy.size.height - side) / 2)
            let point: (CGFloat, CGFloat) -> CGPoint = { x, y in
                CGPoint(x: origin.x + x * side, y: origin.y + y * side)
            }
            ZStack {
                Circle().fill(Self.blue).frame(width: side, height: side)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                Path { path in
                    // The hook at the top, and the stem down to the bar.
                    path.move(to: point(0.735, 0.335))
                    path.addArc(
                        center: point(0.62, 0.335), radius: side * 0.115, startAngle: .degrees(0),
                        endAngle: .degrees(180),
                        clockwise: true)
                    path.addLine(to: point(0.505, 0.665))
                    // The foot curls left into a loop, which comes back as the bar.
                    path.addArc(
                        center: point(0.39, 0.665), radius: side * 0.115, startAngle: .degrees(0),
                        endAngle: .degrees(270),
                        clockwise: false)
                    path.addLine(to: point(0.64, 0.55))
                }
                .stroke(
                    Color.white,
                    style: StrokeStyle(lineWidth: side * 0.095, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
