import Foundation

/// RouterOS data the change planner needs beyond the neutral `JunosConfig`: the bridge that does the
/// switching, its ports and VLAN table (bridge VLAN filtering), the VLAN interfaces that name VLANs,
/// and the default names of the Ethernet ports (commands find ports by them, so renames don't matter).
public struct MikroTikState: Equatable, Sendable {
    /// `/interface bridge port` entry.
    public struct BridgePort: Equatable, Sendable {
        public var interface: String
        public var bridge: String
        public var pvid: Int
        public var frameTypes: String
        public var disabled: Bool
        public var dynamic: Bool

        public init(interface: String, bridge: String, pvid: Int = 1, frameTypes: String = "admit-all",
                    disabled: Bool = false, dynamic: Bool = false) {
            self.interface = interface
            self.bridge = bridge
            self.pvid = pvid
            self.frameTypes = frameTypes
            self.disabled = disabled
            self.dynamic = dynamic
        }
    }

    /// `/interface bridge vlan` entry.
    public struct BridgeVLAN: Equatable, Sendable {
        public var bridge: String
        /// `vlan-ids` exactly as printed ("10", "10,20", "100-110"); commands find the entry by it.
        public var vlanIDs: String
        public var ids: [Int]
        /// Configured member lists (what Netdeck edits).
        public var tagged: [String]
        public var untagged: [String]
        /// Effective member lists, including dynamic PVID membership.
        public var currentTagged: [String]
        public var currentUntagged: [String]
        public var comment: String?
        public var dynamic: Bool
        public var disabled: Bool

        public init(bridge: String, vlanIDs: String, ids: [Int], tagged: [String] = [], untagged: [String] = [],
                    currentTagged: [String] = [], currentUntagged: [String] = [], comment: String? = nil,
                    dynamic: Bool = false, disabled: Bool = false) {
            self.bridge = bridge
            self.vlanIDs = vlanIDs
            self.ids = ids
            self.tagged = tagged
            self.untagged = untagged
            self.currentTagged = currentTagged
            self.currentUntagged = currentUntagged
            self.comment = comment
            self.dynamic = dynamic
            self.disabled = disabled
        }
    }

    /// `/interface vlan` entry (a layer 3 VLAN interface).
    public struct VLANInterface: Equatable, Sendable {
        public var name: String
        public var vlanID: Int
        public var interface: String

        public init(name: String, vlanID: Int, interface: String) {
            self.name = name
            self.vlanID = vlanID
            self.interface = interface
        }
    }

    /// The bridge that switches the ports: the one with VLAN filtering, else the one with most ports.
    public var bridge: String?
    /// `vlan-filtering=yes` on that bridge. Without it VLANs are not enforced and Netdeck doesn't edit them.
    public var vlanFiltering: Bool
    public var bridgePorts: [BridgePort]
    public var bridgeVLANs: [BridgeVLAN]
    public var vlanInterfaces: [VLANInterface]
    /// Current name → `default-name` of every Ethernet interface.
    public var defaultNames: [String: String]
    /// Ethernet interface names in the router's order (keeps member lists tidy).
    public var portOrder: [String]
    /// Display name of every VLAN in use on the bridge: the VLAN interface's name, else "vlan<ID>"
    /// ("default" for VLAN 1).
    public var vlanNames: [Int: String]

    public init(bridge: String? = nil, vlanFiltering: Bool = false, bridgePorts: [BridgePort] = [],
                bridgeVLANs: [BridgeVLAN] = [], vlanInterfaces: [VLANInterface] = [],
                defaultNames: [String: String] = [:], portOrder: [String] = [], vlanNames: [Int: String] = [:]) {
        self.bridge = bridge
        self.vlanFiltering = vlanFiltering
        self.bridgePorts = bridgePorts
        self.bridgeVLANs = bridgeVLANs
        self.vlanInterfaces = vlanInterfaces
        self.defaultNames = defaultNames
        self.portOrder = portOrder
        self.vlanNames = vlanNames
    }
}

extension MikroTikState {
    static let onlyTagged = "admit-only-vlan-tagged"
    static let onlyUntagged = "admit-only-untagged-and-priority-tagged"
    static let admitAll = "admit-all"

    /// The interface's enabled port entry in the switching bridge.
    func bridgePort(of name: String) -> BridgePort? {
        guard let bridge else { return nil }
        return bridgePorts.first { $0.interface == name && $0.bridge == bridge && !$0.disabled }
    }

    /// A static, enabled VLAN entry of the switching bridge (the ones Netdeck may edit).
    func isStaticEntry(_ i: Int) -> Bool {
        let v = bridgeVLANs[i]
        return v.bridge == bridge && !v.dynamic && !v.disabled
    }

    func staticEntryIndex(containing id: Int) -> Int? {
        bridgeVLANs.indices.first { isStaticEntry($0) && bridgeVLANs[$0].ids.contains(id) }
    }

    func vlanName(_ id: Int) -> String { vlanNames[id] ?? (id == 1 ? "default" : "vlan\(id)") }

    func vlanID(named name: String) -> Int? {
        vlanNames.filter { $0.value == name }.keys.min()
    }

    /// Comment of the first static entry that carries the VLAN.
    func vlanComment(_ id: Int) -> String? {
        bridgeVLANs.first { $0.bridge == bridge && !$0.dynamic && $0.ids.contains(id) && $0.comment?.isEmpty == false }?.comment
    }

    /// Members in a stable order: other interfaces (the bridge, bonds) first, then ports in router order.
    func sortedMembers(_ names: [String]) -> [String] {
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0).inserted }
        return unique.sorted { a, b in
            let ia = portOrder.firstIndex(of: a) ?? -1, ib = portOrder.firstIndex(of: b) ?? -1
            return ia != ib ? ia < ib : a < b
        }
    }

    mutating func setBridgePort(_ name: String, pvid: Int, frameTypes: String) {
        guard let i = bridgePorts.firstIndex(where: { $0.interface == name && $0.bridge == bridge && !$0.disabled }) else { return }
        bridgePorts[i].pvid = pvid
        bridgePorts[i].frameTypes = frameTypes
    }

    /// VLAN IDs a port is a tagged or untagged member of, from the configured and effective lists and
    /// its PVID (untagged frames go to the PVID unless the port only admits tagged ones).
    func membership(of name: String) -> (tagged: Set<Int>, untagged: Set<Int>) {
        var tagged = Set<Int>(), untagged = Set<Int>()
        for v in bridgeVLANs where v.bridge == bridge && !v.disabled {
            if v.tagged.contains(name) || v.currentTagged.contains(name) { tagged.formUnion(v.ids) }
            if v.untagged.contains(name) || v.currentUntagged.contains(name) { untagged.formUnion(v.ids) }
        }
        if let bp = bridgePort(of: name), bp.frameTypes != Self.onlyTagged { untagged.insert(bp.pvid) }
        return (tagged, untagged)
    }

    /// Mode, VLAN names and untagged VLAN of a port in the switching bridge; nil when it isn't in it.
    /// Without VLAN filtering the bridge is one flat network, shown as VLAN "default".
    func portVLANs(_ name: String) -> (mode: PortMode, vlans: [String], native: Int?)? {
        guard let bp = bridgePort(of: name) else { return nil }
        guard vlanFiltering else { return (.access, [vlanName(1)], nil) }
        let m = membership(of: name)
        let all = m.tagged.union(m.untagged).sorted()
        if m.tagged.isEmpty && m.untagged.count <= 1 { return (.access, all.map(vlanName), nil) }
        let native = m.untagged.contains(bp.pvid) && bp.frameTypes != Self.onlyTagged ? bp.pvid : nil
        return (.trunk, all.map(vlanName), native)
    }

    /// Ethernet ports that carry the VLAN by configuration (PVID or a configured member list).
    func ports(using id: Int) -> [String] {
        portOrder.filter { name in
            if let bp = bridgePort(of: name), bp.pvid == id, bp.frameTypes != Self.onlyTagged { return true }
            return bridgeVLANs.indices.contains { i in
                isStaticEntry(i) && bridgeVLANs[i].ids.contains(id)
                    && (bridgeVLANs[i].tagged.contains(name) || bridgeVLANs[i].untagged.contains(name))
            }
        }
    }

    /// Names for VLAN IDs: the VLAN interface on the bridge, else "default" for 1 and "vlan<ID>".
    static func names(for ids: Set<Int>, interfaces: [VLANInterface], bridge: String?) -> [Int: String] {
        var names: [Int: String] = [:]
        var used = Set<String>()
        for id in ids.sorted() {
            var name = interfaces.first(where: { $0.vlanID == id && $0.interface == bridge })?.name ?? (id == 1 ? "default" : "vlan\(id)")
            if used.contains(name) { name = "vlan\(id)" }
            var n = 2
            while used.contains(name) { name = "vlan\(id)-\(n)"; n += 1 }
            used.insert(name)
            names[id] = name
        }
        return names
    }
}

// MARK: - Snapshot

/// Raw outputs of the read commands, one per command.
struct MikroTikOutputs: Sendable {
    var identity = ""
    var resource = ""
    var routerboard = ""
    var ethernet = ""
    var interfaces = ""
    var bridges = ""
    var bridgePorts = ""
    var bridgeVLANs = ""
    var vlanInterfaces = ""
    var hosts = ""
    var neighbors = ""
    var addresses = ""
    var export = ""
}

/// Builds the neutral snapshot from RouterOS outputs (pure, for tests).
enum MikroTikSnapshotBuilder {
    static func state(_ o: MikroTikOutputs) -> MikroTikState {
        let bridges = MikroTikParsers.terse(o.bridges).filter { !$0.isDisabled && $0["name"] != nil }
        let ports: [MikroTikState.BridgePort] = MikroTikParsers.terse(o.bridgePorts).compactMap { r -> MikroTikState.BridgePort? in
            guard let i = r["interface"], let b = r["bridge"] else { return nil }
            let frames = r["frame-types"].flatMap { $0.isEmpty ? nil : $0 } ?? MikroTikState.admitAll
            return .init(interface: i, bridge: b, pvid: r["pvid"].flatMap { Int($0) } ?? 1, frameTypes: frames,
                         disabled: r.isDisabled, dynamic: r.has("D"))
        }
        let vlans: [MikroTikState.BridgeVLAN] = MikroTikParsers.terse(o.bridgeVLANs).compactMap { r -> MikroTikState.BridgeVLAN? in
            guard let b = r["bridge"], let raw = r["vlan-ids"] else { return nil }
            return .init(bridge: b, vlanIDs: raw, ids: MikroTikParsers.vlanIDs(raw), tagged: r.list("tagged"),
                         untagged: r.list("untagged"), currentTagged: r.list("current-tagged"),
                         currentUntagged: r.list("current-untagged"), comment: r["comment"].flatMap { $0.isEmpty ? nil : $0 },
                         dynamic: r.has("D"), disabled: r.isDisabled)
        }
        let vlanInterfaces: [MikroTikState.VLANInterface] = MikroTikParsers.terse(o.vlanInterfaces).compactMap { r -> MikroTikState.VLANInterface? in
            guard !r.isDisabled, let n = r["name"], let id = r["vlan-id"].flatMap({ Int($0) }), let i = r["interface"] else { return nil }
            return .init(name: n, vlanID: id, interface: i)
        }
        let ethernet = MikroTikParsers.terse(o.ethernet).filter { $0["name"] != nil }

        // The switching bridge: VLAN filtering on, else the one with most ports (first on a tie).
        var main = bridges.first(where: { $0.bool("vlan-filtering") == true })?["name"]
        if main == nil {
            var best = -1
            for b in bridges {
                guard let name = b["name"] else { continue }
                let count = ports.filter { $0.bridge == name && !$0.disabled }.count
                if count > best { best = count; main = name }
            }
        }
        let filtering = bridges.first(where: { $0["name"] == main })?.bool("vlan-filtering") == true

        var ids = Set<Int>()
        if let main {
            if filtering {
                for v in vlans where v.bridge == main && !v.disabled { ids.formUnion(v.ids) }
                for p in ports where p.bridge == main && !p.disabled { ids.insert(p.pvid) }
            } else if ports.contains(where: { $0.bridge == main && !$0.disabled }) {
                ids.insert(1)
            }
        }

        var defaultNames: [String: String] = [:]
        for r in ethernet {
            if let n = r["name"] { defaultNames[n] = r["default-name"].flatMap { $0.isEmpty ? nil : $0 } ?? n }
        }
        return MikroTikState(bridge: main, vlanFiltering: filtering, bridgePorts: ports, bridgeVLANs: vlans,
                             vlanInterfaces: vlanInterfaces, defaultNames: defaultNames,
                             portOrder: ethernet.compactMap { $0["name"] },
                             vlanNames: MikroTikState.names(for: ids, interfaces: vlanInterfaces, bridge: main))
    }

    static func build(_ o: MikroTikOutputs, takenAt: Date = .now) -> SwitchSnapshot {
        let identity = MikroTikParsers.keyValues(o.identity)["name"].flatMap { $0.isEmpty ? nil : $0 }
        let resource = MikroTikParsers.keyValues(o.resource)
        let board = MikroTikParsers.keyValues(o.routerboard)
        let state = Self.state(o)
        let ethernet = MikroTikParsers.terse(o.ethernet).filter { $0["name"] != nil }
        let interfaces = MikroTikParsers.terse(o.interfaces)

        let statuses: [InterfaceStatus] = interfaces.compactMap { r in
            r["name"].map { InterfaceStatus(name: $0, adminUp: !r.isDisabled, linkUp: r.has("R")) }
        }
        // Local entries are the router's own addresses.
        let macTable: [MACEntry] = MikroTikParsers.terse(o.hosts).compactMap { r -> MACEntry? in
            guard !r.has("L"), !r.isDisabled, let mac = r["mac-address"],
                  let on = r["on-interface"] ?? r["interface"] else { return nil }
            let vlan = r["vid"].flatMap { Int($0) }.map { state.vlanName($0) } ?? ""
            return MACEntry(vlan: vlan, mac: mac.lowercased(), flags: r.flags, interface: on)
        }
        // `/ip neighbor` covers LLDP, CDP and MNDP; neighbors on a bridge port may print as "ether5,bridge".
        let lldp: [LLDPNeighbor] = MikroTikParsers.terse(o.neighbors).compactMap { r -> LLDPNeighbor? in
            guard let local = r["interface"]?.split(separator: ",").first.map(String.init) else { return nil }
            return LLDPNeighbor(localInterface: local, chassisID: (r["mac-address"] ?? "").lowercased(),
                                portInfo: r["interface-name"] ?? "", systemName: r["identity"] ?? "")
        }
        var addresses: [String: [String]] = [:]
        for r in MikroTikParsers.terse(o.addresses) where !r.isDisabled {
            if let i = r["interface"], let a = r["address"] { addresses[i, default: []].append(a) }
        }

        var config = JunosConfig()
        config.hostname = identity
        var ports: [SwitchPort] = []
        for r in ethernet {
            guard let name = r["name"] else { continue }
            let def = state.defaultNames[name] ?? name
            var p = SwitchPort(slotKey: def, name: name)
            p.defaultName = r["default-name"].flatMap { $0.isEmpty ? nil : $0 }
            p.kind = portKind(defaultName: def, comboMode: r["combo-mode"])
            let numbering = numberAndLabel(def)
            p.number = numbering.number
            p.label = numbering.label
            let disabled = r.isDisabled
            p.configDisabled = disabled
            p.adminUp = !disabled
            p.linkUp = r.has("R") || (statuses.first(where: { $0.name == name })?.linkUp ?? false)
            p.present = true
            let comment = r["comment"] ?? interfaces.first(where: { $0["name"] == name })?["comment"]
            p.description = comment.flatMap { $0.isEmpty ? nil : $0 }
            if p.linkUp, let speed = r["speed"], !speed.isEmpty { p.speed = speed }
            p.addresses = addresses[name] ?? []
            p.macs = macTable.filter { $0.interface == name }
            p.lldp = lldp.filter { $0.localInterface == name }

            var ic = JunosConfig.InterfaceConfig()
            ic.description = p.description
            ic.disabled = disabled
            ic.inetAddresses = p.addresses
            if let v = state.portVLANs(name) {
                p.switching = true
                p.mode = v.mode
                p.vlans = v.vlans
                p.nativeVlanID = v.native
                ic.hasEthernetSwitching = true
                ic.mode = v.mode
                ic.vlanMembers = v.vlans
                ic.nativeVlanID = v.native
            }
            config.interfaces[name] = ic
            ports.append(p)
        }
        // Display order: built-in copper first, then the cages, each in the router's order.
        ports = ports.filter { $0.kind == .copper } + ports.filter { $0.kind == .sfp }

        config.vlans = state.vlanNames.keys.sorted().map { id in
            JunosConfig.VLAN(name: state.vlanName(id), vlanID: id, description: state.vlanComment(id),
                             l3Interface: state.vlanInterfaces.first(where: { $0.vlanID == id && $0.interface == state.bridge })?.name)
        }

        let boardName = resource["board-name"].flatMap { $0.isEmpty ? nil : $0 }
        let model = (board["routerboard"] == "yes" ? board["model"] : nil) ?? boardName ?? board["model"]
        let upper = [boardName, model].compactMap { $0?.uppercased() }
        let isSwitch = upper.contains { $0.hasPrefix("CRS") || $0.hasPrefix("CSS") } || state.vlanFiltering
        let version = resource["version"]?.split(separator: " ").first.map(String.init)

        return SwitchSnapshot(
            takenAt: takenAt,
            version: VersionInfo(hostname: identity, model: boardName ?? model, junos: version),
            hardware: HardwareInfo(model: model, serial: board["serial-number"].flatMap { $0.isEmpty ? nil : $0 }),
            config: config,
            configText: MikroTikParsers.stableExport(o.export),
            statuses: statuses,
            macTable: macTable,
            lldp: lldp,
            commits: [],
            platform: .mikrotikRouterOS,
            explicitPorts: ports,
            vendor: .mikrotik(state),
            readKind: isSwitch ? .switchDevice : .router
        )
    }

    /// ether* copper; sfp*, sfp-sfpplus*, sfp28-*, qsfp* cages; combo* copper unless set to SFP.
    static func portKind(defaultName: String, comboMode: String?) -> SwitchPort.Kind {
        let n = defaultName.lowercased()
        if n.hasPrefix("combo") { return comboMode == "sfp" ? .sfp : .copper }
        if n.hasPrefix("sfp") || n.hasPrefix("qsfp") { return .sfp }
        return .copper
    }

    /// Panel number from the default name ("ether12" → 12, "sfp-sfpplus2" → 2). QSFP breakout lanes
    /// ("qsfp28-1-2") get the cage number and a "1-2" label.
    static func numberAndLabel(_ defaultName: String) -> (number: Int, label: String?) {
        let parts = defaultName.split(separator: "-")
        if defaultName.lowercased().hasPrefix("qsfp"), parts.count >= 3,
           let cage = Int(parts[parts.count - 2]), let lane = Int(parts[parts.count - 1]) {
            return (cage, "\(cage)-\(lane)")
        }
        return (MikroTikParsers.trailingNumber(defaultName) ?? 0, nil)
    }
}
