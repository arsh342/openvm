// openvmctl — CLI client for openvmd (full VM lifecycle + guest services).
// Prints vmReply fields as key=value lines; exit 0 on ok status, 1 on error.

import AppKit
import Darwin
import Foundation
import OpenVMCore

let argv = Array(CommandLine.arguments.dropFirst())
guard let op = argv.first else {
    print(usage)
    exit(2)
}

var args: [(key: String, value: CBOR)] = []
var requestOp = op
var clipboardMode: String?
var fileCommand: FileCommand?
var dropCommand: DropCommand?
switch op {
case "create":
    guard argv.count >= 2 else {
        print(usage)
        exit(2)
    }
    args.append(("name", .text(argv[1])))
    var i = 2
    while i < argv.count {
        guard i + 1 < argv.count, argv[i].hasPrefix("--") else {
            print(usage)
            exit(2)
        }
        let key = String(argv[i].dropFirst(2))
        if ["cpus", "memoryMB", "diskSizeMB"].contains(key) {
            guard let v = UInt64(argv[i + 1]) else {
                print(usage)
                exit(2)
            }
            args.append((key, .uint(v)))
        } else if key == "boot-mode" {
            let mode = argv[i + 1]
            guard ["windows", "linux-iso", "linux"].contains(mode) else {  // the host says what replaced "linux"
                print(usage)
                exit(2)
            }
            args.append((key, .text(mode)))
        } else if key == "variable-store-path" || key == "install-media" {
            args.append((key, .text(argv[i + 1])))
        } else {
            print(usage)
            exit(2)
        }
        i += 2
    }
case "set":
    guard argv.count >= 2 else {
        print(usage)
        exit(2)
    }
    args.append(("id", .text(argv[1])))
    var i = 2
    while i < argv.count {
        guard i + 1 < argv.count, argv[i].hasPrefix("--") else {
            print(usage)
            exit(2)
        }
        let key = String(argv[i].dropFirst(2))
        switch key {
        case "cpus", "memoryMB":
            guard let v = UInt64(argv[i + 1]) else {
                print(usage)
                exit(2)
            }
            args.append((key, .uint(v)))
        case "tz":
            args.append((key, .text(argv[i + 1])))
        case "boot-mode":
            let mode = argv[i + 1]
            guard ["windows", "linux-iso", "linux"].contains(mode) else {  // the host says what replaced "linux"
                print(usage)
                exit(2)
            }
            args.append((key, .text(mode)))
        case "variable-store-path":
            args.append((key, .text(argv[i + 1])))
        case "clipboard-sync":
            guard ["on", "off"].contains(argv[i + 1]) else {
                print(usage)
                exit(2)
            }
            args.append((key, .bool(argv[i + 1] == "on")))
        default:
            print(usage)
            exit(2)
        }
        i += 2
    }
case "list":
    guard argv.count == 1 else {
        print(usage)
        exit(2)
    }
case "task":
    // Long jobs the host runs, from a fixed list: openvmctl task start fetch-linux
    if argv.count >= 3, argv[1] == "start" {
        requestOp = "task-start"
        args.append(("kind", .text(argv[2])))
        // windows-media takes the ISO to build from and a name for the media: --iso PATH --name NAME
        var i = 3
        while i + 1 < argv.count, ["--iso", "--name"].contains(argv[i]) {
            let value =
                argv[i] == "--iso" ? URL(fileURLWithPath: argv[i + 1]).standardizedFileURL.path : argv[i + 1]
            args.append((String(argv[i].dropFirst(2)), .text(value)))
            i += 2
        }
        guard i == argv.count else {
            print(usage)
            exit(2)
        }
    } else if argv.count == 3, ["status", "cancel"].contains(argv[1]) {
        requestOp = "task-\(argv[1])"
        args.append(("taskId", .text(argv[2])))
    } else {
        print(usage)
        exit(2)
    }
case "windows-iso" where argv.count == 3 && argv[1] == "check":
    // Is this ISO something a Windows guest can be built from?
    requestOp = "windows-iso-check"
    args.append(("iso", .text(URL(fileURLWithPath: argv[2]).standardizedFileURL.path)))
case "linux-iso" where argv.count == 3 && argv[1] == "check":
    // Can this ISO start on this Mac?
    requestOp = "linux-iso-check"
    args.append(("iso", .text(URL(fileURLWithPath: argv[2]).standardizedFileURL.path)))
case "eject" where argv.count == 2:
    // Take the installer ISO out of a stopped VM, so it starts from its disk.
    requestOp = "eject-installer"
    args.append(("id", .text(argv[1])))
case "host-info" where argv.count == 1:
    // What this Mac can give a VM, and what is ready.
    break
case "stop-all" where argv.count == 1:
    // Shut down every running guest, as quitting the app does.
    break
case "stop" where argv.count == 3 && argv[2] == "--no-wait":
    // Ask the guest to stop and return at once; the VM's record follows it.
    args.append(("id", .text(argv[1])))
    args.append(("wait", .bool(false)))
case "start", "stop", "ping", "info", "delete", "suspend", "resume":
    guard argv.count == 2 else {
        print(usage)
        exit(2)
    }
    args.append(("id", .text(argv[1])))
case "config":
    guard argv.count == 2, argv[1] == "schema" else {
        print(usage)
        exit(2)
    }
    print(
        """
        VM config record: $OPENVM_HOME/vms.json, one JSON array of records.
          {"uuid": <string>, "name": <string>, "state": stopped|starting|running|suspended|stopping,
           "cpus": <1…32>, "memoryMB": <>=128, "diskPath": <path>? , "createdAt": <ISO8601>}
        Evolution rules: later fields must decode as optional; breaking changes need
        a schemaVersion key (none today). Device sidecars and console paths derive
        from diskPath/OPENVM_HOME and are not stored. Full document: docs/vm-records.md.
        """)
    exit(0)
case "clipboard":
    guard argv.count == 3, ["push", "pull"].contains(argv[1]) else {
        print(usage)
        exit(2)
    }
    clipboardMode = argv[1]
    args.append(("id", .text(argv[2])))
    if argv[1] == "push" {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            fail("host clipboard has no text")
        }
        guard text.utf8.count <= 1_048_000 else {
            fail("host clipboard text exceeds the OVMC 1 MiB frame limit")
        }
        requestOp = "clipboard-write"
        args.append(("text", .text(text)))
    } else {
        requestOp = "clipboard-read"
    }
case "file":
    if argv.count == 4, argv[1] == "push" {
        let hostURL = URL(fileURLWithPath: argv[3]).standardizedFileURL
        let guestName = hostURL.lastPathComponent
        guard validGuestName(guestName) else { fail("invalid guest basename") }
        fileCommand = FileCommand(mode: "push", vmID: argv[2], guestName: guestName, hostURL: hostURL)
    } else if argv.count == 5, argv[1] == "push" {
        let hostURL = URL(fileURLWithPath: argv[3]).standardizedFileURL
        guard validGuestName(argv[4]) else { fail("invalid guest basename") }
        fileCommand = FileCommand(mode: "push", vmID: argv[2], guestName: argv[4], hostURL: hostURL)
    } else if argv.count == 5, argv[1] == "pull" {
        guard validGuestName(argv[3]) else { fail("invalid guest basename") }
        fileCommand = FileCommand(
            mode: "pull", vmID: argv[2], guestName: argv[3],
            hostURL: URL(fileURLWithPath: argv[4]).standardizedFileURL)
    } else {
        print(usage)
        exit(2)
    }
case "share":
    if argv.count == 3, argv[1] == "list" {
        requestOp = "share-list"
        args.append(("id", .text(argv[2])))
    } else if argv.count == 4, argv[1] == "add" {
        requestOp = "share-add"
        args.append(("id", .text(argv[2])))
        args.append(("hostPath", .text(argv[3])))
    } else if argv.count == 5, argv[1] == "add" {
        requestOp = "share-add"
        args.append(("id", .text(argv[2])))
        args.append(("hostPath", .text(argv[3])))
        args.append(("guestPath", .text(argv[4])))
    } else if argv.count == 4, argv[1] == "remove" {
        requestOp = "share-remove"
        args.append(("id", .text(argv[2])))
        args.append(("hostPath", .text(argv[3])))
    } else {
        print(usage)
        exit(2)
    }
case "drag":
    if argv.count == 3, ["enter", "leave"].contains(argv[1]) {
        requestOp = "drag"
        args.append(("id", .text(argv[2])))
        args.append(("op", .text(argv[1])))
    } else if argv.count == 4, argv[1] == "send" {
        // Runs the guest's send tool on a path inside the guest; what it sends lands in Downloads.
        requestOp = "drag"
        args.append(("id", .text(argv[2])))
        args.append(("op", .text("send")))
        args.append(("path", .text(argv[3])))
    } else if argv.count >= 4, argv[1] == "drop" {
        dropCommand = DropCommand(
            vmID: argv[2],
            paths: argv[3...].map {
                URL(fileURLWithPath: $0).standardizedFileURL.path
            })
    } else {
        print(usage)
        exit(2)
    }
case "printer":
    if argv.count == 3, argv[1] == "list" {
        requestOp = "printer"
        args.append(("id", .text(argv[2])))
        args.append(("op", .text("list")))
    } else if argv.count == 5, argv[1] == "test", argv[3] == "--name" {
        // Prints a page through the guest's own queue: the job then comes back
        // to the host the way any guest application's would.
        requestOp = "printer"
        args.append(("id", .text(argv[2])))
        args.append(("op", .text("test")))
        args.append(("name", .text(argv[4])))
    } else {
        print(usage)
        exit(2)
    }
case "audio":
    let turnsOn = argv.count == 4 && argv[1] == "enable" && argv[3] == "--test-mode"
    if turnsOn || (argv.count == 3 && ["status", "test", "disable"].contains(argv[1])) {
        requestOp = "audio"
        args.append(("id", .text(argv[2])))
        args.append(("op", .text(argv[1])))
        // Typing --test-mode is the consent; the host will not enable Windows sound without it.
        if turnsOn { args.append(("testMode", .bool(true))) }
    } else {
        print(usage)
        exit(2)
    }
case "display":
    if argv.count == 7 || argv.count == 9, argv[1] == "set", argv[3] == "--width", argv[5] == "--height" {
        requestOp = "display"
        args.append(("id", .text(argv[2])))
        args.append(("op", .text("set")))
        guard let w = UInt64(argv[4]), let h = UInt64(argv[6]) else {
            print(usage)
            exit(2)
        }
        args.append(("width", .uint(w)))
        args.append(("height", .uint(h)))
        if argv.count == 9 {
            guard argv[7] == "--scale", let scale = UInt64(argv[8]) else {
                print(usage)
                exit(2)
            }
            args.append(("scale", .uint(scale)))
        }
    } else if argv.count == 3, argv[1] == "capture" {
        // Grabs the guest's own screen into its staging directory; `file pull`
        // then fetches the name printed here.
        requestOp = "display"
        args.append(("id", .text(argv[2])))
        args.append(("op", .text("capture")))
    } else {
        print(usage)
        exit(2)
    }
default:
    print(usage)
    exit(2)
}

do {
    if let fileCommand {
        print(try transferFile(fileCommand))
        exit(0)
    }
    if let dropCommand {
        print(try runDrop(dropCommand))
        exit(0)
    }
    let reply = try daemonRequest(requestOp, args: args)
    guard case .map(let entries) = reply.body else { fail("reply body not a map") }
    let status = entries.first { $0.key == "status" }?.value
    if status == CBOR.text("ok") {
        if let clipboardMode,
            case .map(let result)? = entries.first(where: { $0.key == "result" })?.value,
            case .text(let text)? = result.first(where: { $0.key == "text" })?.value
        {
            if clipboardMode == "pull" {
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(text, forType: .string) else {
                    fail("could not write guest text to host clipboard")
                }
                print("guest clipboard copied to host")
            } else {
                print("host clipboard copied to guest")
            }
        }
        for e in entries where e.key == "result" || e.key == "uuid" {
            if e.key == "uuid", case .text(let u) = e.value { print("uuid=\(u)") }
        }
        if case .map(let res)? = (entries.first { $0.key == "result" }?.value),
            let m = (res.first { $0.key == "message" }?.value), case .text(let t) = m
        {
            print(t)
        }
        if case .map(let res)? = (entries.first { $0.key == "result" }?.value),
            let v = (res.first { $0.key == "vms" }?.value), case .array(let rows) = v
        {
            for row in rows { printRow(row) }
        }
        if case .map(let res)? = (entries.first { $0.key == "result" }?.value),
            let v = (res.first { $0.key == "shares" }?.value), case .array(let rows) = v
        {
            for row in rows { printRow(row) }
        }
        if ["host-info", "task-start", "task-status", "task-cancel", "windows-iso-check", "linux-iso-check"].contains(requestOp),
            case .map(let res)? = (entries.first { $0.key == "result" }?.value)
        {
            print(
                res.map { entry -> String in
                    switch entry.value {
                    case .uint(let n): return "\(entry.key)=\(n)"
                    case .bool(let b): return "\(entry.key)=\(b)"
                    case .text(let t): return "\(entry.key)=\(t)"
                    default: return entry.key
                    }
                }.joined(separator: "  "))
        }
        if requestOp == "audio", case .map(let res)? = (entries.first { $0.key == "result" }?.value),
            let audio = GuestAudioStatus(.map(res))
        {
            var host = false
            if case .bool(let running)? = (res.first { $0.key == "hostOutputRunning" }?.value) {
                host = running
            }
            let running = audio.running.map(String.init) ?? "unknown"
            print(
                "device=\(audio.device ?? "none") running=\(running) rate=\(audio.rate) "
                    + "hostOutputRunning=\(host)" + (audio.state.map { " state=\($0)" } ?? ""))
            if audio.state == "pending" {
                print(
                    "Stop and start the VM to finish. Windows then runs in Test Mode: driver "
                        + "signature checks are weaker and the desktop shows a watermark.")
            } else if argv[1] == "disable" {
                print("Stop and start the VM to leave Test Mode.")
            }
        }
        if case .map(let res)? = (entries.first { $0.key == "result" }?.value),
            case .text(let name)? = (res.first { $0.key == "capture" }?.value)
        {
            print(name)
        }
        if case .map(let res)? = (entries.first { $0.key == "result" }?.value),
            let v = (res.first { $0.key == "printers" }?.value), case .array(let rows) = v
        {
            for case .text(let name) in rows { print(name) }
        }
        exit(0)
    } else {
        if case .map(let res)? = (entries.first { $0.key == "result" }?.value),
            let m = (res.first { $0.key == "message" }?.value), case .text(let t) = m
        {
            fail(t)
        }
        fail("\(requestOp) failed")
    }
} catch let e as CLIError {
    fail(e.description)
} catch let e as VmRegistryError {
    fail(String(describing: e))
} catch let e as POSIXError where [.ENOENT, .ECONNREFUSED].contains(e.code) {
    fail("cannot reach daemon at \(sockPath): \(e.localizedDescription)")
} catch {
    // Not every failure is a connection failure, so name the real cause.
    fail("\(requestOp) failed: \(error)")
}

func printRow(_ item: CBOR) {
    guard case .map(let row) = item else { return }
    let parts = row.map { e -> String in
        switch e.value {
        case .text(let s): return "\(e.key)=\(s)"
        case .uint(let u): return "\(e.key)=\(u)"
        case .bool(let b): return "\(e.key)=\(b)"
        default: return "\(e.key)=?"
        }
    }
    print(parts.joined(separator: "  "))
}
