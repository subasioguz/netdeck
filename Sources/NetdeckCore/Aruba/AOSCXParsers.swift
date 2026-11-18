import Foundation

/// `show system` of an AOS-CX switch.
public struct AOSCXSystem: Equatable, Sendable {
    public var hostname: String?
    /// "JL661A 6300M 48G CL4 PoE 4SFP56 Swch"
    public var productName: String?
    public var serial: String?
    public var version: String?
}

/// One `interface` block of the running configuration.
public struct AOSCXInterfaceConfig: Equatable, Sendable {
    /// "1/1/1", "lag1", "vlan10", "mgmt"
    public var name: String
    public var description: String?
    /// nil when the configuration says neither `shutdown` nor `no shutdown`.
    public var shutdown: Bool?
    /// nil when neither `routing` nor `no routing` is configured (the platform default applies).
    public var routing: Bool?
    public var accessVLAN: Int?
    public var trunkNative: Int?
    /// `vlan trunk allowed`; nil when not configured, `allowedAll` for "all".
    public var trunkAllowed: [Int]?
    public var allowedAll = false
    /// Member of `lag<N>`.
    public var lag: Int?
    public var addresses: [String] = []

    public var isTrunk: Bool { trunkNative != nil || trunkAllowed != nil || allowedAll }
}

/// A `vlan` block: unnamed VLANs have neither name nor description.
public struct AOSCXVLANConfig: Equatable, Sendable {
    public var name: String?
    public var description: String?
}

public struct AOSCXRunningConfig: Equatable, Sendable {
    public var hostname: String?
    public var vlans: [Int: AOSCXVLANConfig] = [:]
    public var interfaces: [AOSCXInterfaceConfig] = []
}

/// One row of `show interface brief`.
public struct AOSCXInterfaceRow: Equatable, Sendable {
    public var port: String
    public var nativeVLAN: Int?
    /// "access", "trunk", "routed" or "--"
    public var mode: String
    /// "1GbT", "SFP+SR", "--" (empty cage)
    public var type: String
    public var enabled: Bool
    public var up: Bool
    public var reason: String
    /// Mb/s, nil when "--"
    public var speed: Int?
    public var description: String?
}

/// Parsers for AOS-CX `show` output. Fixed-width tables are read by their header columns.
public enum AOSCXParsers {
    // MARK: show version / show system

    /// "ArubaOS-CX" (10.10 and later) or "AOS-CX" (some releases and the documentation).
    public static func isAOSCX(_ version: String) -> Bool {
        version.contains("ArubaOS-CX") || version.contains("AOS-CX")
    }

    /// "Version      : FL.10.13.1101" → "FL.10.13.1101".
    public static func osVersion(_ text: String) -> String? {
        CiscoParsers.capture(#"(?m)^\s*(?:ArubaOS-CX |AOS-CX )?Version\s*:\s*([A-Z]{2}\.\d+\.\d+\.\d+)"#, in: text)?.first
    }

    /// "FL.10.13.1101" → (10, 13).
    public static func release(_ version: String) -> (major: Int, minor: Int)? {
        guard let c = CiscoParsers.capture(#"^[A-Z]{2}\.(\d+)\.(\d+)"#, in: version), let a = Int(c[0]), let b = Int(c[1]) else { return nil }
        return (a, b)
    }

    public static func system(_ text: String) -> AOSCXSystem {
        var s = AOSCXSystem()
        for line in text.components(separatedBy: "\n") {
            guard let colon = line.range(of: " : ") ?? line.range(of: ":") else { continue }
            let key = line[..<colon.lowerBound].trimmingCharacters(in: .whitespaces)
            let value = line[colon.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch key {
            case "Hostname": s.hostname = value
            case "Product Name": s.productName = value
            case "Chassis Serial Nbr", "Serial Number": s.serial = value
            case "ArubaOS-CX Version", "AOS-CX Version": s.version = value
            default: break
            }
        }
        return s
    }

    /// "JL661A 6300M 48G CL4 PoE 4SFP56 Swch" → "JL661A 6300M 48G CL4 PoE 4SFP56".
    public static func model(fromProduct product: String) -> String {
        var p = product.trimmingCharacters(in: .whitespaces)
        for suffix in [" Swch", " Switch"] where p.hasSuffix(suffix) { p.removeLast(suffix.count) }
        return p
    }

    // MARK: show running-config

    public static func runningConfig(_ text: String) -> AOSCXRunningConfig {
        var rc = AOSCXRunningConfig()
        var vlan: Int?
        var current: AOSCXInterfaceConfig?
        func flush() {
            if let c = current { rc.interfaces.append(c) }
            current = nil
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\r", with: "")
            guard !line.isEmpty, !line.hasPrefix("!") else { continue }
            let indented = line.first?.isWhitespace ?? false
            let t = line.trimmingCharacters(in: .whitespaces)
            if !indented {
                flush()
                vlan = nil
                if t.hasPrefix("hostname ") {
                    rc.hostname = String(t.dropFirst("hostname ".count))
                } else if t.hasPrefix("vlan "), let ids = CiscoParsers.vlanList(String(t.dropFirst("vlan ".count))) {
                    // "vlan 10" opens a block; "vlan 1,42,48-49" lists VLANs without settings.
                    for id in ids where rc.vlans[id] == nil { rc.vlans[id] = AOSCXVLANConfig() }
                    vlan = ids.count == 1 ? ids[0] : nil
                } else if t.hasPrefix("interface ") {
                    current = AOSCXInterfaceConfig(name: interfaceName(String(t.dropFirst("interface ".count))))
                }
                continue
            }
            if let v = vlan {
                if t.hasPrefix("name ") { rc.vlans[v]?.name = String(t.dropFirst("name ".count)) }
                if t.hasPrefix("description ") { rc.vlans[v]?.description = String(t.dropFirst("description ".count)) }
            } else if current != nil {
                parseInterfaceLine(t, into: &current!)
            }
        }
        flush()
        return rc
    }

    /// "lag 7 multi-chassis static" → "lag7", "vlan 42" → "vlan42", "1/1/1" → "1/1/1".
    static func interfaceName(_ s: String) -> String {
        let words = s.split(separator: " ").map(String.init)
        guard let first = words.first else { return s }
        if (first == "lag" || first == "vlan" || first == "loopback"), words.count > 1 { return first + words[1] }
        return first
    }

    static func parseInterfaceLine(_ t: String, into c: inout AOSCXInterfaceConfig) {
        if t.hasPrefix("description ") {
            c.description = String(t.dropFirst("description ".count))
        } else if t == "shutdown" {
            c.shutdown = true
        } else if t == "no shutdown" {
            c.shutdown = false
        } else if t == "routing" {
            c.routing = true
        } else if t == "no routing" {
            c.routing = false
        } else if t.hasPrefix("vlan access "), let id = Int(t.dropFirst("vlan access ".count)) {
            c.accessVLAN = id
        } else if t.hasPrefix("vlan trunk native "), let id = Int(t.dropFirst("vlan trunk native ".count).prefix { $0.isNumber }) {
            c.trunkNative = id
        } else if t.hasPrefix("vlan trunk allowed ") {
            let spec = String(t.dropFirst("vlan trunk allowed ".count))
            if spec == "all" {
                c.allowedAll = true
                c.trunkAllowed = nil
            } else if let ids = CiscoParsers.vlanList(spec) {
                // Long lists may be split over several lines.
                c.trunkAllowed = (c.trunkAllowed ?? []) + ids
            }
        } else if t.hasPrefix("lag "), let n = Int(t.dropFirst("lag ".count)) {
            c.lag = n
        } else if t.hasPrefix("ip address "), let a = t.dropFirst("ip address ".count).split(separator: " ").first {
            c.addresses.append(String(a))
        }
    }

    /// The running configuration as kept in History & backups: without the "Current configuration:" header.
    public static func configText(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "\r", with: "") }
            .filter { !$0.hasPrefix("Current configuration:") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
    }

    // MARK: show interface brief

    /// The first six columns are single words; Reason, Speed and Description are located from the header
    /// (Reason may be empty or several words).
    public static func interfaceBrief(_ text: String) -> [AOSCXInterfaceRow] {
        let lines = text.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\r", with: "") }
        guard let h = lines.firstIndex(where: { $0.hasPrefix("Port") && $0.contains("Mode") && $0.contains("Status") }) else { return [] }
        let header = lines[h]
        guard let cReason = CiscoParsers.column(header, "Reason"), let cSpeed = CiscoParsers.column(header, "Speed") else { return [] }
        let cDescription = CiscoParsers.column(header, "Description")
        var out: [AOSCXInterfaceRow] = []
        for line in lines[(h + 1)...] {
            guard let first = line.first, !first.isWhitespace, !line.hasPrefix("---") else { continue }
            let chars = Array(line)
            let head = String(chars.prefix(cReason)).split(separator: " ").map(String.init)
            guard head.count >= 6 else { continue }
            let speed = CiscoParsers.slice(chars, cSpeed, cDescription)
            let description = cDescription.map { CiscoParsers.slice(chars, $0, nil) }
            out.append(AOSCXInterfaceRow(
                port: head[0], nativeVLAN: Int(head[1]), mode: head[2], type: head[3],
                enabled: head[4].lowercased() == "yes", up: head[5].lowercased() == "up",
                reason: CiscoParsers.slice(chars, cReason, cSpeed),
                speed: Int(speed.split(separator: " ").first ?? ""),
                description: description.flatMap { $0.isEmpty || $0 == "--" ? nil : $0 }))
        }
        return out
    }

    // MARK: show vlan

    /// VLAN ID and name (names may contain spaces, so the Name column is located from the header).
    public static func vlans(_ text: String) -> [(id: Int, name: String)] {
        let lines = text.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\r", with: "") }
        guard let h = lines.firstIndex(where: { $0.hasPrefix("VLAN") && $0.contains("Name") && $0.contains("Status") }) else { return [] }
        let header = lines[h]
        guard let cName = CiscoParsers.column(header, "Name"), let cStatus = CiscoParsers.column(header, "Status") else { return [] }
        var out: [(id: Int, name: String)] = []
        for line in lines[(h + 1)...] {
            let chars = Array(line)
            guard let id = Int(CiscoParsers.slice(chars, 0, cName)) else { continue }
            out.append((id: id, name: CiscoParsers.slice(chars, cName, cStatus)))
        }
        return out
    }

    // MARK: show mac-address-table

    public static func macTable(_ text: String) -> [(mac: String, vlan: Int, type: String, port: String)] {
        text.components(separatedBy: "\n").compactMap { line in
            let w = line.split(separator: " ").map(String.init)
            guard w.count >= 4, w[0].filter(\.isHexDigit).count == 12, w[0].contains(":"), let vlan = Int(w[1]) else { return nil }
            return (mac: CiscoParsers.normalizeMAC(w[0]), vlan: vlan, type: w[2], port: w[3])
        }
    }

    // MARK: show lldp neighbor-info

    /// PORT-DESC and SYS-NAME may contain spaces: columns come from the header.
    public static func lldpNeighbors(_ text: String) -> [LLDPNeighbor] {
        let lines = text.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\r", with: "") }
        guard let h = lines.firstIndex(where: { $0.hasPrefix("LOCAL-PORT") && $0.contains("CHASSIS-ID") }) else { return [] }
        let header = lines[h]
        guard let cChassis = CiscoParsers.column(header, "CHASSIS-ID"), let cPort = CiscoParsers.column(header, "PORT-ID") else { return [] }
        let cDesc = CiscoParsers.column(header, "PORT-DESC")
        let cTTL = CiscoParsers.column(header, "TTL")
        let cName = CiscoParsers.column(header, "SYS-NAME")
        var out: [LLDPNeighbor] = []
        for line in lines[(h + 1)...] {
            guard let first = line.first, !first.isWhitespace, !line.hasPrefix("---") else { continue }
            let chars = Array(line)
            let local = CiscoParsers.slice(chars, 0, cChassis)
            guard local.contains("/") || local.hasPrefix("lag") else { continue }
            let portID = CiscoParsers.slice(chars, cPort, cDesc ?? cTTL)
            let portDesc = cDesc.map { CiscoParsers.slice(chars, $0, cTTL) } ?? ""
            let chassis = CiscoParsers.slice(chars, cChassis, cPort)
            // A phone or PC sends its MAC address as port ID; its description ("LAN Port") reads better.
            let portIsMAC = portID.filter(\.isHexDigit).count == 12 && portID.contains(":")
            out.append(LLDPNeighbor(
                localInterface: local,
                chassisID: chassis.contains(":") ? CiscoParsers.normalizeMAC(chassis) : chassis,
                portInfo: portIsMAC && !portDesc.isEmpty ? portDesc : portID,
                systemName: cName.map { CiscoParsers.slice(chars, $0, nil) } ?? ""))
        }
        return out
    }
}
