// The install media openVM builds lives in <home>/media. Deleting a VM, or finishing its install,
// removes that file; a path anywhere else is never touched, however it is spelled.
import Foundation
import OpenVMCore
import Testing

@testable import OpenVMHost

nonisolated struct OwnedMediaTests {
    private func scratch() throws -> (root: URL, media: URL, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("om-\(UUID().uuidString)")
        let media = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        return (root, media, { try? FileManager.default.removeItem(at: root) })
    }

    private func touch(_ url: URL) throws { try Data("media".utf8).write(to: url) }

    @Test func ownedMediaIsRemoved() throws {
        let s = try scratch()
        defer { s.cleanup() }
        let file = s.media.appendingPathComponent("win.raw")
        try touch(file)
        #expect(removeOwnedMedia(file.path, mediaRoot: s.media))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aFileOutsideTheMediaFolderIsKept() throws {
        let s = try scratch()
        defer { s.cleanup() }
        let theirs = s.root.appendingPathComponent("their-own.raw")
        try touch(theirs)
        #expect(!removeOwnedMedia(theirs.path, mediaRoot: s.media))
        #expect(FileManager.default.fileExists(atPath: theirs.path))  // e.g. media the user made by hand
    }

    @Test func aPathThatClimbsOutIsKept() throws {
        let s = try scratch()
        defer { s.cleanup() }
        let theirs = s.root.appendingPathComponent("victim.raw")
        try touch(theirs)
        let sneaky = s.media.path + "/../victim.raw"
        #expect(!removeOwnedMedia(sneaky, mediaRoot: s.media))
        #expect(FileManager.default.fileExists(atPath: theirs.path))
    }

    /// A link inside the media folder is removed as a link; what it points at survives.
    @Test func aLinkOutIsNotFollowed() throws {
        let s = try scratch()
        defer { s.cleanup() }
        let victim = s.root.appendingPathComponent("victim.raw")
        try touch(victim)
        let link = s.media.appendingPathComponent("link.raw")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: victim)
        _ = removeOwnedMedia(link.path, mediaRoot: s.media)
        #expect(FileManager.default.fileExists(atPath: victim.path))
    }

    @Test func aDirectoryIsNeverRemoved() throws {
        let s = try scratch()
        defer { s.cleanup() }
        let dir = s.media.appendingPathComponent("folder.raw")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try touch(dir.appendingPathComponent("inside"))
        #expect(!removeOwnedMedia(dir.path, mediaRoot: s.media))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("inside").path))
    }

    @Test func aMissingFileIsNotAnError() throws {
        let s = try scratch()
        defer { s.cleanup() }
        #expect(!removeOwnedMedia(s.media.appendingPathComponent("gone.raw").path, mediaRoot: s.media))
    }
}
