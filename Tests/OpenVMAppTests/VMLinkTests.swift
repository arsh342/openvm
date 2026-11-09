// openvm://vm/<name> opens a VM's window. It names a VM and does nothing else.
import Foundation
import Testing

@testable import OpenVMApp

struct VMLinkTests {
    @Test func aNameOrUuidIsAccepted() {
        #expect(vmReference(from: URL(string: "openvm://vm/win11")!) == "win11")
        #expect(vmReference(from: URL(string: "openvm://vm/my_box-2")!) == "my_box-2")
        let uuid = "10CE9AF1-30C2-4A0F-B60A-E54FBDEAD1CE"
        #expect(vmReference(from: URL(string: "openvm://vm/\(uuid)")!) == uuid)
    }

    @Test func anythingElseIsRefused() {
        for text in [
            "https://vm/win11", "openvm://other/win11", "openvm://vm/", "openvm://vm",
            "openvm://vm/a/b", "openvm://vm/..", "openvm://vm/-flag", "openvm://vm/a%20b",
            "openvm://vm/\(String(repeating: "a", count: 65))", "openvm://vm/win11?action=stop",
        ] {
            #expect(vmReference(from: URL(string: text)!) == nil, "\(text)")
        }
    }
}
