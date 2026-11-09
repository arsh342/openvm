// OwnedMedia — the install media openVM builds lives in <home>/media, and only that is ever removed.
// A path anywhere else (media a person made by hand and passed to `create --install-media`) is theirs.
import Foundation

/// Removes a media file if, and only if, it sits directly in `mediaRoot` and is a plain file (or a
/// link, which is removed as a link, never followed). Returns whether it removed anything.
nonisolated func removeOwnedMedia(_ path: String, mediaRoot: URL) -> Bool {
    // Standardizing resolves ".." lexically, so "<media>/../x" is judged as "<home>/x": outside.
    let file = URL(fileURLWithPath: path).standardizedFileURL
    guard file.deletingLastPathComponent().resolvingSymlinksInPath().path == mediaRoot.resolvingSymlinksInPath().path
    else { return false }
    // attributesOfItem does not traverse a link, so a link out of the folder is seen as a link.
    guard let type = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.type] as? FileAttributeType,
        type == .typeRegular || type == .typeSymbolicLink
    else { return false }
    return (try? FileManager.default.removeItem(at: file)) != nil
}

/// Where the host keeps the install media it builds.
nonisolated var mediaFolder: URL { home.appendingPathComponent("media", isDirectory: true) }
