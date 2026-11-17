import Foundation

/// Turns staged edits into EdgeOS configuration-mode `set`/`delete` commands. Pure: never talks to the device.
///
/// VLANs live on `switch0` with vlan-aware switching: a port's untagged VLAN is
/// `switch-port interface ethN vlan pvid N` (VLAN 1 without one) and its tagged VLANs are `vlan vid N`.
/// Netdeck's VLAN names are the switch0 vif descriptions ("vlanN" without one, "default" for VLAN 1);
/// the planner maps them back to numbers.
public enum EdgeOSPlanner {
    static let switch0 = "interfaces switch switch0"

    public static func plan(snapshot: SwitchSnapshot, ports: [PortEdit], vlans: [VLANEdit]) -> ChangePlan {
        let state: EdgeOSState
        if case let .edgeos(s) = snapshot.vendor { state = s } else { state = EdgeOSState() }
        var book = VLANBook(snapshot: snapshot, state: state)
        var changes: [PlannedChange] = []
        for edit in vlans {
            if let c = planVLAN(edit, book: &book, state: state, portEdits: ports) { changes.append(c) }
        }
        for edit in ports {
            if let c = planPort(edit, snapshot: snapshot, state: state, book: book) { changes.append(c) }
        }
        return ChangePlan(changes: changes)
    }

    // MARK: VLAN names

    /// VLAN names and numbers as the plan goes: VLAN edits run first, port edits see their result.
    struct VLANBook {
        var names: [Int: String] = [:]
        /// Names as read from the device, so a port edit that still uses a renamed VLAN's old name resolves.
        var readNames: [String: Int] = [:]
        var readNamesByID: [Int: String] = [:]
        /// switch0 vifs, and those with a description.
        var vifs: Set<Int> = []
        var described: Set<Int> = []

        init(snapshot: SwitchSnapshot, state: EdgeOSState) {
            for v in snapshot.config.vlans {
                guard let id = v.vlanID else { continue }
                names[id] = v.name
                readNames[v.name] = id
                readNamesByID[id] = v.name
            }
            if names[EdgeOSState.defaultVLAN] == nil { names[EdgeOSState.defaultVLAN] = "default" }
            readNames["default"] = EdgeOSState.defaultVLAN
            for v in state.vifs {
                vifs.insert(v.id)
                if !(v.description ?? "").isEmpty { described.insert(v.id) }
            }
        }

        func id(of name: String) -> Int? {
            if let hit = names.first(where: { $0.value == name }) { return hit.key }
            if let id = readNames[name], names[id] != nil { return id }
            return nil
        }

        func name(of id: Int) -> String { names[id] ?? (id == EdgeOSState.defaultVLAN ? "default" : "vlan\(id)") }
        func readName(of id: Int) -> String { readNamesByID[id] ?? name(of: id) }
    }

    // MARK: VLANs

    static func planVLAN(_ e: VLANEdit, book: inout VLANBook, state: EdgeOSState, portEdits: [PortEdit]) -> PlannedChange? {
        switch e {
        case let .add(name, id, _):
            // EdgeOS keeps one text per VLAN (the vif description), which is its Netdeck name.
            var warnings: [String] = []
            if !state.vlansEnabled {
                warnings.append(t("VLANs on EdgeOS need the switch0 interface with vlan-aware enabled. Set that up on the router first."))
            }
            if book.id(of: name) != nil { warnings.append(t("A VLAN named '%@' already exists.", name)) }
            if let other = book.names[id] { warnings.append(t("VLAN %@ is already used by '%@'.", String(id), other)) }
            if !(1...4094).contains(id) { warnings.append(t("The VLAN number must be between 1 and 4094.")) }
            let generic = name == "vlan\(id)"
            let command = generic ? "set \(switch0) vif \(id)" : "set \(switch0) vif \(id) description \(EdgeOSParsers.quote(name))"
            if book.names[id] == nil { book.names[id] = name }
            book.vifs.insert(id)
            if !generic { book.described.insert(id) }
            return PlannedChange(kind: .vlan, subject: name, summary: t("VLAN %@ '%@' will be added", String(id), name),
                                 commands: [command], warnings: warnings)

        case let .update(name, vlanID, description):
            guard let id = book.id(of: name) else { return notFound(name) }
            var parts: [String] = [], warnings: [String] = []
            if let n = vlanID, n != id {
                parts.append(t("number: %@ → %@", String(id), String(n)))
                warnings.append(t("EdgeOS can't change a VLAN's number. Delete the VLAN and add it again with the new number."))
            }
            if let d = description, !d.isEmpty {
                parts.append(t("description: %@ → %@", "—", d))
                warnings.append(t("On EdgeOS a VLAN has only a name (the description of its switch0 vif). Rename the VLAN instead."))
            }
            guard !warnings.isEmpty else { return nil }
            return PlannedChange(kind: .vlan, subject: name, summary: t("VLAN '%@': %@", name, parts.joined(separator: " · ")),
                                 commands: [], warnings: warnings)

        case let .rename(from, to):
            guard let id = book.id(of: from) else { return notFound(from) }
            var warnings: [String] = []
            if let other = book.id(of: to), other != id { warnings.append(t("A VLAN named '%@' already exists.", to)) }
            if id == EdgeOSState.defaultVLAN { warnings.append(t("VLAN 1 is the default VLAN; EdgeOS keeps the name 'default' for it.")) }
            var commands: [String] = []
            if to == "vlan\(id)" {
                // The generic name is what a vif without a description reads as.
                if book.described.contains(id) { commands.append("delete \(switch0) vif \(id) description") }
                book.described.remove(id)
            } else {
                // Creates the vif when the VLAN only existed on ports; it is where EdgeOS keeps the name.
                commands.append("set \(switch0) vif \(id) description \(EdgeOSParsers.quote(to))")
                book.vifs.insert(id)
                book.described.insert(id)
            }
            book.names[id] = to
            return PlannedChange(kind: .vlan, subject: from, summary: t("VLAN '%@' will be renamed to '%@'", from, to),
                                 commands: commands, warnings: warnings)

        case let .delete(name):
            guard let id = book.id(of: name) else { return notFound(name) }
            var warnings: [String] = []
            let users = ports(using: id, state: state, portEdits: portEdits, book: book)
            if !users.isEmpty {
                warnings.append(t("'%@' is used on %@. Move those ports to another VLAN first.", name, users.joined(separator: ", ")))
            }
            // A VLAN without a vif only exists through the ports that use it: nothing to delete on the device.
            let commands = book.vifs.contains(id) ? ["delete \(switch0) vif \(id)"] : []
            book.vifs.remove(id)
            book.described.remove(id)
            if id != EdgeOSState.defaultVLAN { book.names[id] = nil }
            return PlannedChange(kind: .vlan, subject: name, summary: t("VLAN '%@' will be deleted", name),
                                 commands: commands, warnings: warnings)
        }
    }

    static func notFound(_ name: String) -> PlannedChange {
        PlannedChange(kind: .vlan, subject: name, summary: t("VLAN not found"), commands: [],
                      warnings: [t("There is no VLAN named '%@'.", name)])
    }

    /// switch0 ports that will still carry VLAN `id`: staged VLAN lists count over the current settings.
    static func ports(using id: Int, state: EdgeOSState, portEdits: [PortEdit], book: VLANBook) -> [String] {
        guard state.vlanAware else { return [] }
        return state.members.keys.sorted { EdgeOSParsers.portOrder($0, $1) }.filter { port in
            if let staged = portEdits.first(where: { $0.port == port })?.vlans {
                return staged.contains { book.id(of: $0) == id }
            }
            return state.members[port]?.vlanIDs.contains(id) ?? false
        }
    }

    // MARK: Ports

    static func planPort(_ e: PortEdit, snapshot: SwitchSnapshot, state: EdgeOSState, book: VLANBook) -> PlannedChange? {
        let p = e.port
        let own = snapshot.config.interfaces[p] ?? JunosConfig.InterfaceConfig()
        let eth = "interfaces ethernet \(p)"
        var cmds: [String] = [], parts: [String] = [], warnings: [String] = []

        if let d = e.description, d != (own.description ?? "") {
            cmds.append(d.isEmpty ? "delete \(eth) description" : "set \(eth) description \(EdgeOSParsers.quote(d))")
            parts.append(t("description: %@ → %@", own.description ?? "—", d.isEmpty ? "—" : d))
        }

        if let on = e.enabled, on == own.disabled {
            cmds.append(on ? "delete \(eth) disable" : "set \(eth) disable")
            parts.append(on ? t("will be enabled") : t("will be disabled"))
        }

        if e.mode != nil || e.vlans != nil || e.nativeVlanID != nil {
            if state.vlansEnabled, let member = state.members[p] {
                planSwitchPort(e, member: member, book: book, cmds: &cmds, parts: &parts, warnings: &warnings)
            } else {
                let current = snapshot.ports.first { $0.name == p }
                if vlanEditChanges(e, current: current) {
                    warnings.append(t("%@ is not a VLAN-aware switch0 port. On EdgeOS, VLANs work only on switch0 ports with vlan-aware enabled.", p))
                    if let m = e.mode, m != current?.mode {
                        parts.append(t("mode: %@ → %@", ChangePlanner.label(current?.mode), ChangePlanner.label(m)))
                    }
                    if let v = e.vlans, v != (current?.vlans ?? []) {
                        let old = current?.vlans ?? []
                        parts.append(t("VLAN: %@ → %@", old.isEmpty ? "—" : old.joined(separator: ", "), v.isEmpty ? "—" : v.joined(separator: ", ")))
                    }
                }
            }
        }

        guard !cmds.isEmpty || !warnings.isEmpty else { return nil }
        return PlannedChange(kind: .port, subject: p, summary: parts.joined(separator: " · "), commands: cmds, warnings: warnings)
    }

    static func vlanEditChanges(_ e: PortEdit, current: SwitchPort?) -> Bool {
        if let m = e.mode, m != current?.mode { return true }
        if let v = e.vlans, v != (current?.vlans ?? []) { return true }
        if let nv = e.nativeVlanID, nv != current?.nativeVlanID { return true }
        return false
    }

    /// pvid/vid commands for a member of a vlan-aware switch0. Access: the one VLAN is the pvid, no vids.
    /// Trunk: the untagged VLAN stays when it is still listed (or `nativeVlanID` names one), the other
    /// listed VLANs become vids; an untagged VLAN that is no longer listed is removed (back to VLAN 1).
    static func planSwitchPort(_ e: PortEdit, member m: EdgeOSState.SwitchMember, book: VLANBook,
                               cmds: inout [String], parts: inout [String], warnings: inout [String]) {
        let p = e.port
        let sp = "\(switch0) switch-port interface \(p) vlan"
        let currentUntagged = m.untaggedVLAN
        let currentMode: PortMode = m.vids.isEmpty ? .access : .trunk
        let currentNames = m.vlanIDs.map(book.readName(of:))
        let targetMode = e.mode ?? currentMode
        let requested = e.vlans ?? (targetMode == .access ? Array(currentNames.prefix(1)) : currentNames)

        var ids: [Int] = []
        for n in requested {
            if let id = book.id(of: n) {
                if !ids.contains(id) { ids.append(id) }
            } else {
                warnings.append(t("%@: there is no VLAN named '%@'.", p, n))
            }
        }

        let targetPvid: Int?
        let targetVids: [Int]
        if targetMode == .access {
            if ids.count > 1 { warnings.append(t("%@: an access port can carry only one VLAN.", p)) }
            targetPvid = ids.first
            targetVids = []
        } else {
            if let nv = e.nativeVlanID {
                targetPvid = nv
            } else {
                targetPvid = ids.contains(currentUntagged) ? m.pvid : nil
            }
            let untagged = targetPvid ?? EdgeOSState.defaultVLAN
            targetVids = ids.filter { $0 != untagged }
        }
        let targetUntagged = targetPvid ?? EdgeOSState.defaultVLAN

        var vlanCmds: [String] = []
        let vidsChange = Set(targetVids) != Set(m.vids)
        // vid is a multi-value node: clear the old list, then set the full new one.
        if vidsChange && !m.vids.isEmpty { vlanCmds.append("delete \(sp) vid") }
        if let n = targetPvid, n != currentUntagged {
            vlanCmds.append("set \(sp) pvid \(n)")
        } else if targetPvid == nil, let old = m.pvid, old != EdgeOSState.defaultVLAN {
            vlanCmds.append("delete \(sp) pvid")
        }
        if vidsChange { vlanCmds += targetVids.map { "set \(sp) vid \($0)" } }
        guard !vlanCmds.isEmpty else { return }
        cmds += vlanCmds

        let newMode: PortMode = targetVids.isEmpty ? .access : .trunk
        if newMode != currentMode {
            parts.append(t("mode: %@ → %@", ChangePlanner.label(currentMode), ChangePlanner.label(newMode)))
        }
        let newIDs = [targetUntagged] + targetVids.filter { $0 != targetUntagged }
        if Set(newIDs) != Set(m.vlanIDs) {
            parts.append(t("VLAN: %@ → %@", currentNames.joined(separator: ", "), newIDs.map(book.name(of:)).joined(separator: ", ")))
        }
        if (newMode == .trunk || currentMode == .trunk), targetUntagged != currentUntagged {
            parts.append(targetPvid == nil
                ? t("untagged VLAN will be removed")
                : t("untagged VLAN: %@ → %@", book.readName(of: currentUntagged), book.name(of: targetUntagged)))
        }
    }
}
