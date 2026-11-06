import Foundation
import Testing

@testable import OpenVMApp
@testable import OpenVMHost

struct ReceiptMessageTests {
    private func receipt(items: [String], rejection: String? = nil) -> OutboxReceipt {
        OutboxReceipt(uuid: "u", vmName: "dev", items: items, folder: URL(fileURLWithPath: "/tmp"), rejection: rejection)
    }

    @Test func oneFileIsNamed() {
        #expect(ReceiptMessage.subtitle(receipt(items: ["a.txt"])) == "Received a.txt in Downloads/openVM/dev")
    }

    @Test func manyAreCounted() {
        #expect(ReceiptMessage.subtitle(receipt(items: ["a", "b", "c"])).hasPrefix("Received 3 items"))
    }

    @Test func aRefusalSaysWhy() {
        let text = ReceiptMessage.subtitle(receipt(items: [], rejection: "the guest sent nothing"))
        #expect(text.contains("Refused") && text.contains("sent nothing"))
    }
}
