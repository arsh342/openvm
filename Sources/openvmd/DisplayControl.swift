// DisplayControl — dynamic resolution. The host owns the size: it
// reconfigures the framework's display, which raises a virtio-gpu display event
// in the guest, then tells the agent to adopt the mode. The reply is the mode the
// guest reports afterwards, so success means the guest really holds it.
import Foundation
import OpenVMCore
import Virtualization

/// The last mode asked of each VM, re-applied after a resume.
nonisolated final class DisplayModes: @unchecked Sendable {
    private let lock = NSLock()
    private var modes: [String: (width: UInt64, height: UInt64, scale: UInt64?)] = [:]

    func set(_ id: String, width: UInt64, height: UInt64, scale: UInt64?) {
        lock.lock()
        defer { lock.unlock() }
        modes[id] = (width, height, scale ?? modes[id]?.scale)
    }

    func get(_ id: String) -> (width: UInt64, height: UInt64, scale: UInt64?)? {
        lock.lock()
        defer { lock.unlock() }
        return modes[id]
    }

    func clear(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        modes[id] = nil
    }
}

nonisolated let displayModes = DisplayModes()

@MainActor
private func reconfigureDisplay(_ vm: VZVirtualMachine, width: UInt64, height: UInt64) -> String {
    guard #available(macOS 14.0, *) else { return "dynamic resolution needs macOS 14" }
    guard let display = vm.graphicsDevices.first?.displays.first else {
        return "this VM has no display device; restart it"
    }
    do {
        try display.reconfigure(sizeInPixels: CGSize(width: Double(width), height: Double(height)))
        return ""
    } catch {
        return "the display refused \(width)x\(height): \(error)"
    }
}

/// Blocks on the guest channel, so it must not run on the main actor.
nonisolated func setGuestDisplay(_ g: LiveGuest, width: UInt64, height: UInt64, scale: UInt64? = nil) throws {
    let wait = BootWaiter()
    Task { @MainActor in wait.complete(reconfigureDisplay(g.vm, width: width, height: height)) }
    wait.wait()
    if let message = wait.value, !message.isEmpty { throw GuestBootError.failure(message) }
    var body: [(key: String, value: CBOR)] = [
        ("op", .text("set")), ("width", .uint(width)), ("height", .uint(height)),
    ]
    if let scale { body.append(("scale", .uint(scale))) }
    let reply = try GuestChannel.display(g, body: .map(body), timeoutSeconds: 30)
    guard let held = GuestDisplay.heldMode(reply) else {
        throw GuestBootError.failure("guest display reply has no mode")
    }
    guard held.width == width, held.height == height else {
        throw GuestBootError.failure("guest holds \(held.width)x\(held.height), not \(width)x\(height)")
    }
    if let scale, GuestDisplay.heldScale(reply) != scale {
        throw GuestBootError.failure("guest did not take scale \(scale)")
    }
}

/// the display configuration survives a suspend. Best effort, like
/// the clock: a guest that cannot take it is still resumed.
nonisolated func reapplyDisplay(_ record: VmRecord) {
    guard let mode = displayModes.get(record.uuid), let g = liveVMs.peek(record.uuid) else { return }
    do {
        try setGuestDisplay(g, width: mode.width, height: mode.height, scale: mode.scale)
    } catch {
        note("openvmd: \(record.name): display not re-applied: \(error)")
    }
}
