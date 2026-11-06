// GuestPayload — the files the host needs to build a guest, shipped with the app rather
// than found on the developer's machine: the install overlay a first boot fetches, and the
// helpers that fetching the Linux files and building Windows media use.
//
//   guest/linux/openvm.apkovl.tar.gz    the overlay: installs Alpine and starts the agent
//   guest/linux/fetch-linux.sh          fetches the pinned Alpine kernel, initramfs and modloop
//   guest/linux/openvm-zboot            unpacks the kernel (so the Mac needs no C compiler)
import Foundation

nonisolated enum GuestPayload {
    static let overlayName = "openvm.apkovl.tar.gz"

    /// Where the payload is, in order: `OPENVM_PAYLOAD` (a developer's override, and decisive:
    /// a wrong path is not quietly replaced by another), the app bundle's resources, and
    /// `.build/payload` under the current directory (what a checkout builds with `make payload`).
    static func root(
        environment: [String: String], bundleResources: URL?, currentDirectory: URL? = nil
    ) -> URL? {
        func directory(_ url: URL) -> URL? {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
                ? url : nil
        }
        if let override = environment["OPENVM_PAYLOAD"], !override.isEmpty {
            return directory(URL(fileURLWithPath: override))
        }
        if let bundled = bundleResources.flatMap({ directory($0.appendingPathComponent("guest")) }) {
            return bundled
        }
        return currentDirectory.flatMap { directory($0.appendingPathComponent(".build/payload")) }
    }

    /// The payload this process runs with.
    static var root: URL? {
        root(
            environment: ProcessInfo.processInfo.environment, bundleResources: Bundle.main.resourceURL,
            currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    }

    /// The install overlay, only if the payload really has it.
    static func overlay(in root: URL?) -> URL? {
        guard let file = root?.appendingPathComponent("linux/\(overlayName)"),
            FileManager.default.fileExists(atPath: file.path)
        else { return nil }
        return file
    }

    static var overlay: URL? { overlay(in: root) }
}
