// HostLock — only one host (the app or openvmd) may serve a given OPENVM_HOME.
//
// Two hosts would fight over the socket (bindListen unlinks whatever is there) and
// over the registry, so the second one is refused before it touches either. The
// lock is an flock on a file in the home directory: the kernel drops it when the
// holder dies, so a crash never leaves a stale lock behind.
import Darwin
import Foundation

public nonisolated enum HostLockError: Error, Equatable, CustomStringConvertible {
    case held(pid: Int32)
    case io(String)

    public var description: String {
        switch self {
        case .held(let pid): return "another openVM host (pid \(pid)) is already running"
        case .io(let message): return message
        }
    }
}

nonisolated final class HostLock: @unchecked Sendable {
    private var fd: Int32

    private init(fd: Int32) { self.fd = fd }

    deinit { release() }

    /// Takes the lock for a home directory, or throws `.held` naming the holder.
    static func acquire(home: URL) throws -> HostLock {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let path = home.appendingPathComponent("host.lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw HostLockError.io("cannot open \(path): \(String(cString: strerror(errno)))") }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let reason = errno
            defer { close(fd) }
            guard reason == EWOULDBLOCK else {
                throw HostLockError.io("cannot lock \(path): \(String(cString: strerror(reason)))")
            }
            throw HostLockError.held(pid: holder(fd))
        }
        // Only the holder writes, so the pid in the file is the holder's.
        let pid = Array("\(getpid())\n".utf8)
        _ = ftruncate(fd, 0)
        _ = pwrite(fd, pid, pid.count, 0)
        return HostLock(fd: fd)
    }

    func release() {
        guard fd >= 0 else { return }
        close(fd)  // closing drops the flock
        fd = -1
    }

    private static func holder(_ fd: Int32) -> Int32 {
        var buffer = [UInt8](repeating: 0, count: 32)
        let n = pread(fd, &buffer, buffer.count, 0)
        guard n > 0 else { return 0 }
        let text = String(decoding: buffer.prefix(n), as: UTF8.self)
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}
