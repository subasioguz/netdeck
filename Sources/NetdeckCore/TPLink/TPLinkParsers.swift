import Foundation

/// One row of `show interface status`.
public struct TPLinkPortRow: Equatable, Sendable {
    /// "Gi1/0/1", "Te1/0/25"
    public var port: String
    public var linkUp: Bool
    /// "1000M", "10G", nil for "N/A"
    public var speed: String?
    /// "Copper", "Fiber"
    public var medium: String?
}

/// Interface configuration from the running configuration.
public struct TPLinkInterfaceConfig: Equatable, Sendable {
    public var description: String?
    public var shutdown = false
    /// `switchport general allowed vlan 10,20-22 untagged`
    public var untagged: [Int] = []
    public var tagged: [Int] = []
    /// `no switchport general allowed vlan 1` (every port starts as an untagged member of VLAN 1)
    public var removedVLAN1 = false
    public var pvid: Int?
    /// `channel-group 1 mode active`
    public var channelGroup: Int?
}

public struct TPLinkRunningConfig: Equatable, Sendable {
    public var hostname: String?
    /// "!SG3428": the first line names the model.
    public var model: String?
    public var vlans: [Int: String] = [:]
    /// Keyed by the short name ("Gi1/0/5").
    public var interfaces: [String: TPLinkInterfaceConfig] = [:]
    /// Lines only a switch adopted by an Omada controller has (`sdm prefer omada`, `profile network id`).
    public var controllerManaged = false
}

/// `show system-info`: "Label  - value" lines.
public struct TPLinkSystemInfo: Equatable, Sendable {
    public var description: String?
    public var name: String?
    /// "TL-SG3452X" (first word of "Hardware Version - TL-SG3452X 1.0")
    public var model: String?
    public var hardwareVersion: String?
    /// "1.0.6 Build 20230702 Rel.70603"
    public var firmware: String?
    public var serial: String?
    public var mac: String?
    public var uptime: String?
}

/// Parsers for TP-Link Omada / JetStream switch CLI output. Pure functions over text.
public enum TPLinkParsers {
    // MARK: Names

    /// Long interface types as typed in the configuration, with their short form in tables.
    static let types: [(long: String, short: String)] = [
        ("fastEthernet", "Fa"), ("gigabitEthernet", "Gi"), ("two-gigabitEthernet", "Tw"),
        ("ten-gigabitEthernet", "Te"), ("twentyfive-gigabitEthernet", "Twe"), ("port-channel", "Po"),
    ]

    /// "gigabitEthernet 1/0/5" → "Gi1/0/5"; "GigabitEthernet1/0/2" (LLDP port IDs) too.
    public static func shortName(_ name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespaces)
        for t in types.sorted(by: { $0.long.count > $1.long.count }) {
            if n.lowercased().hasPrefix(t.long.lowercased()) {
                let rest = n.dropFirst(t.long.count).trimmingCharacters(in: .whitespaces)
                if rest.first?.isNumber == true { return t.short + rest }
            }
        }
        return n
    }

    /// "Gi1/0/5" → "gigabitEthernet 1/0/5", as configuration commands take it.
    public static func longName(_ short: String) -> String {
        for t in types.sorted(by: { $0.short.count > $1.short.count }) where short.hasPrefix(t.short) {
            let rest = short.dropFirst(t.short.count)
            if rest.first?.isNumber == true { return "\(t.long) \(rest)" }
        }
        return short
    }

    /// Front-panel port ("Gi1/0/5"), not a LAG or a VLAN interface.
    static func isFrontPort(_ short: String) -> Bool {
        short.range(of: #"^(Fa|Gi|Tw|Te|Twe)\d+/\d+/\d+$"#, options: .regularExpression) != nil
    }

    /// "10,20-22,30" → [10, 20, 21, 22, 30]
    public static func vlanList(_ s: String) -> [Int] {
        s.split(separator: ",").flatMap { part -> [Int] in
            let p = part.trimmingCharacters(in: .whitespaces)
            let ends = p.split(separator: "-").compactMap { Int($0) }
            if ends.count == 2, ends[0] <= ends[1], ends[1] - ends[0] < 4096 { return Array(ends[0]...ends[1]) }
            return Int(p).map { [$0] } ?? []
        }
    }

    /// [10, 20, 21, 22, 30] → "10,20-22,30"
    public static func vlanListString(_ ids: [Int]) -> String {
        let sorted = Array(Set(ids)).sorted()
        var parts: [String] = []
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count, sorted[j + 1] == sorted[j] + 1 { j += 1 }
            parts.append(j > i ? "\(sorted[i])-\(sorted[j])" : "\(sorted[i])")
            i = j + 1
        }
        return parts.joined(separator: ",")
    }

    // MARK: show system-info

    /// A TP-Link switch's `show system-info` (or a banner naming one).
    public static func isTPLink(_ text: String) -> Bool {
        if text.contains("JetStream") || text.contains("TP-Link") || text.contains("TP-LINK") || text.contains("Omada") { return true }
        let info = system(text)
        return info.hardwareVersion != nil && (info.firmware != nil || info.description != nil)
    }

    public static func system(_ text: String) -> TPLinkSystemInfo {
        var info = TPLinkSystemInfo()
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let r = line.range(of: " - ") else { continue }
            let key = line[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            let value = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch key {
            case "System Description": info.description = info.description ?? value
            case "System Name", "Device Name": info.name = info.name ?? value
            case "Hardware Version":
                info.hardwareVersion = info.hardwareVersion ?? value
                info.model = info.model ?? value.split(separator: " ").first.map(String.init)
            case "Software Version", "Firmware Version": info.firmware = info.firmware ?? value
            case "Serial Number": info.serial = info.serial ?? value
            case "Mac Address", "MAC Address", "MAC": info.mac = info.mac ?? value
            case "Running Time": info.uptime = info.uptime ?? value
            default: break
            }
        }
        return info
    }

    // MARK: show running-config

    public static func runningConfig(_ text: String) -> TPLinkRunningConfig {
        var rc = TPLinkRunningConfig()
        var vlanBlock: [Int] = []
        var iface: String?
        for raw in text.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\r", with: "")
            let t = line.trimmingCharacters(in: .whitespaces)
            if rc.model == nil, t.hasPrefix("!"), t.count > 1 { rc.model = String(t.dropFirst()); continue }
            if t.isEmpty || t == "#" || t == "!" { if t == "#" { vlanBlock = []; iface = nil }; continue }
            let indented = line.first == " "
            if !indented {
                vlanBlock = []
                iface = nil
                if let c = CiscoParsers.capture(#"^vlan ([\d,\-]+)$"#, in: t) {
                    vlanBlock = vlanList(c[0])
                    for id in vlanBlock where rc.vlans[id] == nil { rc.vlans[id] = "" }
                } else if let c = CiscoParsers.capture(#"^interface (.+)$"#, in: t) {
                    let name = shortName(c[0])
                    iface = name
                    if rc.interfaces[name] == nil { rc.interfaces[name] = TPLinkInterfaceConfig() }
                } else if let c = CiscoParsers.capture(#"^hostname "?([^"]*)"?$"#, in: t) {
                    rc.hostname = c[0]
                } else if t == "sdm prefer omada" || t.hasPrefix("profile network id ") || t.hasPrefix("profile ip id ") {
                    rc.controllerManaged = true
                }
                continue
            }
            if !vlanBlock.isEmpty, let c = CiscoParsers.capture(#"^name "?([^"]*)"?$"#, in: t) {
                for id in vlanBlock { rc.vlans[id] = c[0] }
                continue
            }
            guard let name = iface else { continue }
            var ic = rc.interfaces[name] ?? TPLinkInterfaceConfig()
            if let c = CiscoParsers.capture(#"^description "?([^"]*)"?$"#, in: t) {
                ic.description = c[0]
            } else if t == "shutdown" {
                ic.shutdown = true
            } else if let c = CiscoParsers.capture(#"^switchport general allowed vlan ([\d,\-]+) (untagged|tagged)$"#, in: t) {
                let ids = vlanList(c[0])
                if c[1] == "untagged" {
                    ic.untagged += ids.filter { !ic.untagged.contains($0) }
                    ic.tagged.removeAll { ids.contains($0) }
                } else {
                    ic.tagged += ids.filter { !ic.tagged.contains($0) }
                    ic.untagged.removeAll { ids.contains($0) }
                }
            } else if let c = CiscoParsers.capture(#"^no switchport general allowed vlan ([\d,\-]+)$"#, in: t) {
                let ids = vlanList(c[0])
                if ids.contains(1) { ic.removedVLAN1 = true }
                ic.untagged.removeAll { ids.contains($0) }
                ic.tagged.removeAll { ids.contains($0) }
            } else if let c = CiscoParsers.capture(#"^switchport pvid (\d+)$"#, in: t) {
                ic.pvid = Int(c[0])
            } else if let c = CiscoParsers.capture(#"^channel-group (\d+)"#, in: t) {
                ic.channelGroup = Int(c[0])
            }
            rc.interfaces[name] = ic
        }
        return rc
    }

    /// The configuration as stored in history and backups: no pager remnants, no padding `#` runs.
    public static func configText(_ text: String) -> String {
        var out: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let l = raw.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
            if l == "#", out.last == "#" { continue }
            out.append(l)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    /// Configuration lines that matter when comparing running and startup: no padding, blank or comment lines.
    static func significantLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "#" && !$0.hasPrefix("!") }
    }

    /// Running and startup configuration say the same (nothing unsaved).
    public static func sameConfiguration(_ a: String, _ b: String) -> Bool {
        let x = significantLines(a), y = significantLines(b)
        return !x.isEmpty && x == y
    }

    // MARK: show interface status

    /// "Port Status Speed Duplex FlowCtrl Active-Medium" (newer firmware adds columns): columns by header name.
    public static func interfaceStatus(_ text: String) -> [TPLinkPortRow] {
        let lines = text.components(separatedBy: "\n")
        guard let h = lines.firstIndex(where: {
            let w = $0.split(separator: " ")
            return w.first == "Port" && w.contains("Status")
        }) else { return [] }
        let header = lines[h].split(separator: " ").map(String.init)
        func col(_ name: String) -> Int? { header.firstIndex { $0.lowercased().hasPrefix(name.lowercased()) } }
        guard let cStatus = col("Status") else { return [] }
        let cSpeed = col("Speed"), cMedium = col("Active-Medium") ?? col("Medium")
        return lines[(h + 1)...].compactMap { line -> TPLinkPortRow? in
            let w = line.split(separator: " ").map(String.init)
            guard w.count > cStatus, w[0].contains("/"), !w[0].hasPrefix("-") else { return nil }
            let status = w[cStatus].lowercased()
            let speed = cSpeed.flatMap { $0 < w.count ? w[$0] : nil }
            let medium = cMedium.flatMap { $0 < w.count ? w[$0] : nil }
            return TPLinkPortRow(port: w[0], linkUp: status == "linkup" || status == "up",
                                 speed: speed == "N/A" ? nil : speed, medium: medium == "N/A" ? nil : medium)
        }
    }

    // MARK: show vlan

    /// "VLAN Name Status Ports": VLAN numbers and names (names may hold spaces; the status column follows).
    public static func vlans(_ text: String) -> [(id: Int, name: String)] {
        text.components(separatedBy: "\n").compactMap { line in
            guard let c = CiscoParsers.capture(#"^\s*(\d{1,4})\s+(.+?)\s+(active|inactive|act/\S+)\b"#, in: line) else { return nil }
            guard let id = Int(c[0]), (1...4094).contains(id) else { return nil }
            return (id: id, name: c[1])
        }
    }

    // MARK: show mac address-table

    /// "MAC VLAN Port Type Aging" (also "MAC vlan-id port type aging"). The switch's own CPU entries are left out.
    public static func macTable(_ text: String) -> [(mac: String, vlan: Int?, port: String)] {
        text.components(separatedBy: "\n").compactMap { line in
            let w = line.split(separator: " ").map(String.init)
            guard w.count >= 3, w[0].range(of: #"^([0-9a-fA-F]{2}[:\-]){5}[0-9a-fA-F]{2}$"#, options: .regularExpression) != nil else { return nil }
            guard w[2].contains("/") || w[2].hasPrefix("Po") else { return nil }
            return (mac: CiscoParsers.normalizeMAC(w[0]), vlan: Int(w[1]), port: w[2])
        }
    }

    // MARK: show lldp neighbor-information

    /// Detail blocks: "gigabitEthernet 1/0/1:" then "Chassis ID:", "Port ID:", "System name:" lines.
    public static func lldpNeighbors(_ text: String) -> [LLDPNeighbor] {
        var out: [LLDPNeighbor] = []
        var local: String?
        var current: LLDPNeighbor?
        func flush() {
            if let c = current, !c.chassisID.isEmpty || !c.systemName.isEmpty { out.append(c) }
            current = nil
        }
        for raw in text.components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasSuffix(":"), t.contains("/"), !t.contains("  ") {
                flush()
                local = shortName(String(t.dropLast()))
                continue
            }
            if t.hasPrefix("Neighbor index") {
                flush()
                if let local { current = LLDPNeighbor(localInterface: local, chassisID: "", portInfo: "", systemName: "") }
                continue
            }
            guard current != nil, let colon = t.range(of: ":") else { continue }
            let key = t[..<colon.lowerBound].trimmingCharacters(in: .whitespaces)
            let value = t[colon.upperBound...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "Chassis ID": current?.chassisID = AOSSParsers.isMAC(value) ? CiscoParsers.normalizeMAC(value) : value
            case "Port ID": current?.portInfo = value
            case "System name": current?.systemName = value
            default: break
            }
        }
        flush()
        return out
    }
}
