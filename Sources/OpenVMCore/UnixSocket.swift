// The Unix socket between openvmctl and openvmd.
import Darwin
import Foundation

/// Raw POSIX unix-domain-socket helpers: blocking, synchronous,
/// single connection at a time. Exactly what the stub daemon needs;
/// an event-loop or async rewrite waits for a real multi-client design.
public nonisolated enum UnixSocket {

    private static func errnoError() -> POSIXError {
        if let c = POSIXErrorCode(rawValue: errno) { return POSIXError(c) }
        return POSIXError(.EIO)
    }

    private static func check(_ r: Int32) throws {
        if r < 0 { throw errnoError() }
    }

    /// Connect to a socket file; returns the fd.
    public static func connect(path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw errnoError() }
        do {
            var addr = try sockaddrFor(path: path)
            let r = withUnsafePointer(to: &addr) { p -> Int32 in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            try check(r)
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    /// Create, bind and listen on a socket file (blocking backlog of 8).
    /// Unlinks a stale socket file first; creates the parent directory.
    public static func bindListen(path: String) throws -> Int32 {
        let fm = FileManager.default
        try? fm.removeItem(atPath: path)
        try fm.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw errnoError() }
        do {
            var addr = try sockaddrFor(path: path)
            let r = withUnsafePointer(to: &addr) { p -> Int32 in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            try check(r)
            try check(Darwin.listen(fd, 8))
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    /// Accept one connection; returns the fd or -1.
    public static func acceptOne(fd: Int32) -> Int32 { Darwin.accept(fd, nil, nil) }

    /// Read exactly n bytes. nil when the peer EOFed first.
    public static func readExact(fd: Int32, _ n: Int) throws -> Data? {
        var data = Data()
        data.reserveCapacity(n)
        var buf = [UInt8](repeating: 0, count: 4096)
        while data.count < n {
            let want = min(buf.count, n - data.count)
            let got = Darwin.read(fd, &buf, want)
            if got < 0 {
                if errno == EINTR { continue }
                throw errnoError()
            }
            if got == 0 { return nil }  // EOF before n bytes
            data.append(contentsOf: buf[..<got])
        }
        return data
    }

    // One POSIX chunk read (as much as arrived, up to 4 KB); nil on EOF/error.
    // Used by the daemon session reader — readExact() would stall waiting for n bytes.
    /// Reads what is available, or nil at end of stream.
    public static func readChunk(fd: Int32) -> Data? {
        var buf = [UInt8](repeating: 0, count: 4096)
        var n = 0
        repeat { n = Darwin.read(fd, &buf, buf.count) } while n < 0 && errno == EINTR
        guard n > 0 else { return nil }
        return Data(bytes: buf, count: n)
    }

    /// Writes every byte, retrying partial writes.
    public static func writeAll(fd: Int32, _ data: Data) throws {
        var offset = data.startIndex
        while offset < data.endIndex {
            let n = data.withUnsafeBytes { raw -> Int in
                let p = raw.baseAddress!.advanced(by: offset - data.startIndex)
                return Darwin.write(fd, p, data.endIndex - offset)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw errnoError()
            }
            guard n > 0 else { throw POSIXError(.EIO) }
            offset = data.index(offset, offsetBy: n)
        }
    }

    static func sockaddrFor(path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw VmRegistryError.io("socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        return addr
    }
}
