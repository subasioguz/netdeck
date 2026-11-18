import Foundation

/// What the identity command printed ("platform=pfSense", "opnsense=OPNsense 25.1.5_5", ...).
public struct PFIdentity: Equatable, Sendable {
    /// `.pfsense` or `.opnsense`; nil when it is neither.
    public var platform: Platform?
    /// "2.7.2-RELEASE", "24.11-RELEASE", "25.1.5_5".
    public var version: String?
    public var hostname: String?
    /// SMBIOS product ("DEC740", "Netgate 4200"), nil for placeholders such as "To Be Filled By O.E.M.".
    public var model: String?
    public var serial: String?
}

/// One interface of `ifconfig -a`.
public struct PFIfconfig: Equatable, Sendable {
    public var name: String
    public var up = false
    public var mac: String?
    /// "192.0.2.1/24".
    public var addresses: [String] = []
    public var description: String?
    /// "Ethernet autoselect (1000baseT <full-duplex>)".
    public var media: String?
    /// "active", "no carrier".
    public var status: String?
    /// VLAN interfaces: tag and parent.
    public var vlanTag: Int?
    public var parent: String?
    /// LAGG members (`laggport:` lines).
    public var laggPorts: [String] = []
    public var isBridge = false

    public var linkUp: Bool { status == "active" }
}

public struct PFARPEntry: Equatable, Sendable {
    public var ip: String
    public var mac: String
    public var interface: String
}

/// The parts of `/conf/config.xml` Netdeck shows.
public struct PFConfig: Equatable, Sendable {
    /// An assigned interface (`<wan>`, `<lan>`, `<opt1>`...).
    public struct Assigned: Equatable, Sendable {
        public var key: String
        /// The device it sits on: "igb0", "igb1.20", "vlan01", "lagg0", "pppoe0".
        public var device: String
        public var descr: String?
        public var enabled = false
        /// "dhcp", "pppoe", an address, or nil.
        public var ipaddr: String?
        public var subnet: Int?

        /// "WAN", "LAN", "SERVERS"; the key in capitals without a description.
        public var label: String { descr.flatMap { $0.isEmpty ? nil : $0 } ?? key.uppercased() }
    }
    public struct VLAN: Equatable, Sendable {
        public var parent: String
        public var tag: Int
        public var descr: String?
        public var device: String
    }
    public struct Lagg: Equatable, Sendable {
        public var device: String
        public var members: [String]
    }
    /// PPPoE and other PPP links: the `pppoe0` device and the ports it dials out on.
    public struct PPP: Equatable, Sendable {
        public var device: String
        public var ports: [String]
    }

    public var hostname: String?
    public var domain: String?
    public var interfaces: [Assigned] = []
    public var vlans: [VLAN] = []
    public var laggs: [Lagg] = []
    public var ppps: [PPP] = []
}

/// Parsers for pfSense / OPNsense shell output. Pure, so they are unit-tested with captures.
public enum PFParsers {
    /// The identity command: one `key=value` line each, empty values for what the system doesn't have.
    static let identityCommand = [
        #"printf 'platform=%s\n' "$(cat /etc/platform 2>/dev/null)""#,
        #"printf 'version=%s\n' "$(cat /etc/version 2>/dev/null)""#,
        #"printf 'opnsense=%s\n' "$(opnsense-version 2>/dev/null)""#,
        #"printf 'hostname=%s\n' "$(hostname)""#,
        #"printf 'product=%s\n' "$(kenv -q smbios.system.product 2>/dev/null)""#,
        #"printf 'serial=%s\n' "$(kenv -q smbios.system.serial 2>/dev/null)""#,
    ].joined(separator: "; ")

    static let placeholderModels = ["to be filled by o.e.m.", "system product name", "default string", "not specified",
                                    "not applicable", "none", "o.e.m.", "standard pc (i440fx + piix, 1996)", "standard pc (q35 + ich9, 2009)"]

    public static func identity(_ s: String) -> PFIdentity {
        var values: [String: String] = [:]
        for raw in s.components(separatedBy: "\n") {
            guard let eq = raw.firstIndex(of: "=") else { continue }
            let key = raw[..<eq].trimmingCharacters(in: .whitespaces)
            values[key] = raw[raw.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        var id = PFIdentity()
        if let o = values["opnsense"], o.hasPrefix("OPNsense") {
            id.platform = .opnsense
            id.version = o.split(separator: " ").dropFirst().first.map(String.init)
        } else if values["platform"] == "pfSense" || values["platform"] == "pfSense Plus" {
            id.platform = .pfsense
            id.version = values["version"].flatMap { $0.isEmpty ? nil : $0 }
        }
        id.hostname = values["hostname"].flatMap { $0.isEmpty ? nil : $0 }
        if let p = values["product"], !p.isEmpty, !placeholderModels.contains(p.lowercased()) { id.model = p }
        if let s = values["serial"], !s.isEmpty, !placeholderModels.contains(s.lowercased()),
           s.range(of: #"^[0 .\-]*$"#, options: .regularExpression) == nil { id.serial = s }
        return id
    }

    // MARK: ifconfig

    public static func ifconfig(_ s: String) -> [PFIfconfig] {
        var out: [PFIfconfig] = []
        var current: PFIfconfig?
        for raw in s.components(separatedBy: "\n") {
            if let c = CiscoParsers.capture(#"^([A-Za-z][\w.\-]*): flags=[0-9a-f]+<([^>]*)>"#, in: raw) {
                if let cur = current { out.append(cur) }
                current = PFIfconfig(name: c[0])
                current?.up = c[1].split(separator: ",").contains("UP")
                continue
            }
            guard current != nil else { continue }
            let l = raw.trimmingCharacters(in: .whitespaces)
            if let v = value(l, "description:") { current?.description = v }
            else if let v = value(l, "ether") { current?.mac = v.split(separator: " ").first.map { String($0).lowercased() } }
            else if let c = CiscoParsers.capture(#"^inet (\d+\.\d+\.\d+\.\d+)(?: --> \S+)? netmask (0x[0-9a-fA-F]{8})"#, in: l) {
                current?.addresses.append("\(c[0])/\(prefixLength(hex: c[1]))")
            }
            else if let v = value(l, "media:") { current?.media = v }
            else if let v = value(l, "status:") { current?.status = v }
            else if let c = CiscoParsers.capture(#"^vlan: (\d+).*parent interface: (\S+)"#, in: l) {
                current?.vlanTag = Int(c[0])
                current?.parent = c[1]
            }
            else if let v = value(l, "laggport:") { current?.laggPorts.append(String(v.split(separator: " ").first ?? "")) }
            else if l.hasPrefix("groups:"), l.split(separator: " ").contains("bridge") { current?.isBridge = true }
        }
        if let cur = current { out.append(cur) }
        return out
    }

    private static func value(_ line: String, _ key: String) -> String? {
        guard line.hasPrefix(key + " ") else { return nil }
        return String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
    }

    /// "0xffffff00" → 24.
    static func prefixLength(hex: String) -> Int {
        UInt32(hex.dropFirst(2), radix: 16).map { $0.nonzeroBitCount } ?? 0
    }

    /// A network port (not a VLAN, LAGG, bridge, tunnel, loopback or pf device).
    static func isPort(_ i: PFIfconfig) -> Bool {
        guard i.vlanTag == nil, i.laggPorts.isEmpty, !i.isBridge, i.mac != nil, i.media != nil else { return false }
        guard i.name.range(of: #"^[a-z]+\d+$"#, options: .regularExpression) != nil else { return false }
        let virtual = ["lo", "enc", "pflog", "pfsync", "gif", "gre", "tun", "tap", "bridge", "lagg", "vlan", "qinq", "ovpns", "ovpnc",
                       "wg", "ipsec", "ppp", "pppoe", "pptp", "l2tp", "carp", "stf", "tailscale", "zt", "vxlan", "epair", "ue"]
        let prefix = String(i.name.prefix { $0.isLetter })
        return !virtual.contains(prefix)
    }

    /// "(1000baseT <full-duplex>)" → "1G"; "(2500Base-T ...)" → "2.5G"; "(10Gbase-Twinax ...)" → "10G";
    /// "(100baseTX ...)" → "100Mbps". Nil without a link (no active media in brackets).
    static func speed(media: String?) -> String? {
        guard let m = media, let c = CiscoParsers.capture(#"\((\d+(?:\.\d+)?)(G?)[Bb]ase"#, in: m), let n = Double(c[0]) else { return nil }
        let mbps = c[1] == "G" ? n * 1000 : n
        if mbps >= 1000 {
            let g = mbps / 1000
            return g == g.rounded() ? "\(Int(g))G" : "\(g)G"
        }
        return "\(Int(mbps))Mbps"
    }

    /// The active media is an optic or a direct-attach cable (SR, LR, Twinax, SFI...).
    static func isCage(media: String?) -> Bool {
        guard let m = media, let c = CiscoParsers.capture(#"\(\d+(?:\.\d+)?G?[Bb]ase-?([A-Za-z0-9]+)"#, in: m) else { return false }
        return c[0].range(of: #"^(SR|LR|ER|ZR|LRM|SX|LX|ZX|BX|CX|CR|KR|SFI|SFP|Twinax|AOC|ACC)"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: ARP

    /// `arp -an`: "? (192.0.2.10) at 00:00:5e:00:53:10 on igb1 expires in 1199 seconds [ethernet]". The unit's own
    /// addresses ("permanent") and incomplete entries are left out.
    public static func arp(_ s: String) -> [PFARPEntry] {
        var out: [PFARPEntry] = []
        for raw in s.components(separatedBy: "\n") where !raw.contains("permanent") {
            guard let c = CiscoParsers.capture(#"\((\d+\.\d+\.\d+\.\d+)\) at ([0-9a-fA-F]{1,2}(?::[0-9a-fA-F]{1,2}){5}) on (\S+)"#, in: raw) else { continue }
            let mac = c[1].split(separator: ":").map { $0.count == 1 ? "0" + $0 : String($0) }.joined(separator: ":").lowercased()
            let e = PFARPEntry(ip: c[0], mac: mac, interface: c[2])
            if !out.contains(e) { out.append(e) }
        }
        return out
    }

    // MARK: config.xml

    /// `/conf/config.xml` of pfSense (`<pfsense>`) or OPNsense (`<opnsense>`); empty when it can't be read.
    public static func config(_ xml: String) -> PFConfig {
        var cfg = PFConfig()
        guard let start = xml.range(of: "<?xml") ?? xml.range(of: "<pfsense>") ?? xml.range(of: "<opnsense>"),
              let doc = try? XMLDocument(xmlString: String(xml[start.lowerBound...]), options: [.nodeLoadExternalEntitiesNever]),
              let root = doc.rootElement() else { return cfg }
        func text(_ e: XMLElement?, _ name: String) -> String? {
            guard let v = e?.elements(forName: name).first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            return v.isEmpty ? nil : v
        }
        let system = root.elements(forName: "system").first
        cfg.hostname = text(system, "hostname")
        cfg.domain = text(system, "domain")

        for e in root.elements(forName: "interfaces").first?.children?.compactMap({ $0 as? XMLElement }) ?? [] {
            guard let name = e.name, let device = text(e, "if") else { continue }
            // `<enable/>` (pfSense) or `<enable>1</enable>` (OPNsense) means on.
            let enable = e.elements(forName: "enable").first
            let on = enable != nil && (enable?.stringValue.map { $0.trimmingCharacters(in: .whitespaces) } ?? "") != "0"
            cfg.interfaces.append(PFConfig.Assigned(key: name, device: device, descr: text(e, "descr"), enabled: on,
                                                    ipaddr: text(e, "ipaddr"), subnet: text(e, "subnet").flatMap(Int.init)))
        }
        for e in root.elements(forName: "vlans").first?.elements(forName: "vlan") ?? [] {
            guard let parent = text(e, "if"), let tag = text(e, "tag").flatMap(Int.init) else { continue }
            let device = text(e, "vlanif") ?? "\(parent).\(tag)"
            cfg.vlans.append(PFConfig.VLAN(parent: parent, tag: tag, descr: text(e, "descr"), device: device))
        }
        for e in root.elements(forName: "laggs").first?.elements(forName: "lagg") ?? [] {
            guard let device = text(e, "laggif") else { continue }
            let members = (text(e, "members") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            cfg.laggs.append(PFConfig.Lagg(device: device, members: members))
        }
        for e in root.elements(forName: "ppps").first?.elements(forName: "ppp") ?? [] {
            guard let device = text(e, "if") else { continue }
            let ports = (text(e, "ports") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            cfg.ppps.append(PFConfig.PPP(device: device, ports: ports))
        }
        return cfg
    }
}
