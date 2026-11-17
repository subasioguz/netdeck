import Foundation

/// Pure parsers for EdgeOS (EdgeRouter) CLI output. Inputs are command output without the echoed
/// command and the trailing prompt, as `CLISession.run` returns it.
public enum EdgeOSParsers {

    // MARK: show version

    public struct Version: Equatable, Sendable {
        public var version: String?
        public var buildID: String?
        public var model: String?
        public var serial: String?
        public var uptime: String?
    }

    /// `Version:      v2.0.9-hotfix.7` / `HW model:     EdgeRouter X 5-Port` / `HW S/N: ...` / `Uptime: ...`.
    public static func version(_ text: String) -> Version {
        var v = Version()
        for line in text.components(separatedBy: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch key {
            case "Version": v.version = value
            case "Build ID": v.buildID = value
            case "HW model": v.model = value
            case "HW S/N": v.serial = value
            case "Uptime": v.uptime = value
            default: break
            }
        }
        return v
    }

    /// The `show version` output of an EdgeOS device (EdgeRouter or EdgePoint), not VyOS or another Vyatta.
    public static func isEdgeOS(_ versionText: String) -> Bool {
        let v = version(versionText)
        guard v.version != nil, v.model != nil else { return false }
        return ["EdgeRouter", "EdgeOS", "EdgePoint", "Ubiquiti", "UBNT"].contains { versionText.contains($0) }
    }

    // MARK: show configuration commands

    /// The parts of `show configuration commands` Netdeck reads.
    public struct Config: Equatable, Sendable {
        public struct Vif: Equatable, Sendable {
            public var description: String?
            public var addresses: [String] = []
            public var pppoe: [Int] = []
            public var disabled = false
        }

        public struct Ethernet: Equatable, Sendable {
            public var description: String?
            public var disabled = false
            public var addresses: [String] = []
            /// `pppoe N` sessions on the port itself.
            public var pppoe: [Int] = []
            public var vifs: [Int: Vif] = [:]
        }

        public var hostname: String?
        /// Every `interfaces ethernet ethN` seen, also those with only `duplex`/`speed` lines.
        public var ethernet: [String: Ethernet] = [:]
        public var hasSwitch0 = false
        public var vlanAware = false
        public var members: [String: EdgeOSState.SwitchMember] = [:]
        public var switchVifs: [Int: Vif] = [:]
        public var switchAddresses: [String] = []
        public var lines: [String] = []
    }

    public static func config(_ text: String) -> Config {
        var cfg = Config()
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("set ") else { continue }
            cfg.lines.append(line)
            let w = tokenize(line)
            guard w.count >= 3 else { continue }
            switch w[1] {
            case "system":
                if w[2] == "host-name", w.count > 3 { cfg.hostname = w[3] }
            case "interfaces":
                guard w.count >= 4 else { continue }
                if w[2] == "ethernet" {
                    ethernetStatement(port: w[3], Array(w.dropFirst(4)), into: &cfg)
                } else if w[2] == "switch", w[3] == "switch0" {
                    switchStatement(Array(w.dropFirst(4)), into: &cfg)
                }
            default:
                break
            }
        }
        return cfg
    }

    private static func ethernetStatement(port: String, _ rest: [String], into cfg: inout Config) {
        var e = cfg.ethernet[port] ?? Config.Ethernet()
        switch rest.first ?? "" {
        case "description": if rest.count > 1 { e.description = rest[1] }
        case "disable": e.disabled = true
        case "address": if rest.count > 1, !e.addresses.contains(rest[1]) { e.addresses.append(rest[1]) }
        case "pppoe": if rest.count > 1, let n = Int(rest[1]), !e.pppoe.contains(n) { e.pppoe.append(n) }
        case "vif":
            if rest.count > 1, let id = Int(rest[1]) {
                var v = e.vifs[id] ?? Config.Vif()
                vifStatement(Array(rest.dropFirst(2)), into: &v)
                e.vifs[id] = v
            }
        default: break
        }
        cfg.ethernet[port] = e
    }

    private static func switchStatement(_ rest: [String], into cfg: inout Config) {
        cfg.hasSwitch0 = true
        switch rest.first ?? "" {
        case "address":
            if rest.count > 1, !cfg.switchAddresses.contains(rest[1]) { cfg.switchAddresses.append(rest[1]) }
        case "switch-port":
            let r = Array(rest.dropFirst())
            if r.first == "vlan-aware" {
                cfg.vlanAware = r.count > 1 && r[1] == "enable"
            } else if r.first == "interface", r.count > 1 {
                let port = r[1]
                var m = cfg.members[port] ?? EdgeOSState.SwitchMember()
                if r.count > 4, r[2] == "vlan", let n = Int(r[4]) {
                    if r[3] == "pvid" { m.pvid = n }
                    if r[3] == "vid", !m.vids.contains(n) { m.vids.append(n) }
                }
                cfg.members[port] = m
            }
        case "vif":
            if rest.count > 1, let id = Int(rest[1]) {
                var v = cfg.switchVifs[id] ?? Config.Vif()
                vifStatement(Array(rest.dropFirst(2)), into: &v)
                cfg.switchVifs[id] = v
            }
        default:
            break
        }
    }

    private static func vifStatement(_ rest: [String], into v: inout Config.Vif) {
        switch rest.first ?? "" {
        case "description": if rest.count > 1 { v.description = rest[1] }
        case "address": if rest.count > 1, !v.addresses.contains(rest[1]) { v.addresses.append(rest[1]) }
        case "pppoe": if rest.count > 1, let n = Int(rest[1]), !v.pppoe.contains(n) { v.pppoe.append(n) }
        case "disable": v.disabled = true
        default: break
        }
    }

    /// Splits a `set` line into words like the EdgeOS shell does: single quotes keep everything literally,
    /// double quotes allow backslash escapes, and quoted parts glue to their neighbours (`'it'\''s'`).
    public static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inToken = false
        var quote: Character?
        var escaped = false
        for ch in line {
            if escaped {
                current.append(ch)
                escaped = false
                inToken = true
                continue
            }
            if let q = quote {
                if ch == q { quote = nil } else if ch == "\\" && q == "\"" { escaped = true } else { current.append(ch) }
                continue
            }
            switch ch {
            case "'", "\"":
                quote = ch
                inToken = true
            case "\\":
                escaped = true
            case " ", "\t":
                if inToken { tokens.append(current) }
                current = ""
                inToken = false
            default:
                current.append(ch)
                inToken = true
            }
        }
        if inToken { tokens.append(current) }
        return tokens
    }

    /// Quotes a value for a configuration-mode command: bare when it is one plain word, else in single
    /// quotes (as `show configuration commands` prints it), double quotes when it holds a single quote.
    public static func quote(_ value: String) -> String {
        let plain = CharacterSet.alphanumerics
        let extra = "-_./:@+,=".unicodeScalars
        let isPlain = !value.isEmpty && value.unicodeScalars.allSatisfy { $0.isASCII && (plain.contains($0) || extra.contains($0)) }
        if isPlain { return value }
        if !value.contains("'") { return "'" + value + "'" }
        var escaped = value
        for special in ["\\", "\"", "$", "`"] { escaped = escaped.replacingOccurrences(of: special, with: "\\" + special) }
        return "\"" + escaped + "\""
    }

    /// "eth12" → 12. Nil for anything else ("eth0.7", "switch0", "lo").
    public static func ethNumber(_ name: String) -> Int? {
        guard name.hasPrefix("eth") else { return nil }
        let tail = name.dropFirst(3)
        guard !tail.isEmpty, tail.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(tail)
    }

    /// Port order: eth ports by number, anything else after them by name.
    static func portOrder(_ a: String, _ b: String) -> Bool {
        (ethNumber(a) ?? Int.max, a) < (ethNumber(b) ?? Int.max, b)
    }

    // MARK: show interfaces

    public struct InterfaceRow: Equatable, Sendable {
        public var name: String
        public var addresses: [String]
        public var adminUp: Bool
        public var linkUp: Bool
        public var description: String?
    }

    /// `show interfaces`: one row per interface with the S/L column (`u/u`, `u/D`, `A/D`); further
    /// addresses of an interface follow on indented lines.
    public static func interfaces(_ text: String) -> [InterfaceRow] {
        var out: [InterfaceRow] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if line.first == " " || line.first == "\t" {
                if !out.isEmpty, !trimmed.contains(" "), trimmed != "-" { out[out.count - 1].addresses.append(trimmed) }
                continue
            }
            let cols = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 2,
                  let i = cols.firstIndex(where: { $0.range(of: #"^[uDA]/[uDA]$"#, options: .regularExpression) != nil }),
                  i >= 1 else { continue }
            let state = cols[i]
            var description: String?
            if let r = line.range(of: #"\s[uDA]/[uDA](\s+|$)"#, options: .regularExpression) {
                let d = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                description = d.isEmpty ? nil : d
            }
            // DSA member ports may print as "eth1@eth0"; the part before "@" is the name used in commands.
            let name = cols[0].split(separator: "@").first.map(String.init) ?? cols[0]
            out.append(InterfaceRow(name: name, addresses: cols[1..<i].filter { $0 != "-" },
                                    adminUp: state.first != "A", linkUp: state.last == "u", description: description))
        }
        return out
    }

    // MARK: show arp

    public struct ARPEntry: Equatable, Sendable {
        public var address: String
        public var mac: String
        public var flags: String
        public var interface: String
    }

    /// `show arp`: `Address  HWtype  HWaddress  Flags Mask  Iface`. Incomplete entries have no MAC and are skipped.
    public static func arp(_ text: String) -> [ARPEntry] {
        let macPattern = #"^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$"#
        var out: [ARPEntry] = []
        for line in text.components(separatedBy: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 3,
                  let m = cols.firstIndex(where: { $0.range(of: macPattern, options: .regularExpression) != nil }),
                  m > 0, m < cols.count - 1 else { continue }
            let flags = m + 1 < cols.count - 1 ? cols[m + 1] : ""
            out.append(ARPEntry(address: cols[0], mac: cols[m].lowercased(), flags: flags, interface: cols[cols.count - 1]))
        }
        return out
    }

    // MARK: show lldp neighbors

    /// `show lldp neighbors` in either form EdgeOS may print: the lldpd detail blocks
    /// (`Interface: eth1, via: LLDP` / `SysName:` / `PortID:`) or the table
    /// (`Device ID  Local  Proto  Cap  Platform  Port ID`). Anything else gives no neighbors.
    public static func lldpNeighbors(_ text: String) -> [LLDPNeighbor] {
        if text.contains("Interface:"), text.contains("ChassisID:") || text.contains("SysName:") {
            return lldpBlocks(text)
        }
        return lldpTable(text)
    }

    private static func lldpBlocks(_ text: String) -> [LLDPNeighbor] {
        var out: [LLDPNeighbor] = []
        var local: String? = nil
        var chassis = "", name = "", portID = "", portIDKind = ""
        var portDescr: String? = nil

        func flush() {
            guard let l = local, !l.isEmpty else { return }
            let port = portIDKind == "ifname" || portDescr == nil ? portID : (portDescr ?? portID)
            out.append(LLDPNeighbor(localInterface: l, chassisID: chassis, portInfo: port, systemName: name))
        }
        func value(_ line: String) -> String {
            guard let colon = line.firstIndex(of: ":") else { return "" }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        /// "mac 48:a9:8a:00:00:01" → ("mac", "48:a9:8a:00:00:01")
        func subtyped(_ v: String) -> (String, String) {
            let parts = v.split(separator: " ", maxSplits: 1).map(String.init)
            let kinds = ["mac", "ifname", "local", "ip", "ifalias"]
            if parts.count == 2, kinds.contains(parts[0]) { return (parts[0], parts[1]) }
            return ("", v)
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Interface:") {
                flush()
                local = value(line).split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) }
                chassis = ""; name = ""; portID = ""; portIDKind = ""; portDescr = nil
            } else if line.hasPrefix("ChassisID:") {
                chassis = subtyped(value(line)).1
            } else if line.hasPrefix("SysName:") {
                name = value(line)
            } else if line.hasPrefix("PortID:") {
                (portIDKind, portID) = subtyped(value(line))
            } else if line.hasPrefix("PortDescr:") {
                let d = value(line)
                portDescr = d.isEmpty ? nil : d
            }
        }
        flush()
        return out
    }

    private static func lldpTable(_ text: String) -> [LLDPNeighbor] {
        let lines = text.components(separatedBy: "\n")
        guard let h = lines.firstIndex(where: { $0.hasPrefix("Device ID") && $0.contains("Local") }) else { return [] }
        let header = lines[h]
        func col(_ title: String) -> Int? {
            header.range(of: title).map { header.distance(from: header.startIndex, to: $0.lowerBound) }
        }
        guard let cLocal = col("Local"), let cPort = col("Port ID") else { return [] }
        let afterLocal = [col("Proto"), col("Cap"), col("Platform"), cPort].compactMap { $0 }.filter { $0 > cLocal }.min()
        func slice(_ s: String, _ a: Int, _ b: Int?) -> String {
            let chars = Array(s)
            guard a < chars.count else { return "" }
            let end = min(b ?? chars.count, chars.count)
            return String(chars[a..<max(a, end)]).trimmingCharacters(in: .whitespaces)
        }
        var out: [LLDPNeighbor] = []
        for line in lines[(h + 1)...] {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !t.hasPrefix("-") else { continue }
            let local = slice(line, cLocal, afterLocal).split(separator: " ").first.map(String.init) ?? ""
            guard !local.isEmpty else { continue }
            out.append(LLDPNeighbor(localInterface: local, chassisID: "", portInfo: slice(line, cPort, nil),
                                    systemName: slice(line, 0, cLocal)))
        }
        return out
    }

    // MARK: show system commit

    /// `show system commit`: `0   2024-03-01 10:00:00 by ubnt via cli`, a commit comment on the next,
    /// indented line. Unknown formats give an empty history.
    public static func commitHistory(_ text: String) -> [CommitEntry] {
        let pattern = #"^\s*(\d+)\s+(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}(?:\s+[A-Z]{2,5})?)\s+by\s+(\S+)\s+via\s+(\S+)(.*)$"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        var out: [CommitEntry] = []
        for line in text.components(separatedBy: "\n") {
            let ns = line as NSString
            if let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let g = { (i: Int) in ns.substring(with: m.range(at: i)) }
                let stamp = g(2).split(whereSeparator: \.isWhitespace).joined(separator: " ")
                let rest = g(5).lowercased()
                out.append(CommitEntry(index: Int(g(1)), isRescue: false, timestamp: stamp, user: g(3), client: g(4),
                                       confirmed: rest.contains("confirm") || g(4).lowercased().contains("confirm"),
                                       comment: nil))
            } else if line.first == " " || line.first == "\t", !out.isEmpty, out[out.count - 1].comment == nil {
                let c = line.trimmingCharacters(in: .whitespaces)
                if !c.isEmpty { out[out.count - 1].comment = c }
            }
        }
        return out
    }

    // MARK: Configuration mode

    /// Lines that mean the CLI rejected a command (`set`, `delete`, `commit`, `load`...).
    public static func errors(in text: String) -> [String] {
        text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { l in
            l.hasPrefix("Invalid ") || l.contains("is not valid") || l.hasPrefix("Value validation failed")
                || l.hasPrefix("Set failed") || l.hasPrefix("Delete failed") || l.contains("Commit failed")
                || l.hasPrefix("Error:") || l.hasPrefix("error:") || l.hasPrefix("Cannot load")
        }
    }

    /// `compare` (working against active configuration) shows uncommitted changes.
    public static func compareShowsChanges(_ output: String) -> Bool {
        let t = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.contains("No changes") { return false }
        return errors(in: t).isEmpty
    }

    /// Whether the running configuration matches the saved one (/config/config.boot).
    public enum SavedState: Equatable, Sendable { case same, differs, unknown }

    /// Reads `compare saved`, run while the working configuration equals the active one. Only a message
    /// that names the saved configuration counts as "same": an EdgeOS without `compare saved` may answer
    /// with the plain working-vs-active message instead.
    public static func savedState(_ output: String) -> SavedState {
        let t = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !errors(in: t).isEmpty { return .unknown }
        if t.contains("No changes between working and saved") { return .same }
        if t.contains("No changes") { return .unknown }
        let diffLine = t.components(separatedBy: "\n").contains { l in
            l.hasPrefix("+") || l.hasPrefix("-") || l.hasPrefix("[edit") || l.hasPrefix(">") || l.hasPrefix("<")
        }
        return diffLine ? .differs : .unknown
    }

    /// What `commit-confirm N` did.
    public enum CommitConfirmResult: Equatable, Sendable {
        /// The reboot timer runs and the commit went through.
        case armed
        /// No timer runs and nothing was committed. Carries the reason when the safety net itself is missing.
        case notArmed(String?)
        /// The timer was armed but the commit reported errors, so part of the change may be active.
        case commitFailed
    }

    /// Classifies the output of `commit-confirm N` (plus the answer to its `Proceed?` question when
    /// `answered`). Once the question was answered, or the output speaks of the reboot, and no failure
    /// shows, the timer counts as armed: a timer Netdeck doesn't know about would restart the router
    /// unexpectedly, while a timer that isn't there only makes `confirm` report nothing pending.
    public static func commitConfirmResult(_ output: String, answered: Bool) -> CommitConfirmResult {
        let o = output.lowercased()
        if o.contains("commit-revisions is not configured") {
            return .notArmed(t("The router keeps no commit revisions, so EdgeOS can't arm its confirm timer. Turn on commit revisions (system config-management commit-revisions) first."))
        }
        if o.contains("another confirm is pending") {
            return .notArmed(t("Another change on the router is already waiting for confirmation. Confirm it or let its timer run out first."))
        }
        if o.contains("no configuration changes to commit") || o.contains("canceled") || o.contains("cancelled")
            || o.contains("unable to schedule") {
            return .notArmed(nil)
        }
        // The refusals above all come before the timer is set; what's left that speaks of the reboot armed it.
        let scheduled = answered || o.contains("reboot") || o.contains("type 'confirm'")
        if scheduled { return o.contains("commit failed") ? .commitFailed : .armed }
        if o.contains("invalid command") {
            return .notArmed(t("This EdgeOS version has no commit-confirm, so Netdeck can't apply changes with a safety timer."))
        }
        return .notArmed(nil)
    }

    /// `confirm` found no commit-confirm timer ("No confirm pending.").
    public static func nothingPending(_ confirmOutput: String) -> Bool {
        let o = confirmOutput.lowercased()
        return o.contains("nothing to confirm") || o.range(of: #"\bno(t)?\b[^\n]*\bpending\b"#, options: .regularExpression) != nil
    }

    /// A plain `commit` went through ("No configuration changes to commit" counts as success).
    public static func commitSucceeded(_ output: String) -> Bool {
        !output.lowercased().contains("commit failed") && errors(in: output).isEmpty
    }

    /// `save` wrote /config/config.boot ("Saving configuration to '/config/config.boot'... Done").
    public static func saveSucceeded(_ output: String) -> Bool {
        errors(in: output).isEmpty && !output.lowercased().contains("failed")
    }
}
