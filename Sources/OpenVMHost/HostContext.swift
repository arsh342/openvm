// HostContext — the state every handler shares: where the host keeps its files,
// the VM registry, and the guests it holds live.
import Foundation
import OpenVMCore

nonisolated let home = OVMPaths.home
nonisolated let sockPath = OVMPaths.socket
nonisolated let registry = VmRegistry()
nonisolated let liveVMs = LiveVMs()
nonisolated let artifactPort = UInt16(ProcessInfo.processInfo.environment["OPENVM_ARTIFACT_PORT"] ?? "8124") ?? 8124
