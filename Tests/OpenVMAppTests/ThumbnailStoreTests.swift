// The library's preview of each VM: stored as a small PNG, never from a blank screen.
import AppKit
import Foundation
import Testing

@testable import OpenVMApp

@MainActor
struct ThumbnailStoreTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("thumbs-\(UUID().uuidString.lowercased())")
    }

    private func image(width: Int, height: Int, color: NSColor) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    @Test func aSavedPreviewComesBackAndRemovalForgetsIt() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ThumbnailStore(directory: dir)
        #expect(store.image(for: "u") == nil)
        #expect(store.save(image(width: 100, height: 60, color: .systemBlue), for: "u"))
        #expect(store.image(for: "u") != nil)
        store.remove("u")
        #expect(store.image(for: "u") == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("u.png").path))
    }

    @Test func aBlankScreenIsNotSaved() {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ThumbnailStore(directory: dir)
        #expect(!store.save(image(width: 100, height: 60, color: .black), for: "u"))
        #expect(store.image(for: "u") == nil)
    }

    @Test func aBigScreenIsScaledDown() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ThumbnailStore(directory: dir)
        #expect(store.save(image(width: 2496, height: 1496, color: .systemTeal), for: "u"))
        let data = try Data(contentsOf: dir.appendingPathComponent("u.png"))
        let rep = try #require(NSBitmapImageRep(data: data))
        #expect(rep.pixelsWide <= ThumbnailStore.maxWidth)
        #expect(Double(rep.pixelsWide) / Double(rep.pixelsHigh) > 1.6)  // the shape is kept
    }

    @Test func aNameThatCouldEscapeTheFolderIsRefused() {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ThumbnailStore(directory: dir)
        #expect(!store.save(image(width: 10, height: 10, color: .systemRed), for: "../evil"))
        #expect(store.image(for: "../evil") == nil)
    }
}
