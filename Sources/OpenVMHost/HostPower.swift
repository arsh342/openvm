// Watches the Mac's sleep and wake, so guests can be paused safely.
import Foundation
import IOKit
import IOKit.pwr_mgt

/// The host's sleep and wake, as the daemon sees them.
///
/// IOKit delivers the notifications on the run loop of the thread that
/// registered them, so the watcher owns a private thread with a run loop. The
/// sleep notification must be acknowledged with `IOAllowPowerChange` — the
/// sleep goes ahead anyway after 30 seconds if nobody acknowledges it — so the
/// daemon's handler (which flushes the guests) runs first and the
/// acknowledgement follows it.
nonisolated enum HostPower {
    enum Event: Sendable {
        /// The host is about to sleep; the guests are quiesced and then the
        /// sleep is acknowledged.
        case willSleep
        /// The host woke up; the integration state is re-established.
        case didWake
    }

    /// The IOKit message ids the C headers define as macros Swift cannot
    /// import: `kIOMessageSystemWillSleep` (0x80000280) and
    /// `kIOMessageSystemHasPoweredOn` (0x80000300).
    private static let willSleepMessage: UInt32 = 0x8000_0280
    private static let hasPoweredOnMessage: UInt32 = 0x8000_0300

    /// Carries the registration result out of the watcher thread.
    private final class Flag: @unchecked Sendable {
        var registered = false
    }

    /// The kernel port that acknowledges the pending sleep.
    private nonisolated(unsafe) static var kernelPort: io_connect_t = 0
    /// The handler the daemon installed.
    private nonisolated(unsafe) static var handler: (@Sendable (Event) async -> Void)?

    /// Starts watching. Returns false when the system refused the
    /// registration, which leaves the daemon without sleep awareness.
    @discardableResult
    static func start(onEvent: @escaping @Sendable (Event) async -> Void) -> Bool {
        handler = onEvent
        let flag = Flag()
        let registered = DispatchSemaphore(value: 0)
        let thread = Thread {
            var port: IONotificationPortRef?
            var notifier: io_object_t = 0
            let kernel = IORegisterForSystemPower(nil, &port, powerCallback, &notifier)
            if kernel != 0, let port,
                let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue()
            {
                kernelPort = kernel
                CFRunLoopAddSource(CFRunLoopGetCurrent(), source, CFRunLoopMode.defaultMode)
                flag.registered = true
            }
            registered.signal()
            CFRunLoopRun()
        }
        thread.name = "openvmd.power"
        thread.start()
        registered.wait()
        return flag.registered
    }

    private static func acknowledge(notificationID: Int) {
        guard kernelPort != 0 else { return }
        _ = IOAllowPowerChange(kernelPort, notificationID)
    }

    private static let powerCallback: IOServiceInterestCallback = { _, _, message, argument in
        switch message {
        case HostPower.willSleepMessage:
            let id = Int(UInt(bitPattern: argument))
            let work = handler
            // The sleep waits for the acknowledgement, so the handler runs
            // first — it is async because flushing a guest is a blocking
            // channel exchange plus a pause on the main actor.
            Task.detached {
                await work?(.willSleep)
                acknowledge(notificationID: id)
            }
        case HostPower.hasPoweredOnMessage:
            let work = handler
            Task.detached { await work?(.didWake) }
        default:
            break
        }
    }
}
