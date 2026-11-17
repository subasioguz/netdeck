import Foundation

/// Everything Netdeck shows about a switch at one point in time.
public struct SwitchSnapshot: Equatable, Sendable {
    public var takenAt: Date
    public var version: VersionInfo
    public var hardware: HardwareInfo
    public var config: JunosConfig
    public var configText: String
    public var statuses: [InterfaceStatus]
    public var macTable: [MACEntry]
    public var lldp: [LLDPNeighbor]
    public var commits: [CommitEntry]
    public var vcPorts: [VCPort]
    /// The platform this was read from. Junos snapshots derive their ports from the raw outputs below;
    /// other drivers build `explicitPorts` themselves.
    public var platform: Platform
    /// Front-panel ports built by a non-Junos driver, in display order. `nil` for Junos.
    public var explicitPorts: [SwitchPort]?
    /// Platform data a change planner needs beyond `config` (bridge ports, archive state...).
    public var vendor: VendorState
    /// Device kind as read (switch, router, firewall), when the driver knows it.
    public var readKind: DeviceKind?

    public init(
        takenAt: Date = .now, version: VersionInfo, hardware: HardwareInfo, config: JunosConfig, configText: String,
        statuses: [InterfaceStatus], macTable: [MACEntry], lldp: [LLDPNeighbor], commits: [CommitEntry],
        vcPorts: [VCPort] = [], platform: Platform = .juniperJunos, explicitPorts: [SwitchPort]? = nil,
        vendor: VendorState = .none, readKind: DeviceKind? = nil
    ) {
        self.takenAt = takenAt
        self.version = version
        self.hardware = hardware
        self.config = config
        self.configText = configText
        self.statuses = statuses
        self.macTable = macTable
        self.lldp = lldp
        self.commits = commits
        self.vcPorts = vcPorts
        self.platform = platform
        self.explicitPorts = explicitPorts
        self.vendor = vendor
        self.readKind = readKind
    }

    public var hostname: String { config.hostname ?? version.hostname ?? "switch" }
    public var model: String { hardware.model ?? version.model?.uppercased() ?? platform.vendor }
    /// OS version as printed by the device ("21.2R3.8", "7.16.1", "17.9.4").
    public var osVersion: String? { version.junos }
    /// Junos model traits (rear PIC, which ports are cages); `nil` for other platforms.
    public var junosModel: JunosModel? { platform == .juniperJunos ? JunosModel(model) : nil }

    /// Switch, router or firewall, as far as the reading tells.
    public var kind: DeviceKind? {
        if let readKind { return readKind }
        if platform == .juniperJunos { return DeviceDetector.junosKind(model) }
        return nil
    }

    /// The device has Ethernet switching (VLANs and a MAC table). Routers such as Juniper MX don't.
    public var hasSwitching: Bool {
        if !config.vlans.isEmpty { return true }
        if config.interfaces.values.contains(where: \.hasEthernetSwitching) { return true }
        if config.ranges.contains(where: { $0.config.hasEthernetSwitching }) { return true }
        return !macTable.isEmpty
    }

    /// Change handling of the platform (review sheet labels, history, timeout note).
    public var changeTraits: ChangeTraits { platform.changeTraits }

    /// Front-panel ports in display order: built-in copper first, then uplink-module cages.
    public var ports: [SwitchPort] {
        if let explicitPorts { return explicitPorts }
        return junosPorts
    }

    private var junosPorts: [SwitchPort] {
        let traits = JunosModel(model)
        var byKey: [String: SwitchPort] = [:]
        var order: [String] = []

        func status(_ name: String) -> InterfaceStatus? { statuses.first { $0.name == name } }

        for s in statuses where traits.isFrontPanel(s.name) {
            let key = Self.slotKey(s.name)
            if byKey[key] == nil { order.append(key) }
            var p = byKey[key] ?? SwitchPort(slotKey: key, name: s.name)
            // Uplink cages exist as both ge- and xe-; prefer the one that is up, else xe.
            if p.name != s.name {
                let current = status(p.name)
                if s.linkUp && !(current?.linkUp ?? false) { p.name = s.name }
                else if !(current?.linkUp ?? false) && s.name.hasPrefix("xe-") { p.name = s.name }
            }
            byKey[key] = p
        }

        // Empty uplink cages (no transceiver) do not show up in `show interfaces terse`.
        for pic in hardware.pics where pic.isSFP && pic.pic != traits.rearPIC && traits.listsEmptyCages(pic: pic.pic) {
            for n in 0..<(pic.portCount ?? 0) {
                let name = "xe-\(pic.fpc)/\(pic.pic)/\(n)"
                let key = Self.slotKey(name)
                if byKey[key] == nil {
                    byKey[key] = SwitchPort(slotKey: key, name: name)
                    order.append(key)
                }
            }
        }

        var result: [SwitchPort] = []
        for key in order {
            guard var p = byKey[key] else { continue }
            let st = status(p.name)
            let eff = config.effective(p.name)
            let hasModule = hardware.transceivers.contains { Self.slotKey("xe-\($0.fpc)/\($0.pic)/\($0.port)") == key }
            p.kind = traits.isCage(p.name, hasModule: hasModule) ? .sfp : .copper
            p.number = InterfaceName.portNumber(p.name) ?? 0
            p.adminUp = st?.adminUp ?? !eff.disabled
            p.linkUp = st?.linkUp ?? false
            p.present = st != nil
            p.description = eff.description
            p.configDisabled = eff.disabled
            p.disabledByRange = config.ranges(containing: p.name).first { $0.config.disabled }?.name
            p.mode = eff.mode ?? (eff.hasEthernetSwitching ? .access : nil)
            p.vlans = eff.vlanMembers.isEmpty && eff.hasEthernetSwitching ? ["default"] : eff.vlanMembers
            p.nativeVlanID = eff.nativeVlanID
            p.rstpEdge = config.rstpEdge.contains(p.name)
            p.addresses = eff.inetAddresses
            p.switching = eff.hasEthernetSwitching
            p.zone = config.zones[p.name]
            p.macs = macTable.filter { $0.interface == p.name }
            p.lldp = lldp.filter { $0.localInterface == p.name }
            if let x = hardware.transceivers.first(where: { Self.slotKey("xe-\($0.fpc)/\($0.pic)/\($0.port)") == key }) {
                p.transceiver = x
                p.warning = Self.transceiverWarning(x, interfaceName: p.name)
            }
            result.append(p)
        }
        return result.sorted { InterfaceName.sortKey($0.slotKey).lexicographicallyPrecedes(InterfaceName.sortKey($1.slotKey)) }
    }

    /// Rear-panel high-speed ports (EX4300: PIC 1, 4× QSFP+ 40G). Each is either a
    /// Virtual Chassis stacking port or, once converted, a normal `et-` network port.
    public var rearPorts: [RearPort] {
        guard let rear = junosModel?.rearPIC else { return [] }
        var out: [RearPort] = []
        for pic in hardware.pics where pic.pic == rear {
            for n in 0..<(pic.portCount ?? 0) {
                let et = "et-\(pic.fpc)/\(pic.pic)/\(n)"
                if let vc = vcPorts.first(where: { $0.pic == pic.pic && $0.port == n }) {
                    out.append(RearPort(name: "\(pic.pic)/\(n)", role: .virtualChassis, linkUp: vc.status == "Up",
                                        statusText: vc.status, speedLabel: "40G QSFP+", pic: pic.pic, port: n, networkName: et))
                } else {
                    let st = statuses.first { $0.name == et }
                    out.append(RearPort(name: et, role: .network, linkUp: st?.linkUp ?? false,
                                        statusText: st == nil ? "Absent" : (st!.linkUp ? "Up" : "Down"), speedLabel: "40G QSFP+",
                                        pic: pic.pic, port: n, networkName: et))
                }
            }
        }
        return out
    }

    /// Out-of-band management port (me0) on the rear panel.
    public var managementPort: (linkUp: Bool, addresses: [String])? {
        guard let st = statuses.first(where: { $0.name == "me0" }) else { return nil }
        return (st.linkUp, config.effective("me0").inetAddresses)
    }

    public func port(named name: String) -> SwitchPort? {
        ports.first { $0.name == name || $0.slotKey == Self.slotKey(name) }
    }

    public func ports(inVLAN vlan: String) -> [SwitchPort] { ports.filter { $0.vlans.contains(vlan) } }

    /// EX4300 rules, kept for tests: PIC 1 is the rear QSFP+ block.
    static func isFrontPanel(_ name: String) -> Bool { JunosModel("EX4300-48T").isFrontPanel(name) }

    /// "ge-0/2/1" and "xe-0/2/1" are the same physical cage.
    public static func slotKey(_ name: String) -> String {
        guard let dash = name.firstIndex(of: "-") else { return name }
        return String(name[name.index(after: dash)...])
    }

    static func transceiverWarning(_ x: HardwareInfo.Transceiver, interfaceName: String) -> String? {
        let d = x.description.uppercased()
        if (d.contains("25G") || d.contains("SFP28")) && interfaceName.hasPrefix("ge-") {
            return t("%@ is inserted, but the switch sees it as 1G. A 10G SFP+ compatible cable may be needed.", x.description)
        }
        return nil
    }
}

extension HardwareInfo.Transceiver {
    /// Short name from `show chassis hardware`: "SFP28-25G-BASE-CU-1M" → "25G DAC", with the brand when the
    /// part number names one (Juniper parts are 740-…; third-party optics read NON-JNPR). Nil when the
    /// description says nothing usable.
    public var shortName: String? {
        let d = description.uppercased()
        let speed = d.range(of: #"\d+G"#, options: .regularExpression).map { String(d[$0]) }
        let kind: String? = d.contains("AOC") ? "AOC" : (d.contains("-CU") || d.contains("DAC") ? "DAC" : nil)
        let brand: String? = partNumber.hasPrefix("740-") ? "Juniper" : nil
        guard speed != nil || kind != nil else { return nil }
        return [brand, speed, kind ?? "SFP"].compactMap { $0 }.joined(separator: " ")
    }
}

public struct RearPort: Equatable, Sendable, Identifiable {
    public enum Role: String, Sendable, Codable { case virtualChassis, network }
    public var name: String
    public var role: Role
    public var linkUp: Bool
    public var statusText: String
    public var speedLabel: String
    public var pic: Int = 1
    public var port: Int = 0
    /// The port's name when it works as a network port ("et-0/1/0").
    public var networkName: String = ""
    public var id: String { name }
}

public struct SwitchPort: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case copper, sfp }

    public var slotKey: String
    public var name: String
    public var kind: Kind = .copper
    public var number = 0
    public var adminUp = true
    public var linkUp = false
    /// false for an uplink cage with no transceiver (interface not instantiated).
    public var present = true
    public var description: String?
    public var configDisabled = false
    public var disabledByRange: String?
    public var mode: PortMode?
    public var vlans: [String] = []
    public var nativeVlanID: Int?
    public var rstpEdge = false
    public var macs: [MACEntry] = []
    public var lldp: [LLDPNeighbor] = []
    public var transceiver: HardwareInfo.Transceiver?
    public var warning: String?
    /// IP addresses on the port itself (a routed port), "dhcp" when it asks for one.
    public var addresses: [String] = []
    /// The port is a switch port (has a VLAN). False for routed ports and unconfigured ones.
    public var switching = false
    /// Firewall security zone (Juniper SRX), when the port is in one.
    public var zone: String?
    /// Link speed as printed ("1000Mbps", "10G"), when the platform reports it.
    public var speed: String?
    /// Physical label when it differs from `number` (Cisco "Gi1/0/1", MikroTik "ether1").
    public var label: String?
    /// Interface name the device itself uses for this port by default (MikroTik `default-name`).
    public var defaultName: String?

    /// A routed (layer 3) port: it has an address and no VLAN. VLAN edits don't apply to it.
    public var isRouted: Bool { !addresses.isEmpty && !switching }

    public var id: String { slotKey }

    public init(slotKey: String, name: String) {
        self.slotKey = slotKey
        self.name = name
    }

    public enum State: String, Sendable { case up, down, disabled, warning, empty }

    public var state: State {
        if warning != nil { return .warning }
        if !present { return .empty }
        if configDisabled || !adminUp { return .disabled }
        return linkUp ? .up : .down
    }
}
