// Usage — what the CLI accepts, and how it gives up.
import Foundation

let usage = """
    Usage:
      openvmctl create <name> [--cpus N] [--memoryMB N] [--diskSizeMB N] [--boot-mode linux|windows] [--variable-store-path PATH] [--install-media MEDIA.raw]
      openvmctl list
      openvmctl info <name|uuid>
      openvmctl start <name|uuid>
      openvmctl ping <name|uuid>
      openvmctl stop <name|uuid> [--no-wait]
      openvmctl stop-all
      openvmctl host-info
      openvmctl delete <name|uuid>
      openvmctl suspend <name|uuid>
      openvmctl resume <name|uuid>
      openvmctl set <name|uuid> [--cpus N] [--memoryMB N] [--tz Zone] [--boot-mode linux|windows] [--variable-store-path PATH] [--clipboard-sync on|off]
      openvmctl clipboard push|pull <name|uuid>
      openvmctl file push <name|uuid> <host-path> [guest-name]
      openvmctl file pull <name|uuid> <guest-name> <host-path>
      openvmctl share add <name|uuid> <host-dir> [guest-dir]
      openvmctl share list <name|uuid>
      openvmctl share remove <name|uuid> <host-dir>
      openvmctl drag enter|leave <name|uuid>
      openvmctl drag drop <name|uuid> <host-path>...
      openvmctl printer list <name|uuid>
      openvmctl printer test <name|uuid> --name <printer>
      openvmctl audio status|test <name|uuid>
      openvmctl audio enable <name|uuid> --test-mode   (Windows; weakens driver signing, see README)
      openvmctl audio disable <name|uuid>
      openvmctl display set <name|uuid> --width N --height N [--scale 1|2|3]
      openvmctl display capture <name|uuid>
      openvmctl config schema
      Guest files are staged under /tmp/openvm-share; guest names are basenames.
    """

func fail(_ msg: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write("openvmctl: \(msg)\n".data(using: .utf8)!)
    exit(code)
}
