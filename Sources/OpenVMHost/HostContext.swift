// HostContext — the state every handler shares: where the host keeps its files,
// the VM registry, and the guests it holds live.
import Foundation
import OpenVMCore

nonisolated let home =
    ProcessInfo.processInfo.environment["OPENVM_HOME"].map {
        URL(fileURLWithPath: $0)
    } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openvm")
nonisolated let sockPath = home.appendingPathComponent("openvmd.sock").path
nonisolated let registry = VmRegistry()
nonisolated let liveVMs = LiveVMs()
nonisolated let artifactPort = UInt16(ProcessInfo.processInfo.environment["OPENVM_ARTIFACT_PORT"] ?? "8124") ?? 8124
nonisolated let artifactReceiver = ArtifactReceiver(registry: registry, port: artifactPort)
