import Foundation

/// `show version`: what the device is.
public struct CiscoVersion: Equatable, Sendable {
    public var hostname: String?
    public var model: String?
    public var serial: String?
    /// "17.09.04a", "15.2(7)E8".
    public var osVersion: String?
    /// IOS-XE (Catalyst 9000, 3650/3850, ISR 4000) rather than classic IOS.
    public var isXE = false
    /// The text comes from Cisco IOS or IOS-XE (not NX-OS or IOS-XR, which work differently).
    public var isIOS = false
}

/// One `show inventory` entry.
public struct CiscoInventoryItem: Equatable, Sendable {
    public var name: String
    public var descr: String
    public var pid = ""
    public var vid = ""
    public var serial = ""
}

/// One `interface X` block of the running configuration.
public struct CiscoInterfaceConfig: Equatable, Sendable {
    public var name: String
    public var description: String?
    public var shutdown = false
    /// `no switchport`: a routed (layer 3) port.
    public var noSwitchport = false
    /// `switchport mode access|trunk`; nil when not set or dynamic (DTP).
    public var mode: PortMode?
    public var accessVLAN: Int?
    /// `switchport trunk allowed vlan`; nil = all VLANs (nothing configured).
    public var allowedVLANs: [Int]?
    public var nativeVLAN: Int?
    /// "192.0.2.1/30", "dhcp", IPv6 prefixes.
    public var addresses: [String] = []
    public var vrf: String?
    public var channelGroup: Int?
    /// `switchport trunk encapsulation ...` (switches that also speak ISL).
    public var hasEncapsulation = false
}

/// The parts of `show running-config` Netdeck reads.
public struct CiscoRunningConfig: Equatable, Sendable {
    public var hostname: String?
    /// In configuration order.
    public var interfaces: [CiscoInterfaceConfig] = []
    /// VLANs declared with `vlan N` blocks (VTP transparent or off); "" when the block has no name.
    public var vlans: [Int: String] = [:]
    /// `archive` / ` path X`.
    public var archivePath: String?
    /// Some interface sets `switchport trunk encapsulation`: the switch needs it before `switchport mode trunk`.
    public var usesTrunkEncapsulation = false

    public func interface(_ name: String) -> CiscoInterfaceConfig? { interfaces.first { $0.name == name } }
}

/// One row of `show interfaces status`. `port` is the short name as printed ("Gi1/0/3").
public struct CiscoPortStatus: Equatable, Sendable {
    public var port: String
    /// Description, truncated by the switch to 18 characters.
    public var name: String
    /// connected, notconnect, disabled, err-disabled, inactive, suspended...
    public var status: String
    /// VLAN number, "trunk", "routed" or "unassigned".
    public var vlan: String
    public var duplex: String
    public var speed: String
    /// "10/100/1000BaseTX", "SFP-10GBase-SR", "Not Present", "unknown"...
    public var type: String

    public var linkUp: Bool { status == "connected" }
    /// "disabled" means shut down in the configuration; err-disabled ports are still enabled there.
    public var adminUp: Bool { status != "disabled" }
}

/// One VLAN of `show vlan brief`.
public struct CiscoVLANRow: Equatable, Sendable {
    public var id: Int
    public var name: String
    public var status: String
    /// Access ports in the VLAN, short names.
    public var ports: [String]
}

/// One learned address of `show mac address-table`. `port` is the short name as printed.
public struct CiscoMACRow: Equatable, Sendable {
    public var vlan: String
    /// aa:bb:cc:dd:ee:ff
    public var mac: String
    /// "dynamic", "static"
    public var type: String
    public var port: String
}

/// Pure parsers for Cisco IOS / IOS-XE `show` outputs (command echo and prompt already removed).
public enum CiscoParsers {
    // MARK: show version

    public static func version(_ text: String) -> CiscoVersion {
        var v = CiscoVersion()
        let xr = text.contains("IOS XR") || text.contains("IOS-XR")
        v.isXE = text.contains("IOS XE") || text.contains("IOS-XE")
        v.isIOS = !xr && !text.contains("NX-OS")
            && (text.contains("Cisco IOS") || v.isXE || text.contains("Cisco Internetwork Operating System"))
        let lines = text.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\r", with: "") }

        let osLine = lines.first { $0.contains("Cisco IOS XE Software") }
            ?? lines.first { $0.contains("Cisco IOS Software") || $0.contains("IOS (tm)") }
        if let l = osLine, let c = capture(#"Version\s+([^\s,]+)"#, in: l) { v.osVersion = c[0] }

        for line in lines {
            let l = line.trimmingCharacters(in: .whitespaces)
            if v.hostname == nil, let c = capture(#"^(\S+) uptime is "#, in: l) { v.hostname = c[0] }
            // Older switches print "Model number" / "System serial number" in lower case.
            if v.model == nil, let c = capture(#"^Model number\s*:\s*(\S+)"#, in: l, options: .caseInsensitive) { v.model = c[0] }
            if v.serial == nil, let c = capture(#"^System serial number\s*:\s*(\S+)"#, in: l, options: .caseInsensitive) { v.serial = c[0] }
        }
        // "cisco C9500-40X (X86) processor with ...", "Cisco CISCO2911/K9 (revision 1.0) with 491520K/32768K bytes of memory."
        // (routers have no "Model Number" line).
        if v.model == nil,
           let l = lines.first(where: { $0.lowercased().hasPrefix("cisco ") && ($0.contains("processor") || $0.contains("bytes of memory")) }),
           let c = capture(#"^[Cc]isco\s+(\S+)"#, in: l) {
            v.model = c[0]
        }
        if v.serial == nil, let l = lines.first(where: { $0.contains("Processor board ID") }),
           let c = capture(#"Processor board ID\s+(\S+)"#, in: l) {
            v.serial = c[0]
        }
        return v
    }

    // MARK: show inventory

    public static func inventory(_ text: String) -> [CiscoInventoryItem] {
        var out: [CiscoInventoryItem] = []
        for raw in text.components(separatedBy: "\n") {
            let l = raw.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespaces)
            if let c = capture(#"^NAME:\s*"(.*?)"\s*,\s*DESCR:\s*"(.*)"$"#, in: l) {
                out.append(CiscoInventoryItem(name: c[0], descr: c[1]))
            } else if l.hasPrefix("PID:"), !out.isEmpty {
                for part in l.split(separator: ",") {
                    let kv = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard kv.count == 2 else { continue }
                    switch kv[0] {
                    case "PID": out[out.count - 1].pid = kv[1]
                    case "VID": out[out.count - 1].vid = kv[1]
                    case "SN": out[out.count - 1].serial = kv[1]
                    default: break
                    }
                }
            }
        }
        return out
    }

    // MARK: show running-config

    public static func runningConfig(_ text: String) -> CiscoRunningConfig {
        var rc = CiscoRunningConfig()
        var current: CiscoInterfaceConfig?
        var vlanBlock: [Int] = []
        var inArchive = false

        func flush() {
            if let c = current { rc.interfaces.append(c) }
            current = nil
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\r", with: "")
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if !line.hasPrefix(" ") {
                flush()
                vlanBlock = []
                inArchive = false
                if t.hasPrefix("hostname ") {
                    rc.hostname = String(t.dropFirst("hostname ".count)).trimmingCharacters(in: .whitespaces)
                } else if t.hasPrefix("interface ") {
                    current = CiscoInterfaceConfig(name: String(t.dropFirst("interface ".count)).trimmingCharacters(in: .whitespaces))
                } else if t.hasPrefix("vlan "), let ids = vlanList(String(t.dropFirst("vlan ".count))) {
                    // "vlan internal allocation policy ..." and friends are not VLAN lists and fail above.
                    for id in ids where rc.vlans[id] == nil { rc.vlans[id] = "" }
                    vlanBlock = ids
                } else if t == "archive" {
                    inArchive = true
                }
                continue
            }
            if var c = current {
                parseInterfaceLine(t, into: &c)
                if c.hasEncapsulation { rc.usesTrunkEncapsulation = true }
                current = c
            } else if vlanBlock.count == 1, t.hasPrefix("name ") {
                rc.vlans[vlanBlock[0]] = String(t.dropFirst("name ".count)).trimmingCharacters(in: .whitespaces)
            } else if inArchive, t.hasPrefix("path ") {
                rc.archivePath = String(t.dropFirst("path ".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        flush()
        return rc
    }

    static func parseInterfaceLine(_ t: String, into c: inout CiscoInterfaceConfig) {
        func rest(_ prefix: String) -> String { String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
        if t.hasPrefix("description ") {
            c.description = rest("description ")
        } else if t == "shutdown" {
            c.shutdown = true
        } else if t == "no shutdown" {
            c.shutdown = false
        } else if t == "no switchport" {
            c.noSwitchport = true
        } else if t == "switchport" {
            c.noSwitchport = false
        } else if t.hasPrefix("switchport mode ") {
            switch rest("switchport mode ") {
            case "access": c.mode = .access
            case "trunk": c.mode = .trunk
            default: c.mode = nil   // dynamic auto/desirable, private-vlan...
            }
        } else if t.hasPrefix("switchport access vlan ") {
            if let n = Int(rest("switchport access vlan ")) { c.accessVLAN = n }
        } else if t.hasPrefix("switchport trunk native vlan ") {
            if let n = Int(rest("switchport trunk native vlan ")) { c.nativeVLAN = n }
        } else if t.hasPrefix("switchport trunk allowed vlan ") {
            c.allowedVLANs = applyAllowed(rest("switchport trunk allowed vlan "), to: c.allowedVLANs)
        } else if t.hasPrefix("switchport trunk encapsulation ") {
            c.hasEncapsulation = true
        } else if t.hasPrefix("ip address ") {
            let words = rest("ip address ").split(separator: " ").map(String.init)
            if words.first == "dhcp" {
                c.addresses.append("dhcp")
            } else if words.count >= 2, let len = prefixLength(words[1]) {
                c.addresses.append("\(words[0])/\(len)")
            }
        } else if t.hasPrefix("ipv6 address ") {
            if let a = rest("ipv6 address ").split(separator: " ").first, a.contains("/") { c.addresses.append(String(a)) }
        } else if t.hasPrefix("vrf forwarding ") {
            c.vrf = rest("vrf forwarding ").split(separator: " ").first.map(String.init)
        } else if t.hasPrefix("ip vrf forwarding ") {
            c.vrf = rest("ip vrf forwarding ").split(separator: " ").first.map(String.init)
        } else if t.hasPrefix("channel-group ") {
            c.channelGroup = rest("channel-group ").split(separator: " ").first.flatMap { Int($0) }
        }
    }

    /// Applies one `switchport trunk allowed vlan ...` line ("10,20-25", "add 30", "remove 5", "except 1",
    /// "none", "all"). nil = all VLANs.
    static func applyAllowed(_ spec: String, to current: [Int]?) -> [Int]? {
        let words = spec.split(separator: " ").map(String.init)
        guard let first = words.first else { return current }
        let all = Set(1...4094)
        let listed = Set(words.count > 1 ? (vlanList(words[1]) ?? []) : [])
        func result(_ s: Set<Int>) -> [Int]? { s.isSuperset(of: all) ? nil : s.sorted() }
        switch first {
        case "all": return nil
        case "none": return []
        case "add":
            guard let current else { return nil }   // adding to "all" is still all
            return result(Set(current).union(listed))
        case "remove": return result(Set(current ?? Array(1...4094)).subtracting(listed))
        case "except": return result(all.subtracting(listed))
        default:
            guard let ids = vlanList(first) else { return current }
            return result(Set(ids))
        }
    }

    /// "10,20,30-35" → [10, 20, 30, 31, 32, 33, 34, 35]; nil when the text isn't a VLAN list.
    public static func vlanList(_ s: String) -> [Int]? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "," || $0 == "-") }) else { return nil }
        var out: [Int] = []
        for part in t.split(separator: ",") {
            let ends = part.split(separator: "-").compactMap { Int($0) }
            if ends.count == 1 {
                out.append(ends[0])
            } else if ends.count == 2, ends[0] <= ends[1], ends[1] <= 4095 {
                out += Array(ends[0]...ends[1])
            } else {
                return nil
            }
        }
        return out
    }

    /// [10, 20, 30, 31, 32] → "10,20,30-32".
    public static func compressVLANList(_ ids: [Int]) -> String {
        var parts: [String] = []
        var runStart: Int?
        var previous: Int?
        for id in Array(Set(ids)).sorted() {
            if let p = previous, id == p + 1 {
                previous = id
                continue
            }
            if let a = runStart, let b = previous { parts.append(a == b ? "\(a)" : "\(a)-\(b)") }
            runStart = id
            previous = id
        }
        if let a = runStart, let b = previous { parts.append(a == b ? "\(a)" : "\(a)-\(b)") }
        return parts.joined(separator: ",")
    }

    static func prefixLength(_ mask: String) -> Int? {
        let octets = mask.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return nil }
        return octets.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    /// The running configuration as kept in backups: without the lines that change on every read
    /// ("Current configuration : N bytes", change timestamps, `ntp clock-period`).
    public static func configText(_ text: String) -> String {
        let volatile = ["Building configuration", "Current configuration :", "! Last configuration change at",
                        "! NVRAM config last updated at", "! No configuration change since last restart", "ntp clock-period "]
        return text.components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "\r", with: "") }
            .filter { line in !volatile.contains { line.hasPrefix($0) } }
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
    }

    // MARK: show interfaces status

    /// Fixed-width table; columns are located from the header. Speed and duplex are right-aligned and may
    /// start before their header, so the middle part (Status … Speed) is split into words instead.
    public static func interfacesStatus(_ text: String) -> [CiscoPortStatus] {
        let lines = text.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\r", with: "") }
        guard let h = lines.firstIndex(where: { $0.hasPrefix("Port") && $0.contains("Status") && $0.contains("Vlan") }) else { return [] }
        let header = lines[h]
        guard let cName = column(header, "Name"), let cStatus = column(header, "Status") else { return [] }
        let cType = column(header, "Type")
        var out: [CiscoPortStatus] = []
        for line in lines[(h + 1)...] {
            guard let first = line.first, !first.isWhitespace, !line.hasPrefix("Port "), !line.hasPrefix("---") else { continue }
            let port = String(line.prefix { !$0.isWhitespace })
            guard port.contains(where: \.isNumber) else { continue }
            let chars = Array(line)
            let name = slice(chars, max(cName, port.count + 1), cStatus)
            var middle = slice(chars, cStatus, cType).split(separator: " ").map(String.init)
            guard middle.count >= 4 else { continue }
            let speed = middle.removeLast()
            let duplex = middle.removeLast()
            let vlan = middle.removeLast()
            let status = middle.first.map { $0.hasSuffix(":") ? String($0.dropLast()) : $0 } ?? ""
            let type = cType.map { slice(chars, $0, nil) } ?? ""
            out.append(CiscoPortStatus(port: port, name: name, status: status, vlan: vlan, duplex: duplex, speed: speed, type: type))
        }
        return out
    }

    // MARK: show vlan brief

    /// VLANs 1002–1005 (FDDI/Token Ring leftovers) are skipped. Port lists wrap onto continuation lines.
    public static func vlanBrief(_ text: String) -> [CiscoVLANRow] {
        let lines = text.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\r", with: "") }
        guard let h = lines.firstIndex(where: { $0.hasPrefix("VLAN") && $0.contains("Name") && $0.contains("Status") }) else { return [] }
        let header = lines[h]
        guard let cName = column(header, "Name"), let cStatus = column(header, "Status") else { return [] }
        let cPorts = column(header, "Ports")
        func ports(_ s: String) -> [String] {
            s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        var out: [CiscoVLANRow] = []
        for line in lines[(h + 1)...] {
            let chars = Array(line)
            if let f = line.first, f.isNumber {
                guard let id = Int(line.prefix { $0.isNumber }) else { continue }
                let status = slice(chars, cStatus, cPorts).split(separator: " ").first.map(String.init) ?? ""
                out.append(CiscoVLANRow(id: id, name: slice(chars, cName, cStatus), status: status,
                                        ports: cPorts.map { ports(slice(chars, $0, nil)) } ?? []))
            } else if line.first == " ", !out.isEmpty, let c = cPorts {
                out[out.count - 1].ports += ports(slice(chars, c, nil))
            }
        }
        return out.filter { !(1002...1005).contains($0.id) }
    }

    // MARK: show mac address-table

    /// Both layouts: "Vlan Mac Address Type Ports" (Catalyst 2960/3850/9000) and
    /// "vlan mac address type learn age ports" (Catalyst 4500/6500), plus the old
    /// "Destination Address Address Type VLAN Destination Port". Entries of the switch itself
    /// (CPU, Router, Switch, VLAN "All", static entries off the front ports) are skipped.
    public static func macTable(_ text: String) -> [CiscoMACRow] {
        var out: [CiscoMACRow] = []
        for raw in text.components(separatedBy: "\n") {
            let tokens = raw.replacingOccurrences(of: "\r", with: "")
                .split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let i = tokens.firstIndex(where: isDottedMAC), let last = tokens.last else { continue }
            let vlan: String, type: String
            if i == 0 {
                guard tokens.count >= 4 else { continue }
                type = tokens[1]
                vlan = tokens[2]
            } else {
                guard tokens.count >= i + 3 else { continue }
                vlan = tokens[i - 1]
                type = tokens[i + 1]
            }
            let port = String(last.split(separator: ",").first ?? "")
            guard vlan.lowercased() != "all", isInterfaceName(port) else { continue }
            // Static entries are the switch's own (SVI, CPU) unless they sit on a front port (port-security).
            if type.lowercased().contains("static") && !CiscoNames.isPhysical(CiscoNames.full(port)) { continue }
            out.append(CiscoMACRow(vlan: vlan, mac: normalizeMAC(tokens[i]), type: type.lowercased(), port: port))
        }
        return out
    }

    static func isDottedMAC(_ s: String) -> Bool {
        s.range(of: #"^[0-9A-Fa-f]{4}\.[0-9A-Fa-f]{4}\.[0-9A-Fa-f]{4}$"#, options: .regularExpression) != nil
    }

    static func isInterfaceName(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z][A-Za-z\-]*\d+(/\d+)*$"#, options: .regularExpression) != nil
    }

    /// "30a3.30a3.a1cd" → "30:a3:30:a3:a1:cd".
    public static func normalizeMAC(_ s: String) -> String {
        let hex = Array(s.lowercased().filter(\.isHexDigit))
        guard hex.count == 12 else { return s.lowercased() }
        return stride(from: 0, to: 12, by: 2).map { String(hex[$0..<($0 + 2)]) }.joined(separator: ":")
    }

    // MARK: show lldp neighbors

    /// Device IDs are cut to 20 characters by the switch. "% LLDP is not enabled" gives no rows.
    /// `localInterface` is the short name as printed; the chassis ID isn't in this output.
    public static func lldpNeighbors(_ text: String) -> [LLDPNeighbor] {
        let lines = text.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\r", with: "") }
        guard let h = lines.firstIndex(where: { $0.hasPrefix("Device ID") && $0.contains("Local Intf") }) else { return [] }
        let header = lines[h]
        guard let cLocal = column(header, "Local Intf"), let cPort = column(header, "Port ID") else { return [] }
        let cHold = column(header, "Hold-time") ?? column(header, "Hold")
        var out: [LLDPNeighbor] = []
        var pendingDevice: String?
        for line in lines[(h + 1)...] {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if t.hasPrefix("Total entries") { break }
            let chars = Array(line)
            let device = slice(chars, 0, cLocal)
            let local = slice(chars, cLocal, cHold ?? cPort).split(separator: " ").first.map(String.init) ?? ""
            guard !local.isEmpty else {
                // Some releases print a long Device ID on a line of its own.
                pendingDevice = t
                continue
            }
            out.append(LLDPNeighbor(localInterface: local, chassisID: "", portInfo: slice(chars, cPort, nil),
                                    systemName: device.isEmpty ? (pendingDevice ?? "") : device))
            pendingDevice = nil
        }
        return out
    }

    // MARK: show archive

    /// The configuration archive (needed by `configure terminal revert timer`) has a path. Unknown
    /// text, such as "Archive feature not enabled", counts as not configured.
    public static func archiveConfigured(_ text: String) -> Bool {
        text.lowercased().contains("next archive file will be named")
    }

    // MARK: Helpers

    static func column(_ header: String, _ title: String) -> Int? {
        guard let r = header.range(of: title) else { return nil }
        return header.distance(from: header.startIndex, to: r.lowerBound)
    }

    static func slice(_ chars: [Character], _ a: Int, _ b: Int?) -> String {
        guard a < chars.count else { return "" }
        let end = min(b ?? chars.count, chars.count)
        return String(chars[a..<max(a, end)]).trimmingCharacters(in: .whitespaces)
    }

    /// Capture groups of the first match ("" for a group that didn't take part).
    static func capture(_ pattern: String, in s: String, options: NSRegularExpression.Options = []) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<max(1, m.numberOfRanges)).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }
}
