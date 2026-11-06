// ReceiptMessage — the line a window shows when a guest has sent files to the Mac.
import OpenVMHost

enum ReceiptMessage {
    static func subtitle(_ receipt: OutboxReceipt) -> String {
        if let why = receipt.rejection { return "Refused what \(receipt.vmName) sent: \(why)" }
        let n = receipt.items.count
        let what = n == 1 ? receipt.items[0] : "\(n) items"
        return "Received \(what) in Downloads/openVM/\(receipt.vmName)"
    }
}
