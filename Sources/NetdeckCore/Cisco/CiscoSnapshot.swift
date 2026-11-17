import Foundation

/// Builds a `SwitchSnapshot` from the raw `show` outputs of a Cisco IOS / IOS-XE device. Pure, so the
/// whole read path is testable without a device.
enum CiscoSnapshotBuilder {
    /// Command outputs without echo and prompt. Missing or rejected commands leave "" or the error text.
    struct Outputs: Sendable {
        var version = ""
        var inventory = ""
        var runningConfig = ""
        var interfacesStatus = ""
        var vlanBrief = ""
        var macTable = ""
        var lldp = ""
        /// `show cdp neighbors`, read when LLDP found nobody (Cisco networks often run only CDP).
        var cdp = ""
        var archive = ""
    }

    static func build(_ o: Outputs, takenAt: Date = .now) -> SwitchSnapshot {
        let ver = CiscoParsers.version(o.version)
        let inventory = CiscoParsers.inventory(o.inventory)
        let rc = CiscoParsers.runningConfig(o.runningConfig)
        let statusRows = CiscoParsers.interfacesStatus(o.interfacesStatus)
        let vlanRows = CiscoParsers.vlanBrief(o.vlanBrief)

        let known = Set(rc.interfaces.map(\.name))
        func full(_ name: String) -> String { CiscoNames.resolve(name, known: known) }
        var configs: [String: CiscoInterfaceConfig] = [:]
        for c in rc.interfaces { configs[c.name] = c }
        var statusByName: [String: CiscoPortStatus] = [:]
        for s in statusRows { statusByName[full(s.port)] = s }

        // Routers (ISR) answer neither `show interfaces status` nor `show vlan brief`.
        let isSwitch = !statusRows.isEmpty || !vlanRows.isEmpty
            || rc.interfaces.contains { $0.mode != nil || $0.accessVLAN != nil || $0.allowedVLANs != nil }

        // VLANs: `show vlan brief` is complete (in VTP server/client mode VLANs are not in the running config).
        var vlanList: [(id: Int, name: String)] = vlanRows.map { (id: $0.id, name: $0.name) }
        if vlanList.isEmpty {
            vlanList = rc.vlans.filter { !(1002...1005).contains($0.key) }
                .map { (id: $0.key, name: $0.value.isEmpty ? String(format: "VLAN%04d", $0.key) : $0.value) }
            if isSwitch, !vlanList.contains(where: { $0.id == 1 }) { vlanList.append((id: 1, name: "default")) }
        }
        vlanList.sort { $0.id < $1.id }
        // Netdeck identifies VLANs by name; keep names unique.
        var vlanNames: [Int: String] = [:]
        var usedNames = Set<String>()
        for v in vlanList {
            let name = usedNames.contains(v.name) ? "\(v.name) (\(v.id))" : v.name
            usedNames.insert(name)
            vlanNames[v.id] = name
        }
        let allVLANIDs = vlanList.map(\.id)

        func members(_ mode: PortMode, accessVLAN: Int, allowed: [Int]?) -> [String] {
            switch mode {
            case .access: return [vlanNames[accessVLAN] ?? String(format: "VLAN%04d", accessVLAN)]
            case .trunk: return (allowed ?? allVLANIDs).compactMap { vlanNames[$0] }
            }
        }
        func isRouted(_ name: String) -> Bool {
            !isSwitch || (configs[name]?.noSwitchport ?? false) || statusByName[name]?.vlan == "routed"
        }
        func effectiveMode(_ name: String) -> PortMode {
            configs[name]?.mode ?? (statusByName[name]?.vlan == "trunk" ? .trunk : .access)
        }

        // Neutral config model.
        var config = JunosConfig()
        config.hostname = rc.hostname ?? ver.hostname
        config.vlans = vlanList.compactMap { v in vlanNames[v.id].map { JunosConfig.VLAN(name: $0, vlanID: v.id) } }
        for c in rc.interfaces {
            var ic = JunosConfig.InterfaceConfig()
            ic.description = c.description
            ic.disabled = c.shutdown
            ic.mode = c.mode
            ic.nativeVlanID = c.nativeVLAN
            ic.inetAddresses = c.addresses
            if CiscoNames.isPhysical(c.name) && !isRouted(c.name) {
                ic.hasEthernetSwitching = true
                ic.vlanMembers = members(effectiveMode(c.name), accessVLAN: c.accessVLAN ?? 1, allowed: c.allowedVLANs)
            }
            config.interfaces[c.name] = ic
        }

        // Front-panel ports.
        let candidates = statusRows.isEmpty ? rc.interfaces.map(\.name) : statusRows.map { full($0.port) }
        var seen = Set<String>()
        let physical = candidates.filter { CiscoNames.isPhysical($0) && seen.insert($0).inserted }
        let stackStyle = physical.contains { CiscoNames.path($0).count >= 3 }
        let front = physical.filter { name in
            // Management port: in the management VRF (Catalyst 9000 Gi0/0 is in Mgmt-vrf, ISR 4000 Gi0 in Mgmt-intf).
            if let vrf = configs[name]?.vrf, vrf.lowercased().hasPrefix("mgmt") { return false }
            if stackStyle && name == "GigabitEthernet0/0" { return false }
            return true
        }
        let shown = dropAbsentModuleVariants(front, status: statusByName, inventory: inventory)

        let macs: [MACEntry] = CiscoParsers.macTable(o.macTable).map { m in
            MACEntry(vlan: Int(m.vlan).flatMap { vlanNames[$0] } ?? m.vlan, mac: m.mac, flags: m.type, interface: full(m.port))
        }
        var lldp: [LLDPNeighbor] = CiscoParsers.lldpNeighbors(o.lldp).map { neighbor in
            var n = neighbor
            n.localInterface = full(n.localInterface)
            return n
        }
        // CDP fills in the ports LLDP said nothing about.
        let lldpPorts = Set(lldp.map(\.localInterface))
        for neighbor in CiscoParsers.cdpNeighbors(o.cdp) {
            var n = neighbor
            n.localInterface = full(n.localInterface)
            if !lldpPorts.contains(n.localInterface) { lldp.append(n) }
        }
        var transceivers: [String: HardwareInfo.Transceiver] = [:]
        for item in inventory {
            let name = full(item.name)
            guard CiscoNames.isPhysical(name) else { continue }
            let path = CiscoNames.path(name)
            transceivers[name] = HardwareInfo.Transceiver(
                fpc: CiscoNames.member(name), pic: CiscoNames.module(name), port: path.last ?? 0,
                partNumber: item.pid, serial: item.serial, description: item.descr)
        }

        var portConfigs: [String: CiscoPortConfig] = [:]
        var ports: [SwitchPort] = []
        for name in shown {
            let st = statusByName[name]
            let c = configs[name]
            let routed = isRouted(name)
            let pc = CiscoPortConfig(switchport: !routed, mode: c?.mode, accessVLAN: c?.accessVLAN ?? 1,
                                     allowedVLANs: c?.allowedVLANs, nativeVLAN: c?.nativeVLAN,
                                     hasEncapsulation: c?.hasEncapsulation ?? false, channelGroup: c?.channelGroup)
            portConfigs[name] = pc

            var p = SwitchPort(slotKey: name, name: name)
            p.kind = isCage(type: st?.type, modulePort: CiscoNames.isModulePort(name), isSwitch: isSwitch) ? .sfp : .copper
            p.number = CiscoNames.path(name).last ?? 0
            p.label = String(p.number)
            p.present = st.map { $0.type.lowercased() != "not present" } ?? true
            p.configDisabled = c?.shutdown ?? false
            p.adminUp = st?.adminUp ?? !p.configDisabled
            p.linkUp = st?.linkUp ?? false
            p.description = c?.description ?? st.flatMap { $0.name.isEmpty ? nil : $0.name }
            if st?.status == "err-disabled" { p.warning = t("The switch shut this port down after an error (err-disabled).") }
            p.switching = !routed
            if !routed {
                let mode = effectiveMode(name)
                p.mode = mode
                p.vlans = members(mode, accessVLAN: pc.accessVLAN, allowed: pc.allowedVLANs)
                p.nativeVlanID = pc.nativeVLAN
            }
            p.addresses = c?.addresses ?? []
            p.macs = macs.filter { $0.interface == name }
            p.lldp = lldp.filter { $0.localInterface == name }
            p.transceiver = transceivers[name]
            if p.linkUp, let s = st?.speed { p.speed = speedLabel(s) }
            ports.append(p)
        }
        // Stack member 1 first; per member the built-in copper ports, then the cages.
        func order(_ p: SwitchPort) -> [Int] {
            [CiscoNames.member(p.name), p.kind == .copper ? 0 : 1, CiscoNames.module(p.name), p.number]
        }
        ports.sort { order($0).lexicographicallyPrecedes(order($1)) }

        var hardware = HardwareInfo()
        let chassis = inventory.first { $0.name == "Switch 1" || $0.name == "Chassis" } ?? inventory.first { !$0.pid.isEmpty }
        hardware.model = ver.model ?? chassis?.pid
        hardware.serial = ver.serial ?? chassis.flatMap { $0.serial.isEmpty ? nil : $0.serial }
        hardware.transceivers = Array(transceivers.values).sorted {
            [$0.fpc, $0.pic, $0.port].lexicographicallyPrecedes([$1.fpc, $1.pic, $1.port])
        }

        let state = CiscoState(ports: portConfigs,
                               archiveConfigured: CiscoParsers.archiveConfigured(o.archive),
                               needsTrunkEncapsulation: rc.usesTrunkEncapsulation)
        return SwitchSnapshot(
            takenAt: takenAt,
            version: VersionInfo(hostname: rc.hostname ?? ver.hostname, model: hardware.model, junos: ver.osVersion),
            hardware: hardware,
            config: config,
            configText: CiscoParsers.configText(o.runningConfig),
            statuses: statusRows.map { InterfaceStatus(name: full($0.port), adminUp: $0.adminUp, linkUp: $0.linkUp) },
            macTable: macs,
            lldp: lldp,
            commits: [],
            platform: .ciscoIOS,
            explicitPorts: ports,
            vendor: .cisco(state),
            readKind: isSwitch ? .switchDevice : .router
        )
    }

    /// A Catalyst 9300 lists every interface name its network-module slot could have (Gi1/1/1-4,
    /// Te1/1/1-8, Twe1/1/1-2, Fo1/1/1-2), whatever module is installed. Keep the media type that is
    /// really there: the one with a known Type or a link, else the one the inventory's uplink module
    /// describes ("8x10G Uplink Module"). With neither, the slot is empty and none is shown.
    static func dropAbsentModuleVariants(_ names: [String], status: [String: CiscoPortStatus],
                                         inventory: [CiscoInventoryItem]) -> [String] {
        var groups: [String: [String]] = [:]
        for n in names where CiscoNames.isModulePort(n) {
            groups["\(CiscoNames.member(n))/\(CiscoNames.module(n))", default: []].append(n)
        }
        var drop = Set<String>()
        for (_, members) in groups {
            let media = Set(members.map { CiscoNames.split($0).prefix })
            guard media.count > 1 else { continue }
            func isReal(_ n: String) -> Bool {
                guard let s = status[n] else { return false }
                let type = s.type.lowercased()
                return s.linkUp || (!type.isEmpty && type != "unknown")
            }
            var keep = Set(members.filter(isReal).map { CiscoNames.split($0).prefix })
            if keep.isEmpty, let first = members.first, let prefix = uplinkMedia(member: CiscoNames.member(first), inventory: inventory) {
                keep = [prefix]
            }
            for n in members where !keep.contains(CiscoNames.split(n).prefix) { drop.insert(n) }
        }
        return names.filter { !drop.contains($0) }
    }

    /// Interface prefix of the installed uplink module of a stack member, from its description
    /// ("8x10G Uplink Module" → TenGigabitEthernet).
    static func uplinkMedia(member: Int, inventory: [CiscoInventoryItem]) -> String? {
        let modules = inventory.filter { $0.name.lowercased().contains("uplink module") || $0.descr.lowercased().contains("uplink module") }
        guard let item = modules.first(where: { $0.name.contains("Switch \(member) ") }) ?? (member == 1 ? modules.first : nil),
              let c = CiscoParsers.capture(#"(\d+)\s*x\s*(\d+)G"#, in: item.descr, options: .caseInsensitive),
              let speed = Int(c[1]) else { return nil }
        switch speed {
        case 1: return "GigabitEthernet"
        case 10: return "TenGigabitEthernet"
        case 25: return "TwentyFiveGigE"
        case 40: return "FortyGigabitEthernet"
        case 100: return "HundredGigE"
        default: return nil
        }
    }

    /// A pluggable cage (SFP, SFP+, QSFP...) rather than a built-in copper port.
    static func isCage(type: String?, modulePort: Bool, isSwitch: Bool) -> Bool {
        let t = (type ?? "").uppercased()
        let markers = ["SFP", "GBIC", "X2", "XENPAK", "NOT PRESENT", "UNKNOWN", "BASE-SR", "BASE-LR", "BASE-ER", "BASE-ZR",
                       "BASESX", "BASELX", "BASEZX", "BASE-SX", "BASE-LX", "BASEBX", "BASE-BX", "BASE-CU", "CX1", "AOC"]
        if markers.contains(where: { t.contains($0) }) { return true }
        if t.contains("BASET") { return false }
        // Network-module ports of a switch are cages unless the Type says copper.
        return isSwitch && modulePort
    }

    /// "a-1000" → "1000Mbps", "10G" → "10G", "auto" → nil.
    static func speedLabel(_ s: String) -> String? {
        var v = s
        if v.hasPrefix("a-") { v.removeFirst(2) }
        if v.isEmpty || v == "auto" { return nil }
        return Int(v) != nil ? v + "Mbps" : v
    }
}
