// Where openVM keeps its files. The host, the CLI and the app must agree.
import Foundation

public nonisolated enum OVMPaths {
    /// `$OPENVM_HOME`, else `~/.openvm`.
    public static var home: URL {
        if let env = ProcessInfo.processInfo.environment["OPENVM_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openvm")
    }

    /// The host's Unix socket.
    public static var socket: String { home.appendingPathComponent("openvmd.sock").path }
}
