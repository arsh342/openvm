// ThumbnailStore — the small picture of each VM's screen that the library shows on its card.
//
// The app takes one from a VM's window now and then and keeps the last good one, so a stopped VM still
// shows how it was left. Stored as PNGs under `$OPENVM_HOME/thumbs`. A blank capture is never kept: it
// would replace a useful picture with a black rectangle.
import AppKit
import Combine
import OpenVMCore

@MainActor
final class ThumbnailStore: ObservableObject {
    static let shared = ThumbnailStore(directory: OVMPaths.home.appendingPathComponent("thumbs"))
    /// Wide enough for a card at 2x, small enough to be a few tens of kilobytes.
    static let maxWidth = 640

    /// Bumped whenever a picture changes, so cards redraw.
    @Published private(set) var revision = 0
    private let directory: URL
    private var cache: [String: NSImage] = [:]

    init(directory: URL) { self.directory = directory }

    func image(for uuid: String) -> NSImage? {
        guard let url = url(for: uuid) else { return nil }
        if let cached = cache[uuid] { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache[uuid] = image
        return image
    }

    /// Scales and stores a capture. False when it was blank, or could not be written.
    @discardableResult
    func save(_ capture: NSBitmapImageRep, for uuid: String) -> Bool {
        guard let url = url(for: uuid), !Self.isBlank(capture), let small = Self.scaled(capture),
            let data = small.representation(using: .png, properties: [:])
        else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch { return false }
        cache[uuid] = nil
        revision += 1
        return true
    }

    func remove(_ uuid: String) {
        guard let url = url(for: uuid) else { return }
        try? FileManager.default.removeItem(at: url)
        cache[uuid] = nil
        revision += 1
    }

    /// A VM's id is a UUID; anything that could name another place is refused.
    private func url(for uuid: String) -> URL? {
        guard !uuid.isEmpty, uuid.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        return directory.appendingPathComponent("\(uuid).png")
    }

    /// Samples a grid of pixels: a screen that is all (nearly) black has nothing to show.
    static func isBlank(_ rep: NSBitmapImageRep) -> Bool {
        guard rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return true }
        for yi in 0..<8 {
            for xi in 0..<8 {
                let x = min(rep.pixelsWide - 1, (xi * rep.pixelsWide) / 8 + rep.pixelsWide / 16)
                let y = min(rep.pixelsHigh - 1, (yi * rep.pixelsHigh) / 8 + rep.pixelsHigh / 16)
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent + color.greenComponent + color.blueComponent > 0.06 { return false }
            }
        }
        return true
    }

    private static func scaled(_ rep: NSBitmapImageRep) -> NSBitmapImageRep? {
        let width = min(rep.pixelsWide, maxWidth)
        let height = max(1, rep.pixelsHigh * width / max(1, rep.pixelsWide))
        guard
            let out = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSGraphicsContext.current?.imageInterpolation = .high
        rep.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        return out
    }
}
