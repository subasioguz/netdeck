import Foundation

/// `show system` and `show modules` of an AOS-S switch.
public struct AOSSSystem: Equatable, Sendable {
    public var name: String?
    /// "WC.16.11.0028"
    public var softwareRevision: String?
    public var serial: String?
    /// "2930M-48G-PoE+"
    public var model: String?
    /// "JL322A"
    public var productNumber: String?
}

/// One `vlan` block of the running configuration.
public struct AOSSVLANConfig: Equatable, Sendable {
    public var name: String?
    public var untagged: [String] = []
    public var tagged: [String] = []
}

/// One `interface` block of the running configuration.
public struct AOSSInterfaceConfig: Equatable, Sendable {
    public var name: String?
    public var disabled = false
}

public struct AOSSRunningConfig: Equatable, Sendable {
    public var hostname: String?
    /// ";JL322A Configuration Editor; Created on release #WC.16.11.0028"
    public var productNumber: String?
    public var vlans: [Int: AOSSVLANConfig] = [:]
    public var interfaces: [String: AOSSInterfaceConfig] = [:]
    /// Port → trunk group ("49" → "Trk1").
    public var trunkOf: [String: String] = [:]
}

/// One row of `show interfaces brief`.
public struct AOSSPortRow: Equatable, Sendable {
    public var port: String
    /// Trunk group from a "1/28-Trk1" style name.
    public var trunk: String?
    /// "100/1000T", "SFP+SR", "" (empty cage)
    public var type: String
    public var enabled: Bool
    public var up: Bool
    /// "1000FDx", "10GigFD", "." when down
    public var mode: String
}

/// Parsers for AOS-S (ProCurve) `show` output.
public enum AOSSParsers {
    // MARK: Port lists

    /// "1-4,7,A1-A3,Trk1,1/1-1/3" → every port named.
    public static func ports(_ list: String) -> [String] {
        var out: [String] = []
        for part in list.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
            let ends = part.split(separator: "-", maxSplits: 1).map(String.init)
            guard ends.count == 2, let a = split(ends[0]), let b = split(ends[1]), a.prefix == b.prefix, a.number <= b.number,
                  b.number - a.number < 1000 else {
                out.append(part)
                continue
            }
            out += (a.number...b.number).map { a.prefix + String($0) }
        }
        return out
    }

    /// "A12" → ("A", 12), "1/3" → ("1/", 3), "Trk2" → ("Trk", 2).
    static func split(_ name: String) -> (prefix: String, number: Int)? {
        guard let c = CiscoParsers.capture(#"^(.*?)(\d+)$"#, in: name), let n = Int(c[1]) else { return nil }
        return (c[0], n)
    }

    /// ["1", "2", "3", "7", "A1", "A2"] → "1-3,7,A1-A2".
    public static func compress(_ ports: [String]) -> String {
        var groups: [String: [Int]] = [:]
        var order: [String] = []
        var loose: [String] = []
        for p in ports {
            guard let s = split(p) else { loose.append(p); continue }
            if groups[s.prefix] == nil { order.append(s.prefix) }
            groups[s.prefix, default: []].append(s.number)
        }
        var parts: [String] = []
        for prefix in order {
            let numbers = Array(Set(groups[prefix]!)).sorted()
            var i = 0
            while i < numbers.count {
                var j = i
                while j + 1 < numbers.count, numbers[j + 1] == numbers[j] + 1 { j += 1 }
                parts.append(i == j ? "\(prefix)\(numbers[i])" : "\(prefix)\(numbers[i])-\(prefix)\(numbers[j])")
                i = j + 1
            }
        }
        return (parts + loose).joined(separator: ",")
    }

    // MARK: show version / show system / show modules

    /// "WC.16.11.0028", "K.15.18.0013", "YA.16.10.0010".
    public static func softwareRevision(_ text: String) -> String? {
        CiscoParsers.capture(#"\b([A-Z]{1,3}\.1\d\.\d{2}\.\d{4})\b"#, in: text)?.first
    }

    /// "WC.16.11.0028" → (16, 11).
    public static func release(_ revision: String) -> (major: Int, minor: Int)? {
        guard let c = CiscoParsers.capture(#"^[A-Z]{1,3}\.(\d+)\.(\d+)"#, in: revision), let a = Int(c[0]), let b = Int(c[1]) else { return nil }
        return (a, b)
    }

    /// `show version` of AOS-S: "Image stamp:" and a revision such as "WC.16.11.0028".
    public static func isAOSS(_ version: String) -> Bool {
        version.contains("Image stamp:") && softwareRevision(version) != nil
    }

    /// Two "key : value" columns per line; values may contain single spaces.
    public static func system(_ systemText: String, modules: String = "") -> AOSSSystem {
        var s = AOSSSystem()
        for line in systemText.components(separatedBy: "\n") {
            let chunks = line.components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            var key: String?
            for chunk in chunks {
                if chunk.hasPrefix(":") {
                    let value = chunk.dropFirst().trimmingCharacters(in: .whitespaces)
                    switch key {
                    case "System Name": s.name = value.isEmpty ? nil : value
                    case "Software revision": s.softwareRevision = value.isEmpty ? nil : value
                    case "Serial Number": s.serial = s.serial ?? (value.isEmpty ? nil : value)
                    default: break
                    }
                    key = nil
                } else if let r = chunk.range(of: " : ") {
                    // "System Name : x" with single spaces.
                    let k = String(chunk[..<r.lowerBound]), v = String(chunk[r.upperBound...])
                    if k == "System Name" { s.name = v }
                    if k == "Software revision" { s.softwareRevision = v }
                    if k == "Serial Number" { s.serial = s.serial ?? v }
                } else {
                    key = chunk
                }
            }
        }
        // " Chassis: 2930M-48G-PoE+  JL322A         Serial Number:   SG00XXXXXX"
        if let c = CiscoParsers.capture(#"Chassis:\s*(\S+)\s+([A-Z]{1,2}\d{3,4}[A-Z])?\s*(?:Serial Number:\s*(\S+))?"#, in: modules) {
            s.model = c[0].isEmpty ? nil : c[0]
            s.productNumber = c[1].isEmpty ? nil : c[1]
            if !c[2].isEmpty { s.serial = s.serial ?? c[2] }
        }
        return s
    }

    // MARK: show running-config

    public static func runningConfig(_ text: String) -> AOSSRunningConfig {
        var rc = AOSSRunningConfig()
        var vlan: Int?
        var interface: String?
        func unquote(_ s: String) -> String {
            var v = s.trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 { v = String(v.dropFirst().dropLast()) }
            return v
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\r", with: "")
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if t.hasPrefix(";") {
                if let c = CiscoParsers.capture(#"^;\s*(\S+) Configuration Editor"#, in: t) { rc.productNumber = c[0] }
                continue
            }
            let indented = line.first?.isWhitespace ?? false
            if !indented {
                vlan = nil
                interface = nil
                if t.hasPrefix("hostname ") {
                    rc.hostname = unquote(String(t.dropFirst("hostname ".count)))
                } else if t.hasPrefix("vlan "), let id = Int(t.dropFirst("vlan ".count).prefix { $0.isNumber }) {
                    vlan = id
                    if rc.vlans[id] == nil { rc.vlans[id] = AOSSVLANConfig() }
                } else if t.hasPrefix("interface ") {
                    let name = String(t.dropFirst("interface ".count)).split(separator: " ").first.map(String.init) ?? ""
                    interface = name
                    if rc.interfaces[name] == nil { rc.interfaces[name] = AOSSInterfaceConfig() }
                } else if t.hasPrefix("trunk ") {
                    // "trunk 49-50 trk1 lacp"
                    let w = t.split(separator: " ").map(String.init)
                    if w.count >= 3 {
                        let group = "Trk" + w[2].dropFirst(3)
                        for p in ports(w[1]) { rc.trunkOf[p] = group }
                    }
                }
                continue
            }
            if let v = vlan {
                if t.hasPrefix("name ") { rc.vlans[v]?.name = unquote(String(t.dropFirst("name ".count))) }
                if t.hasPrefix("untagged ") { rc.vlans[v]?.untagged += ports(String(t.dropFirst("untagged ".count))) }
                if t.hasPrefix("tagged ") { rc.vlans[v]?.tagged += ports(String(t.dropFirst("tagged ".count))) }
            } else if let i = interface {
                if t.hasPrefix("name ") { rc.interfaces[i]?.name = unquote(String(t.dropFirst("name ".count))) }
                if t == "disable" { rc.interfaces[i]?.disabled = true }
                if t == "enable" { rc.interfaces[i]?.disabled = false }
            }
        }
        return rc
    }

    /// The running configuration as kept in History & backups: without the "Running configuration:" header.
    public static func configText(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "\r", with: "") }
            .filter { !$0.hasPrefix("Running configuration:") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
    }

    // MARK: show interfaces brief

    /// "Port Type | Alert Enabled Status Mode ...": the part before "|" is the port and type, the part
    /// after it starts with Intrusion Alert, Enabled, Status and Mode.
    public static func interfacesBrief(_ text: String) -> [AOSSPortRow] {
        var out: [AOSSPortRow] = []
        for line in text.components(separatedBy: "\n") {
            let halves = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard halves.count == 2 else { continue }
            let left = halves[0].split(separator: " ").map(String.init)
            let right = halves[1].split(separator: " ").map(String.init)
            guard let name = left.first, right.count >= 4, ["yes", "no"].contains(right[1].lowercased()),
                  name.range(of: #"^(\d+/)?[A-Z]?\d+(-Trk\d+)?$"#, options: .regularExpression) != nil else { continue }
            let parts = name.components(separatedBy: "-Trk")
            out.append(AOSSPortRow(port: parts[0], trunk: parts.count > 1 ? "Trk" + parts[1] : nil,
                                   type: left.count > 1 ? left[1] : "", enabled: right[1].lowercased() == "yes",
                                   up: right[2].lowercased() == "up", mode: right[3]))
        }
        return out
    }

    // MARK: show vlans

    public static func vlans(_ text: String) -> [(id: Int, name: String)] {
        text.components(separatedBy: "\n").compactMap { line in
            let halves = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard halves.count == 2 else { return nil }
            let left = halves[0].trimmingCharacters(in: .whitespaces)
            guard let idText = left.split(separator: " ").first, let id = Int(idText) else { return nil }
            let name = left.dropFirst(idText.count).trimmingCharacters(in: .whitespaces)
            return (id: id, name: name)
        }
    }

    // MARK: show mac-address

    /// "500000-260000     Trk1      17" (MAC Address, Port, VLAN); older releases have no VLAN column.
    public static func macTable(_ text: String) -> [(mac: String, port: String, vlan: Int?)] {
        text.components(separatedBy: "\n").compactMap { line in
            let w = line.split(separator: " ").map(String.init)
            guard w.count >= 2, w[0].range(of: #"^[0-9a-fA-F]{6}-[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil else { return nil }
            return (mac: CiscoParsers.normalizeMAC(w[0]), port: w[1], vlan: w.count > 2 ? Int(w[2]) : nil)
        }
    }

    // MARK: show lldp info remote-device

    /// "3821c7-c1cd00", "3c e1 a1 22 18 f0", "38:21:c7:c1:cd:00".
    static func isMAC(_ s: String) -> Bool {
        s.filter(\.isHexDigit).count == 12 && s.allSatisfy { $0.isHexDigit || $0 == " " || $0 == "-" || $0 == ":" }
    }

    /// "LocalPort | ChassisId PortId PortDescr SysName": the chassis and port IDs may be hex bytes with spaces,
    /// so the columns come from the header.
    public static func lldpNeighbors(_ text: String) -> [LLDPNeighbor] {
        let lines = text.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\r", with: "") }
        guard let h = lines.firstIndex(where: { $0.contains("LocalPort") && $0.contains("ChassisId") }) else { return [] }
        let header = lines[h]
        guard let cChassis = CiscoParsers.column(header, "ChassisId"), let cPort = CiscoParsers.column(header, "PortId") else { return [] }
        let cDesc = CiscoParsers.column(header, "PortDescr")
        let cName = CiscoParsers.column(header, "SysName")
        var out: [LLDPNeighbor] = []
        for line in lines[(h + 1)...] {
            guard let bar = line.firstIndex(of: "|") else { continue }
            let local = line[..<bar].trimmingCharacters(in: .whitespaces)
            guard !local.isEmpty, !local.hasPrefix("-") else { continue }
            let chars = Array(line)
            let chassis = CiscoParsers.slice(chars, cChassis, cPort)
            let portID = CiscoParsers.slice(chars, cPort, cDesc ?? cName)
            let portDesc = cDesc.map { CiscoParsers.slice(chars, $0, cName) } ?? ""
            // A phone or PC sends its MAC address as port ID; its description reads better.
            out.append(LLDPNeighbor(
                localInterface: local,
                chassisID: isMAC(chassis) ? CiscoParsers.normalizeMAC(chassis) : chassis,
                portInfo: isMAC(portID) && !portDesc.isEmpty ? portDesc : portID,
                systemName: cName.map { CiscoParsers.slice(chars, $0, nil) } ?? ""))
        }
        return out
    }
}
