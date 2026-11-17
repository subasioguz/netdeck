import Foundation

/// Structured view of the parts of a Junos ELS switch config that Netdeck edits,
/// built from `show configuration | display set`.
public struct JunosConfig: Equatable, Sendable {
    public struct InterfaceConfig: Equatable, Sendable {
        public var description: String?
        public var disabled = false
        public var mode: PortMode?
        public var vlanMembers: [String] = []
        public var nativeVlanID: Int?
        public var inetAddresses: [String] = []
        public var hasEthernetSwitching = false
    }

    public struct InterfaceRange: Equatable, Sendable {
        public var name: String
        public var memberRanges: [MemberRange] = []
        public var members: [String] = []
        public var config = InterfaceConfig()

        public func contains(_ port: String) -> Bool {
            members.contains(port) || memberRanges.contains { $0.contains(port) }
        }
    }

    public struct MemberRange: Equatable, Sendable, Hashable {
        public var start: String
        public var end: String

        public var prefix: String { InterfaceName.prefix(start) }

        public func contains(_ port: String) -> Bool {
            guard InterfaceName.prefix(port) == prefix,
                  let n = InterfaceName.portNumber(port),
                  let a = InterfaceName.portNumber(start),
                  let b = InterfaceName.portNumber(end) else { return false }
            return (min(a, b)...max(a, b)).contains(n)
        }

        public var ports: [String] {
            guard let a = InterfaceName.portNumber(start), let b = InterfaceName.portNumber(end) else { return [] }
            return (min(a, b)...max(a, b)).map { prefix + String($0) }
        }
    }

    public struct VLAN: Equatable, Sendable, Hashable, Identifiable {
        public var name: String
        public var vlanID: Int?
        public var description: String?
        public var l3Interface: String?
        public var id: String { name }

        public init(name: String, vlanID: Int? = nil, description: String? = nil, l3Interface: String? = nil) {
            self.name = name
            self.vlanID = vlanID
            self.description = description
            self.l3Interface = l3Interface
        }
    }

    public struct RTGGroup: Equatable, Sendable {
        public var name: String
        public var primary: String?
        public var members: [String] = []
    }

    public var hostname: String?
    public var interfaces: [String: InterfaceConfig] = [:]
    public var ranges: [InterfaceRange] = []
    public var vlans: [VLAN] = []
    public var rstpEdge: Set<String> = []
    public var rstpDisabled: Set<String> = []
    public var bpduBlockOnEdge = false
    public var rtgGroups: [RTGGroup] = []
    public var lines: [String] = []

    public init() {}

    public func vlan(named name: String) -> VLAN? { vlans.first { $0.name == name } }

    public func ranges(containing port: String) -> [InterfaceRange] { ranges.filter { $0.contains(port) } }

    /// Effective config of a physical port: interface-range config merged with the port's own statements.
    public func effective(_ port: String) -> InterfaceConfig {
        var result = InterfaceConfig()
        for r in ranges(containing: port) { result.merge(r.config) }
        if let own = interfaces[port] { result.merge(own) }
        return result
    }
}

extension JunosConfig.InterfaceConfig {
    mutating func merge(_ other: JunosConfig.InterfaceConfig) {
        if let d = other.description { description = d }
        if other.disabled { disabled = true }
        if let m = other.mode { mode = m }
        if !other.vlanMembers.isEmpty { vlanMembers = other.vlanMembers }
        if let n = other.nativeVlanID { nativeVlanID = n }
        inetAddresses += other.inetAddresses
        hasEthernetSwitching = hasEthernetSwitching || other.hasEthernetSwitching
    }
}

public enum PortMode: String, Sendable, Codable, CaseIterable {
    case access, trunk
}

public enum InterfaceName {
    /// "ge-0/0/12" → "ge-0/0/"
    public static func prefix(_ name: String) -> String {
        guard let slash = name.lastIndex(of: "/") else { return name }
        return String(name[...slash])
    }

    /// "ge-0/0/12" → 12, "ge-0/0/12.0" → 12
    public static func portNumber(_ name: String) -> Int? {
        guard let slash = name.lastIndex(of: "/") else { return nil }
        let tail = name[name.index(after: slash)...].prefix { $0.isNumber }
        return Int(tail)
    }

    /// "ge-0/0/12.0" → "ge-0/0/12"
    public static func physical(_ name: String) -> String {
        name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? name
    }

    /// Stable sort key: media type order then FPC/PIC/port numbers.
    public static func sortKey(_ name: String) -> [Int] {
        let nums = name.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        return nums
    }
}

// MARK: - Parser

public enum SetConfigParser {
    public static func parse(_ text: String) -> JunosConfig {
        var cfg = JunosConfig()
        var rangeIndex: [String: Int] = [:]
        var rtgIndex: [String: Int] = [:]

        func iface(_ name: String, _ body: (inout JunosConfig.InterfaceConfig) -> Void) {
            var c = cfg.interfaces[name] ?? JunosConfig.InterfaceConfig()
            body(&c)
            cfg.interfaces[name] = c
        }
        func range(_ name: String, _ body: (inout JunosConfig.InterfaceRange) -> Void) {
            let i: Int
            if let existing = rangeIndex[name] { i = existing } else {
                cfg.ranges.append(JunosConfig.InterfaceRange(name: name))
                i = cfg.ranges.count - 1
                rangeIndex[name] = i
            }
            body(&cfg.ranges[i])
        }
        func vlan(_ name: String, _ body: (inout JunosConfig.VLAN) -> Void) {
            if let i = cfg.vlans.firstIndex(where: { $0.name == name }) {
                body(&cfg.vlans[i])
            } else {
                var v = JunosConfig.VLAN(name: name)
                body(&v)
                cfg.vlans.append(v)
            }
        }
        /// Applies interface-level statements (shared by interfaces and interface-ranges).
        func applyInterfaceStatement(_ t: ArraySlice<String>, _ c: inout JunosConfig.InterfaceConfig) {
            let t = Array(t)
            guard let head = t.first else { return }
            switch head {
            case "description": if t.count > 1 { c.description = t[1] }
            case "disable": c.disabled = true
            case "native-vlan-id": if t.count > 1 { c.nativeVlanID = Int(t[1]) }
            case "unit":
                guard t.count > 3, t[2] == "family" else { return }
                if t[3] == "ethernet-switching" {
                    c.hasEthernetSwitching = true
                    let rest = Array(t.dropFirst(4))
                    if rest.first == "interface-mode", rest.count > 1 { c.mode = PortMode(rawValue: rest[1]) }
                    if rest.count > 2, rest[0] == "vlan", rest[1] == "members" {
                        let members = rest.dropFirst(2).filter { $0 != "[" && $0 != "]" }
                        for m in members where !c.vlanMembers.contains(m) { c.vlanMembers.append(m) }
                    }
                } else if t[3] == "inet" || t[3] == "inet6" {
                    if t.count > 5, t[4] == "address" { c.inetAddresses.append(t[5]) }
                    if t.count > 4, t[4] == "dhcp" { c.inetAddresses.append("dhcp") }
                }
            default: break
            }
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("set ") else { continue }
            cfg.lines.append(line)
            let t = tokenize(line)
            guard t.count >= 3 else { continue }

            switch t[1] {
            case "system":
                if t[2] == "host-name", t.count > 3 { cfg.hostname = t[3] }
            case "interfaces":
                if t[2] == "interface-range", t.count > 4 {
                    let name = t[3]
                    let rest = t[4...]
                    range(name) { r in
                        if rest.first == "member-range", rest.count >= 4 {
                            let a = Array(rest)
                            r.memberRanges.append(.init(start: a[1], end: a[3]))
                        } else if rest.first == "member", rest.count >= 2 {
                            r.members.append(Array(rest)[1])
                        } else {
                            applyInterfaceStatement(rest, &r.config)
                        }
                    }
                } else if t.count > 3 {
                    let name = t[2]
                    iface(name) { applyInterfaceStatement(t[3...], &$0) }
                }
            case "vlans":
                guard t.count > 4 else { continue }
                let name = t[2]
                vlan(name) { v in
                    switch t[3] {
                    case "vlan-id": v.vlanID = Int(t[4])
                    case "description": v.description = t[4]
                    case "l3-interface": v.l3Interface = t[4]
                    default: break
                    }
                }
            case "protocols":
                guard t[2] == "rstp" else { continue }
                if t.count > 3, t[3] == "bpdu-block-on-edge" { cfg.bpduBlockOnEdge = true }
                if t.count > 5, t[3] == "interface" {
                    if t[5] == "edge" { cfg.rstpEdge.insert(t[4]) }
                    if t[5] == "disable" { cfg.rstpDisabled.insert(t[4]) }
                }
            case "switch-options":
                // set switch-options redundant-trunk-group group UPLINK interface xe-0/2/3.0 primary
                guard t.count > 6, t[2] == "redundant-trunk-group", t[3] == "group", t[5] == "interface" else { continue }
                let g = t[4], ifc = InterfaceName.physical(t[6])
                let i: Int
                if let existing = rtgIndex[g] { i = existing } else {
                    cfg.rtgGroups.append(.init(name: g))
                    i = cfg.rtgGroups.count - 1
                    rtgIndex[g] = i
                }
                if !cfg.rtgGroups[i].members.contains(ifc) { cfg.rtgGroups[i].members.append(ifc) }
                if t.count > 7, t[7] == "primary" { cfg.rtgGroups[i].primary = ifc }
            default:
                break
            }
        }
        return cfg
    }

    /// Splits a `set` line into tokens, keeping double-quoted strings together (quotes removed).
    public static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        var hadQuotes = false
        for ch in line {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" && inQuotes { escaped = true; continue }
            if ch == "\"" { inQuotes.toggle(); hadQuotes = true; continue }
            if ch == " " && !inQuotes {
                if !current.isEmpty || hadQuotes { tokens.append(current) }
                current = ""
                hadQuotes = false
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty || hadQuotes { tokens.append(current) }
        return tokens
    }

    /// Quotes a value for use in a `set` command when needed.
    public static func quote(_ value: String) -> String {
        let needs = value.isEmpty || value.contains(where: { " \t\"';{}[]#".contains($0) })
        guard needs else { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
