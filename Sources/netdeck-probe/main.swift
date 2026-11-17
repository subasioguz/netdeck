import Foundation
import NetdeckCore

// Command-line field tool: exercises NetdeckCore against a real switch without the app.
//
//   NETDECK_PASSWORD=... netdeck-probe --serial /dev/cu.usbserial-X --user root snapshot
//   NETDECK_PASSWORD=... netdeck-probe --ssh 192.0.2.10 --user admin preview "set interfaces ge-0/0/2 description X"
//   NETDECK_PASSWORD=... netdeck-probe --serial /dev/cu.usbserial-X compare 1
//
// `preview` loads the commands into the candidate configuration, prints the switch's own diff and
// `commit check` result, then discards everything with `rollback 0`. This tool never commits.

struct Options {
    var serial: String?
    var baud = 9600
    var ssh: String?
    var user = "root"
    var keepSession = false
    var rest: [String] = []
}

func parseOptions() -> Options {
    var args = Array(CommandLine.arguments.dropFirst())
    func take(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        let v = args[i + 1]
        args.removeSubrange(i...(i + 1))
        return v
    }
    var o = Options()
    o.serial = take("--serial")
    o.baud = Int(take("--baud") ?? "9600") ?? 9600
    o.ssh = take("--ssh")
    o.user = take("--user") ?? "root"
    o.keepSession = args.contains("--keep-session")
    args.removeAll { $0 == "--keep-session" }
    o.rest = args
    return o
}

L10n.language = .en
let opts = parseOptions()
let command = opts.rest.first ?? "snapshot"
let password = ProcessInfo.processInfo.environment["NETDECK_PASSWORD"]

guard opts.serial != nil || opts.ssh != nil else {
    FileHandle.standardError.write(Data("""
    usage: netdeck-probe (--serial PATH [--baud N] | --ssh HOST) [--user U] [--keep-session]
                         [snapshot | preview "cmd; cmd" | compare N]
    password: NETDECK_PASSWORD environment variable

    """.utf8))
    exit(2)
}

let transport: Transport = opts.serial.map { SerialTransport(path: $0, baud: opts.baud) as Transport }
    ?? SSHTransport(host: opts.ssh!, username: opts.user, password: password)
let driver = JunosDriver(transport: transport)

func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: max(n, s.count), withPad: " ", startingAt: 0) }

@MainActor
func run() async -> Int32 {
    let t0 = Date()
    func elapsed() -> String { String(format: "%.1fs", Date().timeIntervalSince(t0)) }
    if command == "session", let path = opts.serial {
        // Exercises the app's session layer: read, log out, then read again (logs back in and out).
        let session = DeviceSession(profile: DeviceProfile(name: "probe", platform: .juniperJunos,
                                                           connection: .serial(path: path, baud: opts.baud), username: opts.user))
        await session.connect(password: password)
        print("connect → phase \(session.phase), ports \(session.snapshot?.ports.count ?? 0), connected \(session.isConnected), offline \(session.isOffline) (\(elapsed()))")
        await session.refresh()
        print("refresh → phase \(session.phase), ports \(session.snapshot?.ports.count ?? 0), connected \(session.isConnected) (\(elapsed()))")
        if let e = session.lastError { print("error: \(e)") }
        return session.lastError == nil ? 0 : 1
    }
    do {
        print("→ connecting: \(transport.displayName)")
        try await driver.connect(username: opts.user, password: password)
        print("✓ logged in (\(elapsed()))")

        switch command {
        case "snapshot":
            let s = try await driver.loadSnapshot { step in print("  [\(step.index + 1)/\(step.total)] \(step.title)") }
            print("✓ read (\(elapsed()))")
            print("\n\(s.hostname) · \(s.model) · Junos \(s.version.junos ?? "?") · serial \(s.hardware.serial ?? "?")")
            print("VLANs: " + s.config.vlans.map { "\($0.vlanID.map(String.init) ?? "?"):\($0.name)" }.joined(separator: ", "))
            let ports = s.ports
            let counts = Dictionary(grouping: ports, by: \.state).mapValues(\.count)
            print("Ports: \(ports.count) · " + counts.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: " "))
            for p in ports where p.state != .disabled {
                let who = p.macs.prefix(2).map { m in m.mac + (Vendors.lookup(m.mac).map { " (\($0))" } ?? "") }.joined(separator: ", ")
                var line = "  \(pad(p.name, 10)) \(pad(p.state.rawValue, 8)) \(pad(p.description ?? "—", 16)) VLAN \(p.vlans.joined(separator: ","))  \(p.macs.count) MAC \(who)"
                if let w = p.warning { line += "  ⚠︎ \(w)" }
                print(line)
            }
            for r in s.rearPorts { print("  rear \(r.name) \(r.role.rawValue) \(r.statusText)") }
            print("Last commit: " + (s.commits.first.map { "\($0.timestamp) \($0.user) — \($0.comment ?? "")" } ?? "—"))
        case "preview":
            let cmds = (opts.rest.dropFirst().first ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let r = try await driver.preview(cmds)
            print("── switch diff ──\n\(r.diff)\n── commit check: \(r.checkPassed ? "passed" : "FAILED") ──")
            if !r.checkPassed { print(r.checkOutput) }
            print("(candidate discarded; nothing was applied to the switch)")
        case "compare":
            let n = Int(opts.rest.dropFirst().first ?? "1") ?? 1
            print(try await driver.compare(rollback: n))
        default:
            print("unknown command: \(command)")
        }
        if !opts.keepSession { await driver.disconnect() }
        return 0
    } catch {
        print("✗ error: \(error.localizedDescription)")
        await driver.disconnect()
        return 1
    }
}

let code = await run()
exit(code)
