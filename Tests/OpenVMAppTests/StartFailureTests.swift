// What the app tells a person when the host cannot start.
import Foundation
import OpenVMHost
import Testing

@testable import OpenVMApp

struct StartFailureTests {
    @Test func aRunningHostIsNamedByItsProcess() {
        let message = hostStartFailureMessage(HostLockError.held(pid: 4242))
        #expect(message.contains("4242"))
        #expect(message.contains("Quit it"))
    }

    @Test func anyOtherFailureIsStatedPlainly() {
        struct Boom: Error, CustomStringConvertible { var description: String { "no socket" } }
        #expect(hostStartFailureMessage(Boom()).contains("no socket"))
    }
}
