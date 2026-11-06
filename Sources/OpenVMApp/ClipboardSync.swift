// ClipboardSync — moves text between the Mac's clipboard and one guest's as the VM's window gains
// and loses focus. What to move, and what never to, is ClipboardPolicy; this does the I/O.
//
// Nothing here polls. A push happens when the window comes to the front, a pull when it goes away,
// so an idle guest costs nothing and the guest agents need no change.
import AppKit
import OpenVMCore

/// The part of the Mac's pasteboard this needs, so a test can stand in for it.
@MainActor
protocol PasteboardAccess: AnyObject {
    var changeCount: Int { get }
    /// True when the app that copied this asked for it not to be kept or shared.
    var isConcealed: Bool { get }
    func text() -> String?
    /// Replaces the contents with plain text; returns the new change count.
    func setText(_ text: String) -> Int
}

@MainActor
final class MacPasteboard: PasteboardAccess {
    private let pasteboard: NSPasteboard
    /// The convention password managers follow (nspasteboard.org).
    private static let hidden: [NSPasteboard.PasteboardType] = [
        .init("org.nspasteboard.ConcealedType"), .init("org.nspasteboard.TransientType"),
    ]

    init(_ pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    var changeCount: Int { pasteboard.changeCount }
    var isConcealed: Bool { Self.hidden.contains { pasteboard.types?.contains($0) == true } }
    func text() -> String? { pasteboard.string(forType: .string) }
    func setText(_ text: String) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }
}

@MainActor
final class ClipboardSync {
    private var policy: ClipboardPolicy
    private let uuid: String
    private let name: String
    private let transport: any HostTransport
    private let pasteboard: any PasteboardAccess
    /// Called with a short line when something was not shared, and with nil when that no longer holds.
    var onNotice: (String?) -> Void = { _ in }
    /// Operations run one after another: a pull must finish before the next push reads the Mac.
    private var tail: Task<Void, Never>?

    init(vm: VmSummary, transport: any HostTransport, pasteboard: any PasteboardAccess) {
        self.policy = ClipboardPolicy(enabled: vm.clipboardSync)
        self.uuid = vm.uuid
        self.name = vm.name
        self.transport = transport
        self.pasteboard = pasteboard
    }

    /// The per-VM switch changed.
    func setEnabled(_ on: Bool) { policy.enabled = on }

    /// The VM's window came to the front: send the Mac's text, if it is new and fit to share.
    func focusGained() async { await enqueue { await $0.push() } }

    /// The VM's window stopped being in front: fetch the guest's text for the Mac.
    func focusLost() async { await enqueue { await $0.pull() } }

    private func enqueue(_ work: @escaping @MainActor (ClipboardSync) async -> Void) async {
        let previous = tail
        let task = Task { @MainActor [self] in
            await previous?.value
            await work(self)
        }
        tail = task
        await task.value
    }

    private func push() async {
        let text = pasteboard.text()
        guard
            policy.onFocusGained(
                changeCount: pasteboard.changeCount, concealed: pasteboard.isConcealed,
                byteCount: text?.utf8.count ?? 0),
            let text
        else {
            report()
            return
        }
        do {
            _ = try await transport.send("clipboard-write", [("id", .text(uuid)), ("text", .text(text))])
            policy.didPush(text)
            log("sent \(text.utf8.count) bytes to \(name)")
        } catch {
            // Most often the guest has no desktop session yet; the next focus tries again.
            policy.pushFailed()
        }
        report()
    }

    private func pull() async {
        guard policy.enabled else { return }
        let guestText: String?
        do {
            let fields = try await transport.send("clipboard-read", [("id", .text(uuid))])
            if case .text(let t)? = DaemonClient.field(fields, "text") { guestText = t } else { guestText = nil }
        } catch {
            return
        }
        if let text = policy.onFocusLost(guestText: guestText) {
            policy.didPull(changeCount: pasteboard.setText(text), text: text)
            log("received \(text.utf8.count) bytes from \(name)")
        }
        report()
    }

    private func report() {
        switch policy.lastSkip {
        case .concealed?: onNotice("Clipboard not shared: it was marked private")
        case .tooLarge?: onNotice("Clipboard not shared: the text is over 512 KiB")
        case nil: onNotice(nil)
        }
    }

    /// Sizes only. What was copied is never written down.
    private func log(_ line: String) {
        FileHandle.standardError.write(Data("openvm: clipboard: \(line)\n".utf8))
    }
}
