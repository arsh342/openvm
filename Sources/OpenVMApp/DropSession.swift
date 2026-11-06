// DropSession — one VM's file drop, from the moment files land on its window to the guest saying
// they are in place. The host stages and copies; this follows it. Only one drop runs at a time
// (the host refuses a second), and nothing is polled unless a drop is running.
import Combine
import Foundation
import OpenVMCore

enum DropState: Equatable {
    case idle
    case copying(bytes: UInt64)
    case finished([String])
    case failed(String)
}

@MainActor
final class DropSession: ObservableObject {
    @Published private(set) var state: DropState = .idle
    /// Why a drop dropped while another was running was not taken. Cleared with the next drop.
    @Published private(set) var refusal: String?

    private let uuid: String
    private let name: String
    private let transport: any HostTransport
    private let interval: Duration

    init(uuid: String, name: String, transport: any HostTransport, interval: Duration = .seconds(1)) {
        self.uuid = uuid
        self.name = name
        self.transport = transport
        self.interval = interval
    }

    var isRunning: Bool {
        if case .copying = state { return true }
        return false
    }

    /// Takes the files to the guest and follows the copy to its end.
    func begin(paths: [String]) async {
        if isRunning {
            refusal = "A drop to \(name) is already running. Wait for it to finish."
            return
        }
        refusal = nil
        // The same rules the host applies, so a bad drop fails before anything is copied.
        if case .failure(let problem) = DragDrop.itemNames(for: paths) {
            state = .failed(problem.description)
            return
        }
        state = .copying(bytes: 0)
        do {
            _ = try await transport.send(
                "drag", [("id", .text(uuid)), ("op", .text("drop")), ("paths", .array(paths.map { .text($0) }))])
        } catch {
            state = .failed("\(error)")
            return
        }
        await follow()
    }

    /// Back to idle once the person has seen the result.
    func dismiss() { if !isRunning { state = .idle } }

    private func follow() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: interval)
                let fields = try await transport.send("drag", [("id", .text(uuid)), ("op", .text("status"))])
                guard let status = DragDrop.status(.map(fields)) else {
                    state = .failed("The guest's answer was not understood.")
                    return
                }
                if let error = status.error {
                    state = .failed(error)
                    return
                }
                if status.done {
                    state = .finished(status.placed)
                    return
                }
                state = .copying(bytes: status.bytes)
            } catch is CancellationError {
                return
            } catch {
                // The VM stopped, or the host went away: there is nothing left to poll.
                state = .failed("\(error)")
                return
            }
        }
    }
}
