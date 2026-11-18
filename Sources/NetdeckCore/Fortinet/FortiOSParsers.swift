import Foundation

/// `get system status`.
public struct FortiOSStatus: Equatable, Sendable {
    /// "FortiGate-60F", "FortiWiFi-40F", "FortiGate-VM64-KVM".
    public var model: String?
    /// "7.4.8".
    public var version: String?
    /// "2795".
    public var build: String?
    public var serial: String?
    public var hostname: String?
    /// Virtual domains are on ("multiple", "split-task"): interfaces and the ARP table live under
    /// `config global` / per VDOM instead of the top level.
    public var vdoms = false
    /// "standalone", "a-p", "a-a".
    public var haMode: String?
    public var operationMode: String?
}

/// One port of `get system interface physical`.
public struct FortiOSPhysicalPort: Equatable, Sendable {
    public var name: String
    public var linkUp = false
    /// "1000Mbps", nil when there is no link ("n/a").
    public var speed: String?
    /// "full" / "half".
    public var duplex: String?
}

/// One interface of `config system interface`.
public struct FortiOSInterface: Equatable, Sendable {
    public var name: String
    public var vdom: String?
    /// "physical", "hard-switch", "switch", "aggregate", "redundant", "loopback", "tunnel", "vlan"...
    /// VLAN interfaces often print no type: they are the ones with a `vlanid`.
    public var type: String?
    public var alias: String?
    public var description: String?
    public var down = false
    /// "dhcp", "pppoe" or "static".
    public var mode: String?
    /// "192.0.2.1/24"; nil without an address (0.0.0.0).
    public var address: String?
    /// The interface a VLAN rides on (`set interface`).
    public var parent: String?
    public var vlanID: Int?
    /// Aggregate and redundant members (`set member`).
    public var members: [String] = []
    public var role: String?

    public var isVLAN: Bool { vlanID != nil }

    /// What the interface itself carries: its address, "dhcp" or "pppoe".
    public var addressText: String? {
        switch mode {
        case "dhcp": return address.map { "\($0) (dhcp)" } ?? "dhcp"
        case "pppoe": return address.map { "\($0) (pppoe)" } ?? "pppoe"
        default: return address
        }
    }
}

public struct FortiOSARPEntry: Equatable, Sendable {
    public var ip: String
    public var mac: String
    public var interface: String
}

/// One `edit` entry of a `config` table: its `set` lines and the entry names of tables nested in it
/// (`config port` inside a virtual switch).
public struct FortiOSConfigEntry: Equatable, Sendable {
    public var name: String
    public var settings: [String: [String]] = [:]
    public var nested: [String: [String]] = [:]

    public func value(_ key: String) -> String? { settings[key]?.first }
}

/// Parsers for FortiOS command output. Pure, so they are unit-tested with captures.
public enum FortiOSParsers {
    /// `get system status` of a FortiGate or FortiWiFi.
    public static func isFortiGate(_ s: String) -> Bool {
        s.range(of: #"(?m)^Version:\s*Forti(Gate|WiFi)"#, options: .regularExpression) != nil
    }

    /// The console's login prompt ("FortiGate-60F login:").
    public static func isLoginBanner(_ s: String) -> Bool {
        s.range(of: #"(?m)^Forti(Gate|WiFi)[\w\-]* login:"#, options: .regularExpression) != nil
    }

    public static func status(_ s: String) -> FortiOSStatus {
        var st = FortiOSStatus()
        for raw in s.components(separatedBy: "\n") {
            guard let colon = raw.firstIndex(of: ":") else { continue }
            let key = raw[..<colon].trimmingCharacters(in: .whitespaces)
            let value = raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "Version":
                // "FortiGate-60F v7.4.8,build2795,250523 (GA.M)"
                if let c = CiscoParsers.capture(#"^(\S+)\s+v(\d+(?:\.\d+)+)(?:,build(\d+))?"#, in: value) {
                    st.model = c[0]
                    st.version = c[1]
                    st.build = c[2].isEmpty ? nil : c[2]
                }
            case "Serial-Number": st.serial = value.isEmpty ? nil : value
            case "Hostname": st.hostname = value.isEmpty ? nil : value
            case "Virtual domain configuration":
                st.vdoms = ["multiple", "enable", "split-task"].contains(value.lowercased())
            case "Current HA mode": st.haMode = value.isEmpty ? nil : value
            case "Operation Mode": st.operationMode = value.isEmpty ? nil : value
            default: break
            }
        }
        return st
    }

    // MARK: Interfaces

    /// `get system interface physical`: one `==[name]` block per port with `status:` and `speed:` lines.
    /// Group headers (`== [onboard]`) have no lines of their own and are skipped.
    public static func physical(_ s: String) -> [FortiOSPhysicalPort] {
        var out: [FortiOSPhysicalPort] = []
        var current: FortiOSPhysicalPort?
        var hasStatus = false
        func flush() {
            if let c = current, hasStatus { out.append(c) }
            current = nil
            hasStatus = false
        }
        for raw in s.components(separatedBy: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if let name = CiscoParsers.capture(#"^==\s*\[\s*([^\]\s]+)\s*\]$"#, in: l)?.first {
                flush()
                current = FortiOSPhysicalPort(name: name)
                continue
            }
            guard current != nil, let colon = l.firstIndex(of: ":") else { continue }
            let key = l[..<colon].trimmingCharacters(in: .whitespaces)
            let value = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "status":
                hasStatus = true
                current?.linkUp = value.lowercased() == "up"
            case "speed":
                // "1000Mbps (Duplex: full)", "n/a"
                if let c = CiscoParsers.capture(#"^(\d+(?:\.\d+)?[MG]bps)(?:\s*\(Duplex:\s*(\w+)\))?"#, in: value) {
                    current?.speed = c[0]
                    current?.duplex = c[1].isEmpty ? nil : c[1].lowercased()
                }
            default: break
            }
        }
        flush()
        return out
    }

    /// Every interface of every `config system interface` table in a configuration (`show`).
    public static func interfaces(_ config: String) -> [FortiOSInterface] {
        table("system interface", in: config).map { e in
            var i = FortiOSInterface(name: e.name)
            i.vdom = e.value("vdom")
            i.type = e.value("type")
            i.alias = e.value("alias").flatMap { $0.isEmpty ? nil : $0 }
            i.description = e.value("description").flatMap { $0.isEmpty ? nil : $0 }
            i.down = e.value("status") == "down"
            i.mode = e.value("mode")
            if let ip = e.settings["ip"], ip.count >= 2 { i.address = cidr(ip[0], ip[1]) }
            else if let ip = e.value("ip"), ip.contains("/"), !ip.hasPrefix("0.0.0.0") { i.address = ip }
            i.parent = e.value("interface")
            i.vlanID = e.value("vlanid").flatMap(Int.init)
            i.members = e.settings["member"] ?? []
            i.role = e.value("role")
            return i
        }
    }

    /// Hardware switches (`config system virtual-switch`): name → member ports (`config port`).
    public static func virtualSwitches(_ config: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for e in table("system virtual-switch", in: config) { out[e.name] = e.nested["port"] ?? [] }
        return out
    }

    /// Software switches (`config system switch-interface`): name → members.
    public static func softwareSwitches(_ config: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for e in table("system switch-interface", in: config) { out[e.name] = e.settings["member"] ?? [] }
        return out
    }

    /// Zones of every VDOM (`config system zone`): name → interfaces.
    public static func zones(_ config: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for e in table("system zone", in: config) { out[e.name, default: []] += e.settings["interface"] ?? [] }
        return out
    }

    /// "192.0.2.1", "255.255.255.0" → "192.0.2.1/24"; nil for 0.0.0.0.
    static func cidr(_ address: String, _ mask: String) -> String? {
        guard address != "0.0.0.0" else { return nil }
        let octets = mask.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return address }
        let bits = octets.reduce(0) { $0 + $1.nonzeroBitCount }
        return "\(address)/\(bits)"
    }

    // MARK: ARP

    /// `get system arp` ("Address Age(min) Hardware Addr Interface") or `diagnose ip arp list`
    /// ("index=5 ifname=internal 192.0.2.10 00:00:5e:00:53:01 state=00000002 ..."). Incomplete entries
    /// (all-zero MAC) are left out.
    public static func arp(_ s: String) -> [FortiOSARPEntry] {
        let mac = #"[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}"#
        var out: [FortiOSARPEntry] = []
        for raw in s.components(separatedBy: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            var entry: FortiOSARPEntry?
            if let c = CiscoParsers.capture(#"ifname=(\S+)\s+(\d+\.\d+\.\d+\.\d+)\s+("# + mac + ")", in: l) {
                entry = FortiOSARPEntry(ip: c[1], mac: c[2].lowercased(), interface: c[0])
            } else {
                let cols = l.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                if cols.count >= 4, cols[0].range(of: #"^\d+\.\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
                   cols[2].range(of: "^" + mac + "$", options: .regularExpression) != nil {
                    entry = FortiOSARPEntry(ip: cols[0], mac: cols[2].lowercased(), interface: cols[3])
                }
            }
            if let e = entry, e.mac != "00:00:00:00:00:00", !out.contains(e) { out.append(e) }
        }
        return out
    }

    // MARK: Errors

    /// Lines FortiOS prints when it refuses or doesn't know a command.
    public static func errors(in output: String) -> [String] {
        let patterns = [
            #"^Command fail\."#, #"command parse error"#, #"^Unknown action"#, #"node_check_object fail"#,
            #"value parse error"#, #"^Permission denied"#, #"^Attribute '.*' value"#,
        ]
        return output.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { l in
            !l.isEmpty && patterns.contains { l.range(of: $0, options: .regularExpression) != nil }
        }
    }

    // MARK: Configuration tables

    /// Every `edit` entry of every `config <path>` table in the text. A multi-VDOM configuration has a
    /// table per VDOM (zones) or one under `config global` (interfaces); all of them are returned.
    public static func table(_ path: String, in text: String) -> [FortiOSConfigEntry] {
        enum Frame { case table, entry }
        var out: [FortiOSConfigEntry] = []
        var stack: [Frame] = []
        var current: FortiOSConfigEntry?
        var nestedName: String?
        for raw in text.components(separatedBy: "\n") {
            let words = tokens(raw)
            guard let first = words.first else { continue }
            if stack.isEmpty {
                if first == "config", words.dropFirst().joined(separator: " ") == path { stack = [.table] }
                continue
            }
            switch first {
            case "config":
                stack.append(.table)
                if stack.count == 3 { nestedName = words.dropFirst().joined(separator: " ") }
            case "edit" where words.count > 1:
                stack.append(.entry)
                if stack.count == 2 {
                    current = FortiOSConfigEntry(name: words[1])
                } else if stack.count == 4, let n = nestedName {
                    current?.nested[n, default: []].append(words[1])
                }
            case "set" where words.count > 1:
                if stack.count == 2 { current?.settings[words[1]] = Array(words.dropFirst(2)) }
            case "next":
                if stack.last == .entry { stack.removeLast() }
                if stack.count == 1, let c = current { out.append(c); current = nil }
            case "end":
                // An entry closed by `end` without `next` (not printed by FortiOS, but harmless).
                if stack.last == .entry {
                    stack.removeLast()
                    if stack.count == 1, let c = current { out.append(c); current = nil }
                }
                if !stack.isEmpty { stack.removeLast() }
                if stack.count == 2 { nestedName = nil }
            default:
                break
            }
        }
        return out
    }

    /// Words of a configuration line; double-quoted values keep their blanks and `\"` / `\\` escapes.
    static func tokens(_ line: String) -> [String] {
        var out: [String] = []
        var word = ""
        var inQuotes = false, escaped = false, started = false
        for ch in line {
            if escaped {
                word.append(ch)
                escaped = false
            } else if inQuotes {
                if ch == "\\" { escaped = true } else if ch == "\"" { inQuotes = false } else { word.append(ch) }
            } else if ch == "\"" {
                inQuotes = true
                started = true
            } else if ch == " " || ch == "\t" {
                if started { out.append(word); word = ""; started = false }
            } else {
                word.append(ch)
                started = true
            }
        }
        if started { out.append(word) }
        return out
    }
}
