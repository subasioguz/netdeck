import Foundation

public struct InterfaceStatus: Equatable, Sendable {
    public var name: String
    public var adminUp: Bool
    public var linkUp: Bool
}

public struct MACEntry: Equatable, Sendable, Hashable {
    public var vlan: String
    public var mac: String
    public var flags: String
    public var interface: String
}

public struct LLDPNeighbor: Equatable, Sendable {
    public var localInterface: String
    public var chassisID: String
    public var portInfo: String
    public var systemName: String
}

public struct HardwareInfo: Equatable, Sendable {
    public struct Transceiver: Equatable, Sendable {
        public var fpc: Int
        public var pic: Int
        public var port: Int
        public var partNumber: String
        public var serial: String
        public var description: String
    }
    public struct PIC: Equatable, Sendable {
        public var fpc: Int
        public var pic: Int
        public var description: String
        /// "4x 1G/10G SFP/SFP+" → 4
        public var portCount: Int? { Int(description.prefix { $0.isNumber }) }
        public var isSFP: Bool { description.uppercased().contains("SFP") }
    }
    public var model: String?
    public var serial: String?
    public var pics: [PIC] = []
    public var transceivers: [Transceiver] = []
}

public struct CommitEntry: Equatable, Sendable, Identifiable {
    public var index: Int?          // nil for "rescue"
    public var isRescue: Bool
    public var timestamp: String    // as printed by the switch, e.g. "2026-10-30 05:37:08 EET"
    public var user: String
    public var client: String       // cli, junoscript, netconf, button ...
    public var confirmed: Bool      // "commit confirmed, rollback in Nmins"
    public var comment: String?
    /// Minutes of the confirm timer for a `commit confirmed` ("rollback in 5mins").
    public var confirmMinutes: Int? = nil
    public var id: String { isRescue ? "rescue" : String(index ?? -1) }

    /// The timestamp as a date. It follows the switch clock, which may be wrong.
    public var date: Date? {
        let parts = timestamp.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = timeZone ?? .current
        return f.date(from: parts[0] + " " + parts[1])
    }

    /// The switch's time zone from the timestamp ("EET"), to show dates as the switch printed them.
    public var timeZone: TimeZone? {
        let parts = timestamp.split(separator: " ")
        guard parts.count >= 3 else { return nil }
        let zone = String(parts[2])
        return Self.zones[zone] ?? TimeZone(abbreviation: zone)
    }

    /// Abbreviations Foundation doesn't resolve on its own (Junos prints the zone's short name).
    static let zones: [String: TimeZone] = [
        "EET": TimeZone(secondsFromGMT: 2 * 3600)!, "EEST": TimeZone(secondsFromGMT: 3 * 3600)!,
        "CET": TimeZone(secondsFromGMT: 1 * 3600)!, "CEST": TimeZone(secondsFromGMT: 2 * 3600)!,
        "UTC": TimeZone(secondsFromGMT: 0)!, "GMT": TimeZone(secondsFromGMT: 0)!,
    ]
}

/// Rear QSFP+ ports used for Virtual Chassis stacking (`show virtual-chassis vc-port`).
public struct VCPort: Equatable, Sendable {
    public var pic: Int
    public var port: Int
    public var type: String      // Configured, Dedicated, Auto-Configured
    public var status: String    // Up, Down, Absent
}

public struct VersionInfo: Equatable, Sendable {
    public var hostname: String?
    public var model: String?
    public var junos: String?
}

public enum OutputParsers {
    // show interfaces terse
    public static func interfacesTerse(_ text: String) -> [InterfaceStatus] {
        var out: [InterfaceStatus] = []
        for line in text.components(separatedBy: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 3, !cols[0].contains("."),
                  cols[1] == "up" || cols[1] == "down",
                  cols[2] == "up" || cols[2] == "down" else { continue }
            out.append(.init(name: cols[0], adminUp: cols[1] == "up", linkUp: cols[2] == "up"))
        }
        return out
    }

    // show ethernet-switching table
    public static func macTable(_ text: String) -> [MACEntry] {
        let mac = #"([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})"#
        let pattern = #"^\s*(\S+)\s+"# + mac + #"\s+(\S+)\s+(\S+)\s+(\S+)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        var out: [MACEntry] = []
        for line in text.components(separatedBy: "\n") {
            let ns = line as NSString
            guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let g = { (i: Int) in ns.substring(with: m.range(at: i)) }
            out.append(.init(vlan: g(1), mac: g(2).lowercased(), flags: g(3), interface: InterfaceName.physical(g(5))))
        }
        return out
    }

    // show lldp neighbors — fixed-width columns located from the header line
    public static func lldpNeighbors(_ text: String) -> [LLDPNeighbor] {
        let lines = text.components(separatedBy: "\n")
        guard let hIdx = lines.firstIndex(where: { $0.hasPrefix("Local Interface") }) else { return [] }
        let header = lines[hIdx]
        func col(_ title: String) -> Int? {
            header.range(of: title).map { header.distance(from: header.startIndex, to: $0.lowerBound) }
        }
        guard let cChassis = col("Chassis Id"), let cPort = col("Port info"), let cName = col("System Name") else { return [] }
        func slice(_ s: String, _ a: Int, _ b: Int?) -> String {
            let chars = Array(s)
            guard a < chars.count else { return "" }
            let end = min(b ?? chars.count, chars.count)
            return String(chars[a..<max(a, end)]).trimmingCharacters(in: .whitespaces)
        }
        var out: [LLDPNeighbor] = []
        for line in lines[(hIdx + 1)...] where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let local = line.split(separator: " ").first.map(String.init) ?? ""
            guard local.contains("-") || local.hasPrefix("me") else { continue }
            out.append(.init(
                localInterface: InterfaceName.physical(local),
                chassisID: slice(line, cChassis, cPort),
                portInfo: slice(line, cPort, cName),
                systemName: slice(line, cName, nil)
            ))
        }
        return out
    }

    // show chassis hardware
    public static func chassisHardware(_ text: String) -> HardwareInfo {
        var info = HardwareInfo()
        let lines = text.components(separatedBy: "\n")
        guard let hIdx = lines.firstIndex(where: { $0.hasPrefix("Item") }) else { return info }
        let header = lines[hIdx]
        func col(_ title: String) -> Int {
            header.range(of: title).map { header.distance(from: header.startIndex, to: $0.lowerBound) } ?? 0
        }
        let cPart = col("Part number"), cSerial = col("Serial number"), cDesc = col("Description")
        func slice(_ s: String, _ a: Int, _ b: Int?) -> String {
            let chars = Array(s)
            guard a < chars.count else { return "" }
            let end = min(b ?? chars.count, chars.count)
            return String(chars[a..<max(a, end)]).trimmingCharacters(in: .whitespaces)
        }
        var fpc = 0, pic = 0
        for line in lines[(hIdx + 1)...] {
            let item = line.trimmingCharacters(in: .whitespaces)
            if item.hasPrefix("Chassis") {
                info.serial = slice(line, cSerial, cDesc)
                info.model = slice(line, cDesc, nil)
            } else if let m = item.range(of: #"^FPC (\d+)"#, options: .regularExpression) {
                fpc = Int(item[m].dropFirst(4)) ?? 0
            } else if let m = item.range(of: #"^PIC (\d+)"#, options: .regularExpression) {
                pic = Int(item[m].dropFirst(4)) ?? 0
                info.pics.append(.init(fpc: fpc, pic: pic, description: slice(line, cDesc, nil)))
            } else if let m = item.range(of: #"^Xcvr (\d+)"#, options: .regularExpression) {
                let port = Int(item[m].dropFirst(5)) ?? 0
                info.transceivers.append(.init(
                    fpc: fpc, pic: pic, port: port,
                    partNumber: slice(line, cPart, cSerial),
                    serial: slice(line, cSerial, cDesc),
                    description: slice(line, cDesc, nil)
                ))
            }
        }
        return info
    }

    // show system commit
    public static func commitHistory(_ text: String) -> [CommitEntry] {
        let pattern = #"^(\d+|rescue)\s+(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \S+) by (\S+) via (\S+)(.*)$"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        var out: [CommitEntry] = []
        for line in text.components(separatedBy: "\n") {
            let ns = line as NSString
            if let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let g = { (i: Int) in ns.substring(with: m.range(at: i)) }
                let idx = g(1)
                out.append(.init(
                    index: Int(idx), isRescue: idx == "rescue", timestamp: g(2), user: g(3), client: g(4),
                    confirmed: g(5).contains("commit confirmed"), comment: nil,
                    confirmMinutes: g(5).range(of: #"rollback in (\d+) ?min"#, options: .regularExpression)
                        .flatMap { Int(g(5)[$0].filter(\.isNumber)) }
                ))
            } else if line.hasPrefix("    "), !out.isEmpty, out[out.count - 1].comment == nil {
                let c = line.trimmingCharacters(in: .whitespaces)
                if !c.isEmpty { out[out.count - 1].comment = c }
            }
        }
        return out
    }

    // show virtual-chassis vc-port
    public static func vcPorts(_ text: String) -> [VCPort] {
        let statuses = ["Up", "Down", "Absent"]
        var out: [VCPort] = []
        for line in text.components(separatedBy: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 3, let slash = cols[0].firstIndex(of: "/"),
                  let pic = Int(cols[0][..<slash]), let port = Int(cols[0][cols[0].index(after: slash)...]) else { continue }
            let status = cols.dropFirst(2).first { statuses.contains($0) } ?? "?"
            out.append(.init(pic: pic, port: port, type: cols[1], status: status))
        }
        return out.sorted { ($0.pic, $0.port) < ($1.pic, $1.port) }
    }

    // show version
    public static func version(_ text: String) -> VersionInfo {
        var v = VersionInfo()
        for line in text.components(separatedBy: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("Hostname:") { v.hostname = value(l) }
            if l.hasPrefix("Model:") { v.model = value(l) }
            if l.hasPrefix("Junos:") { v.junos = value(l) }
        }
        return v
    }

    /// `show | compare | count` → "Count: 3 lines"
    public static func count(_ text: String) -> Int? {
        guard let r = text.range(of: #"Count: (\d+) lines"#, options: .regularExpression) else { return nil }
        return Int(text[r].split(separator: " ")[1])
    }

    /// Lines that indicate the CLI rejected a command.
    public static func errors(in text: String) -> [String] {
        text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { l in
            l.hasPrefix("error:") || l.hasPrefix("syntax error") || l.hasPrefix("unknown command")
                || l.hasPrefix("missing argument") || l.hasPrefix("invalid") || l.contains("is not valid")
        }
    }

    private static func value(_ l: String) -> String {
        l.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }
}
