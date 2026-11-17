import Foundation
import NetdeckCore

// Command-line field tool: exercises NetdeckCore against a real device without the app.
//
//   NETDECK_PASSWORD=... netdeck-probe --serial /dev/cu.usbserial-X --user root snapshot
//   NETDECK_PASSWORD=... netdeck-probe --ssh 192.0.2.10 --user admin --platform cisco snapshot
//   NETDECK_PASSWORD=... netdeck-probe --api https://192.0.2.30 --user root snapshot
//   NETDECK_PASSWORD=... netdeck-probe --ssh 192.0.2.10 --user admin preview "set interfaces ge-0/0/2 description X"
//   NETDECK_PASSWORD=... netdeck-probe --serial /dev/cu.usbserial-X compare 1
//
// `snapshot` goes through the app's session layer: it detects the platform (unless --platform is
// given), reads everything and logs out. `preview` asks the device what the commands would change
// and throws them away (Junos and EdgeOS show the device's own diff; IOS and RouterOS have no
// candidate configuration, so nothing is sent). This tool never applies or commits anything.

struct Options {
    var serial: String?
    var baud = 9600
    var ssh: String?
    var sshPort = 22
    var api: String?
    var user = "root"
    var platform: Platform?
    var keepSession = false
    var rest: [String] = []
}

let platformNames: [String: Platform] = [
    "junos": .juniperJunos, "mikrotik": .mikrotikRouterOS, "routeros": .mikrotikRouterOS, "cisco": .ciscoIOS, "ios": .ciscoIOS,
    "edgeos": .ubiquitiEdgeOS, "idrac": .dellIDRAC, "redfish": .redfish, "synology": .synologyDSM, "truenas": .truenas,
]

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
    o.sshPort = Int(take("--port") ?? "22") ?? 22
    o.api = take("--api")
    o.user = take("--user") ?? "root"
    o.platform = take("--platform").flatMap { platformNames[$0.lowercased()] }
    o.keepSession = args.contains("--keep-session")
    args.removeAll { $0 == "--keep-session" }
    o.rest = args
    return o
}

L10n.language = .en
let opts = parseOptions()
let command = opts.rest.first ?? "snapshot"
let password = ProcessInfo.processInfo.environment["NETDECK_PASSWORD"]

let connection: DeviceProfile.Connection
if let path = opts.serial {
    connection = .serial(path: path, baud: opts.baud)
} else if let host = opts.ssh {
    connection = .ssh(host: host, port: opts.sshPort)
} else if let url = opts.api {
    connection = .api(url: url)
} else {
    FileHandle.standardError.write(Data("""
    usage: netdeck-probe (--serial PATH [--baud N] | --ssh HOST [--port N] | --api URL) [--user U]
                         [--platform junos|mikrotik|cisco|edgeos|idrac|redfish|synology|truenas] [--keep-session]
                         [snapshot | session | preview "cmd; cmd" | compare N]
    password: NETDECK_PASSWORD environment variable

    """.utf8))
    exit(2)
}

let profile = DeviceProfile(name: "probe", platform: opts.platform, connection: connection, username: opts.user)

func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: max(n, s.count), withPad: " ", startingAt: 0) }

func printSnapshot(_ s: SwitchSnapshot) {
    print("\n\(s.hostname) · \(s.platform.displayName) · \(s.model) · \(s.platform.osName) \(s.osVersion ?? "?") · serial \(s.hardware.serial ?? "?")")
    print("VLANs: " + s.config.vlans.map { "\($0.vlanID.map(String.init) ?? "?"):\($0.name)" }.joined(separator: ", "))
    let ports = s.ports
    let counts = Dictionary(grouping: ports, by: \.state).mapValues(\.count)
    print("Ports: \(ports.count) · " + counts.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: " "))
    for p in ports where p.state != .disabled {
        let who = p.macs.prefix(2).map { m in m.mac + (Vendors.lookup(m.mac).map { " (\($0))" } ?? "") }.joined(separator: ", ")
        var line = "  \(pad(p.name, 12)) \(pad(p.kind.rawValue, 6)) \(pad(p.state.rawValue, 8)) \(pad(p.description ?? "—", 16))"
        line += p.isRouted ? " routed \(p.addresses.joined(separator: ","))" : " VLAN \(p.vlans.joined(separator: ","))"
        line += "  \(p.macs.count) MAC \(who)"
        if let z = p.zone { line += "  zone \(z)" }
        if let w = p.warning { line += "  ⚠︎ \(w)" }
        print(line)
    }
    for r in s.rearPorts { print("  rear \(r.name) \(r.role.rawValue) \(r.statusText)") }
    print("Last commit: " + (s.commits.first.map { "\($0.timestamp) \($0.user) — \($0.comment ?? "")" } ?? "—"))
}

func printAppliance(_ a: ApplianceSnapshot) {
    print("\n\(a.hostname ?? "?") · \(a.platform.displayName) · \(a.model ?? "?") · \(a.osVersion ?? "?") · serial \(a.serial ?? "?")")
    print("Power \(a.power.rawValue) · health \(a.health.rawValue) (worst \(a.worstHealth.rawValue))")
    for f in a.facts + a.firmware { print("  \(pad(f.label, 18)) \(f.value)") }
    for p in a.pools { print("  pool \(p.name) \(p.status) \(p.layout ?? "") \(p.usedBytes ?? 0)/\(p.sizeBytes ?? 0)") }
    for d in a.disks { print("  disk \(pad(d.name, 22)) \(d.model ?? "") \(d.type ?? "") \(d.health.rawValue)") }
    for s in a.sensors { print("  \(s.kind.rawValue) \(pad(s.name, 26)) \(s.reading.map { String(format: "%.0f", $0) } ?? "—") \(s.unit) \(s.health.rawValue)") }
    for c in a.components { print("  \(pad(c.name, 22)) \(c.detail ?? "") \(c.health.rawValue)") }
    for i in a.interfaces { print("  if \(pad(i.name, 22)) \(i.mac ?? "") \(i.linkUp.map { $0 ? "up" : "down" } ?? "?") \(i.addresses.joined(separator: ","))") }
    for alert in a.alerts { print("  ⚠︎ \(alert)") }
    if !a.powerActions.isEmpty { print("  power actions: \(a.powerActions.map(\.rawValue).joined(separator: ", ")) (never sent by the probe)") }
}

@MainActor
func run() async -> Int32 {
    let t0 = Date()
    func elapsed() -> String { String(format: "%.1fs", Date().timeIntervalSince(t0)) }

    if command == "snapshot" || command == "session" {
        // The app's session layer: detect, log in, read, log out (serial), read again for `session`.
        let session = DeviceSession(profile: profile, stagedStore: nil)
        print("→ connecting: \(profile.connectionLabel)")
        await session.connect(password: password)
        print("connect → phase \(session.phase) (\(elapsed()))")
        if let d = session.detection { print("detected: \(d.summary)") }
        if command == "session" {
            await session.refresh()
            print("refresh → phase \(session.phase), connected \(session.isConnected) (\(elapsed()))")
        }
        if let s = session.snapshot { printSnapshot(s) }
        if let a = session.appliance { printAppliance(a) }
        if let e = session.lastError { print("✗ error: \(e)") }
        if !opts.keepSession { await session.disconnect() }
        return session.lastError == nil ? 0 : 1
    }

    let platform = opts.platform ?? DriverFactory.fallbackPlatform(for: connection.type)
    guard let driver = DriverFactory.make(platform: platform, profile: profile, password: password) else {
        print("✗ no driver for \(platform.displayName) over \(connection.type.rawValue)")
        return 2
    }
    do {
        print("→ connecting: \(profile.connectionLabel) as \(platform.displayName)")
        try await driver.connect(username: opts.user, password: password)
        print("✓ logged in (\(elapsed()))")
        switch command {
        case "preview":
            let cmds = (opts.rest.dropFirst().first ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let plan = ChangePlan(changes: [PlannedChange(kind: .port, subject: "probe", summary: "", commands: cmds)])
            let r = try await driver.preview(plan)
            print("── device diff ──\n\(r.diff)\n── check: \(r.checkPassed ? "passed" : "FAILED") ──")
            if !r.checkOutput.isEmpty { print(r.checkOutput) }
            print("(nothing was applied to the device)")
        case "compare":
            let n = Int(opts.rest.dropFirst().first ?? "1") ?? 1
            print(try await driver.compare(rollback: n, to: 0))
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
