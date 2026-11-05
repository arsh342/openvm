// The single-host rule: two hosts on one home would fight over the socket and registry.
import Darwin
import Foundation
import Testing

@testable import OpenVMHost

struct HostLockTests {
    private func tempHome() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hostlock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func secondHostIsRefusedAndNamesTheHolder() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let first = try HostLock.acquire(home: home)
        defer { first.release() }
        #expect(throws: HostLockError.held(pid: getpid())) { try HostLock.acquire(home: home) }
    }

    @Test func lockIsReleasedWithItsHolder() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let first = try HostLock.acquire(home: home)
        first.release()
        let second = try HostLock.acquire(home: home)
        second.release()
    }

    @Test func differentHomesDoNotCollide() throws {
        let a = try tempHome()
        let b = try tempHome()
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        let one = try HostLock.acquire(home: a)
        let two = try HostLock.acquire(home: b)
        one.release()
        two.release()
    }
}
