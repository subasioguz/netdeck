import Foundation

/// Builds Netdeck's neutral snapshot from EdgeOS command outputs. Pure, so it is unit-tested with captures.
public enum EdgeOSSnapshot {
    public static func build(version versionText: String, config configText: String, interfaces interfacesText: String,
                             arp arpText: String, lldp lldpText: String, commits commitsText: String,
                             takenAt: Date = .now) -> SwitchSnapshot {
        let version = EdgeOSParsers.version(versionText)
        let cfg = EdgeOSParsers.config(configText)
        let rows = EdgeOSParsers.interfaces(interfacesText)
        let state = EdgeOSState(
            hasSwitch0: cfg.hasSwitch0, vlanAware: cfg.vlanAware, members: cfg.members,
            vifs: cfg.switchVifs.keys.sorted().map { id in
                let v = cfg.switchVifs[id]
                return EdgeOSState.Vif(id: id, description: v?.description, addresses: v?.addresses ?? [])
            },
            model: version.model
        )
        let vlans = vlanList(cfg, state: state)
        let names = Dictionary(vlans.compactMap { v in v.vlanID.map { ($0, v.name) } }, uniquingKeysWith: { a, _ in a })
        let vlanName = { (id: Int) -> String in names[id] ?? (id == EdgeOSState.defaultVLAN ? "default" : "vlan\(id)") }

        var portNames = Set(cfg.ethernet.keys.filter { EdgeOSParsers.ethNumber($0) != nil })
        for r in rows where EdgeOSParsers.ethNumber(r.name) != nil { portNames.insert(r.name) }
        for m in cfg.members.keys where EdgeOSParsers.ethNumber(m) != nil { portNames.insert(m) }

        // Without a switch the router has no MAC table worth showing (and Netdeck would treat it as a switch).
        let macs = state.hasSwitch0 && !state.members.isEmpty
            ? macTable(EdgeOSParsers.arp(arpText), state: state, ports: portNames, vlanName: vlanName) : []
        let lldp = EdgeOSParsers.lldpNeighbors(lldpText)

        var neutral = JunosConfig()
        neutral.hostname = cfg.hostname
        neutral.vlans = vlans
        neutral.lines = cfg.lines

        var ports: [SwitchPort] = []
        for name in portNames {
            let n = EdgeOSParsers.ethNumber(name) ?? 0
            let eth = cfg.ethernet[name]
            let row = rows.first { $0.name == name }
            var p = SwitchPort(slotKey: name, name: name)
            p.kind = EdgeOSModel.kind(model: version.model, number: n)
            p.number = n
            p.label = String(n)
            p.description = eth?.description
            p.configDisabled = eth?.disabled ?? false
            p.adminUp = row?.adminUp ?? !p.configDisabled
            p.linkUp = row?.linkUp ?? false
            p.addresses = eth.map { routedAddresses(port: name, $0) } ?? []
            if let m = state.members[name] {
                p.switching = true
                if state.vlanAware {
                    p.mode = m.vids.isEmpty ? .access : .trunk
                    p.vlans = m.vlanIDs.map(vlanName)
                    p.nativeVlanID = m.vids.isEmpty ? nil : m.untaggedVLAN
                } else {
                    // A plain switch0 bridges all its ports in one network.
                    p.mode = .access
                    p.vlans = ["default"]
                }
            }
            p.macs = macs.filter { $0.interface == name }
            p.lldp = lldp.filter { $0.localInterface == name }
            ports.append(p)

            var c = JunosConfig.InterfaceConfig()
            c.description = p.description
            c.disabled = p.configDisabled
            c.mode = p.mode
            c.vlanMembers = p.vlans
            c.nativeVlanID = p.nativeVlanID
            c.inetAddresses = p.addresses
            c.hasEthernetSwitching = p.switching
            neutral.interfaces[name] = c
        }
        // Copper first, then cages; by port number within each.
        ports.sort { ($0.kind == .copper ? 0 : 1, $0.number) < ($1.kind == .copper ? 0 : 1, $1.number) }

        return SwitchSnapshot(
            takenAt: takenAt,
            version: VersionInfo(hostname: cfg.hostname, model: version.model, junos: version.version),
            hardware: HardwareInfo(model: version.model, serial: version.serial),
            config: neutral,
            configText: configText,
            statuses: rows.filter { !$0.name.contains(".") }.map { InterfaceStatus(name: $0.name, adminUp: $0.adminUp, linkUp: $0.linkUp) },
            macTable: macs,
            lldp: lldp,
            commits: EdgeOSParsers.commitHistory(commitsText),
            platform: .ubiquitiEdgeOS,
            explicitPorts: ports,
            vendor: .edgeos(state),
            readKind: .router
        )
    }

    /// VLANs Netdeck shows: every switch0 vif plus, with vlan-aware switching, every VLAN a port uses.
    /// Named after the vif description; "vlanN" without one or when the description is taken. VLAN 1 is
    /// "default" and only listed when it has a vif (the app adds the built-in "default" itself).
    static func vlanList(_ cfg: EdgeOSParsers.Config, state: EdgeOSState) -> [JunosConfig.VLAN] {
        var ids = Set(cfg.switchVifs.keys)
        if state.vlanAware { for m in cfg.members.values { ids.formUnion(m.vlanIDs) } }
        if cfg.switchVifs[EdgeOSState.defaultVLAN] == nil { ids.remove(EdgeOSState.defaultVLAN) }
        let sorted = ids.sorted()

        var used: Set<String> = ["default"]
        var names: [Int: String] = [EdgeOSState.defaultVLAN: "default"]
        func unique(_ base: String) -> String {
            var name = base, k = 2
            while used.contains(name) { name = "\(base)-\(k)"; k += 1 }
            used.insert(name)
            return name
        }
        func vifDescription(_ id: Int) -> String {
            cfg.switchVifs[id]?.description?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        // Generic names first, so a description can't take another VLAN's "vlanN".
        for id in sorted where id != EdgeOSState.defaultVLAN && vifDescription(id).isEmpty { names[id] = unique("vlan\(id)") }
        for id in sorted where id != EdgeOSState.defaultVLAN && names[id] == nil {
            let d = vifDescription(id)
            names[id] = used.contains(d) ? unique("vlan\(id)") : unique(d)
        }
        return sorted.map { id in
            JunosConfig.VLAN(name: names[id] ?? "vlan\(id)", vlanID: id,
                             l3Interface: cfg.switchVifs[id] == nil ? nil : "switch0.\(id)")
        }
    }

    /// Addresses of a routed port, with those of its vifs ("dhcp (eth0.7)") and PPPoE sessions ("pppoe0").
    static func routedAddresses(port: String, _ e: EdgeOSParsers.Config.Ethernet) -> [String] {
        var out = e.addresses + e.pppoe.map { "pppoe\($0)" }
        for id in e.vifs.keys.sorted() {
            guard let v = e.vifs[id] else { continue }
            out += v.addresses.map { "\($0) (\(port).\(id))" }
            out += v.pppoe.map { "pppoe\($0) (\(port).\(id))" }
        }
        return out
    }

    /// ARP entries as the MAC table. Entries on switch0 (or a switch0 vif) only land on a port when exactly
    /// one switch port carries that VLAN; the router can't tell which member port the others are behind.
    static func macTable(_ arp: [EdgeOSParsers.ARPEntry], state: EdgeOSState, ports: Set<String>,
                         vlanName: (Int) -> String) -> [MACEntry] {
        var out: [MACEntry] = []
        for e in arp {
            let iface = e.interface
            var entry: MACEntry?
            if ports.contains(iface) {
                entry = MACEntry(vlan: "—", mac: e.mac, flags: e.flags, interface: iface)
            } else if iface == "switch0" || iface.hasPrefix("switch0.") {
                let id: Int? = iface == "switch0" ? EdgeOSState.defaultVLAN : Int(iface.dropFirst("switch0.".count))
                if let id {
                    let carriers = state.ports(carrying: id)
                    if carriers.count == 1 {
                        entry = MACEntry(vlan: vlanName(id), mac: e.mac, flags: e.flags, interface: carriers[0])
                    }
                }
            } else if let dot = iface.firstIndex(of: "."), ports.contains(String(iface[..<dot])) {
                // A routed vif such as eth0.7.
                entry = MACEntry(vlan: "—", mac: e.mac, flags: e.flags, interface: String(iface[..<dot]))
            }
            if let entry, !out.contains(entry) { out.append(entry) }
        }
        return out
    }
}
