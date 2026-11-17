import Foundation

/// Turns staged edits into RouterOS commands for a bridge with VLAN filtering. Every change also carries
/// the exact commands that put the previous values back (`PlannedChange.undo`): RouterOS has no
/// `commit confirmed`, so the safety net is a scheduled script that runs them.
///
/// Ports are found by `default-name`, so a renamed port keeps working. Member lists are always sent
/// complete (`tagged=a,b,c`), computed from the state the earlier changes of the same plan leave behind.
public enum MikroTikPlanner {
    public static func plan(snapshot: SwitchSnapshot, ports: [PortEdit], vlans: [VLANEdit]) -> ChangePlan {
        guard case let .mikrotik(state) = snapshot.vendor else { return ChangePlan(changes: []) }
        var work = state
        var changes: [PlannedChange] = []
        // VLAN deletions go last, so ports moved away in the same plan no longer count as users.
        let deletions = vlans.filter { if case .delete = $0 { return true } else { return false } }
        for e in vlans where !deletions.contains(e) {
            if let c = planVLAN(e, state: &work) { changes.append(c) }
        }
        for e in ports {
            if let c = planPort(e, snapshot: snapshot, state: &work) { changes.append(c) }
        }
        for e in deletions {
            if let c = planVLAN(e, state: &work) { changes.append(c) }
        }
        return ChangePlan(changes: changes)
    }

    // MARK: Command pieces

    static func q(_ s: String) -> String { MikroTikQuote.value(s) }

    static func ethernetSet(_ defaultName: String) -> String {
        "/interface ethernet set [find default-name=\(q(defaultName))]"
    }

    static func bridgePortSet(_ name: String) -> String {
        "/interface bridge port set [find interface=\(q(name))]"
    }

    static func vlanFind(_ bridge: String, _ ids: String) -> String {
        "[find bridge=\(q(bridge)) vlan-ids=\(q(ids))]"
    }

    /// Re-creates a removed VLAN entry with its old lists. Guarded, so running the undo after a plan that
    /// stopped before the removal doesn't create a duplicate.
    static func reAdd(_ e: MikroTikState.BridgeVLAN, bridge: String) -> String {
        var add = "/interface bridge vlan add bridge=\(q(bridge)) vlan-ids=\(q(e.vlanIDs))"
        if !e.tagged.isEmpty { add += " tagged=\(MikroTikQuote.list(e.tagged))" }
        if !e.untagged.isEmpty { add += " untagged=\(MikroTikQuote.list(e.untagged))" }
        if let c = e.comment, !c.isEmpty { add += " comment=\(MikroTikQuote.quoted(c))" }
        return ":if ([:len [/interface bridge vlan find bridge=\(q(bridge)) vlan-ids=\(q(e.vlanIDs))]] = 0) do={\(add)}"
    }

    static var needsFiltering: String {
        t("VLANs on RouterOS need bridge VLAN filtering. Turn on vlan-filtering on the bridge first.")
    }

    static func sharedEntry(_ ids: String) -> String {
        t("VLANs %@ share one bridge VLAN entry on the router. Split it into one entry per VLAN first.", ids)
    }

    // MARK: Ports

    static func planPort(_ e: PortEdit, snapshot: SwitchSnapshot, state w: inout MikroTikState) -> PlannedChange? {
        guard let port = snapshot.ports.first(where: { $0.name == e.port })
                ?? snapshot.ports.first(where: { $0.slotKey == e.port || $0.defaultName == e.port }) else { return nil }
        let name = port.name
        let def = port.defaultName ?? port.slotKey
        var cmds: [String] = [], undo: [String] = [], parts: [String] = [], warnings: [String] = []

        if let d = e.description, d != (port.description ?? "") {
            cmds.append("\(ethernetSet(def)) comment=\(MikroTikQuote.quoted(d))")
            undo.append("\(ethernetSet(def)) comment=\(MikroTikQuote.quoted(port.description ?? ""))")
            parts.append(t("description: %@ → %@", port.description ?? "—", d.isEmpty ? "—" : d))
        }

        if let on = e.enabled, on == port.configDisabled {
            cmds.append("\(ethernetSet(def)) disabled=\(on ? "no" : "yes")")
            undo.append("\(ethernetSet(def)) disabled=\(on ? "yes" : "no")")
            parts.append(on ? t("will be enabled") : t("will be disabled"))
        }

        let modeChanged = e.mode.map { $0 != port.mode } ?? false
        let vlansChanged = e.vlans.map { $0 != port.vlans } ?? false
        let nativeChanged = e.nativeVlanID.map { $0 != port.nativeVlanID } ?? false
        if modeChanged || vlansChanged || nativeChanged {
            let mode = e.mode ?? port.mode ?? .access
            let names = e.vlans ?? port.vlans
            let native: Int? = e.nativeVlanID ?? port.nativeVlanID
            if modeChanged { parts.append(t("mode: %@ → %@", ChangePlanner.label(port.mode), ChangePlanner.label(mode))) }
            if vlansChanged {
                parts.append(t("VLAN: %@ → %@", port.vlans.isEmpty ? "—" : port.vlans.joined(separator: ", "),
                               names.isEmpty ? "—" : names.joined(separator: ", ")))
            }
            if nativeChanged {
                if let n = native {
                    parts.append(t("untagged VLAN: %@ → %@", port.nativeVlanID.map(String.init) ?? "—", String(n)))
                } else {
                    parts.append(t("untagged VLAN will be removed"))
                }
            }
            if let bridge = w.bridge, w.vlanFiltering, let bp = w.bridgePort(of: name) {
                let steps = planMembership(port: name, bridgePort: bp, bridge: bridge, mode: mode, names: names, native: native, state: &w)
                cmds += steps.commands
                undo += steps.undo
                warnings += steps.warnings
            } else {
                warnings.append(t("%@: VLANs on RouterOS need bridge VLAN filtering. Add the port to the bridge and turn on vlan-filtering first.", name))
            }
        }

        guard !cmds.isEmpty || !warnings.isEmpty else { return nil }
        return PlannedChange(kind: .port, subject: name, summary: parts.joined(separator: " · "), commands: cmds,
                             warnings: warnings, undo: Array(undo.reversed()))
    }

    struct Steps {
        var commands: [String] = []
        var undo: [String] = []
        var warnings: [String] = []
    }

    /// PVID, frame types and VLAN member lists for a port's new mode and VLANs.
    /// Access: PVID = the VLAN, untagged only. Trunk: tagged in every VLAN but the untagged (native) one,
    /// which becomes the PVID; without a native VLAN the port admits tagged frames only.
    static func planMembership(port name: String, bridgePort bp: MikroTikState.BridgePort, bridge: String, mode: PortMode,
                               names: [String], native: Int?, state w: inout MikroTikState) -> Steps {
        var s = Steps()
        var ids: [Int] = []
        for n in names {
            if let id = w.vlanID(named: n) {
                if !ids.contains(id) { ids.append(id) }
            } else {
                s.warnings.append(t("%@: there is no VLAN named '%@'.", name, n))
            }
        }

        var tagged = Set<Int>(), untagged = Set<Int>()
        let pvid: Int, frameTypes: String
        switch mode {
        case .access:
            if names.count > 1 { s.warnings.append(t("%@: an access port can carry only one VLAN.", name)) }
            guard let id = ids.first else {
                if names.isEmpty { s.warnings.append(t("%@: choose a VLAN for this port.", name)) }
                return s
            }
            pvid = id
            frameTypes = MikroTikState.onlyUntagged
            untagged = [id]
        case .trunk:
            if let n = native, !ids.contains(n) {
                s.warnings.append(t("%@: untagged VLAN %@ (%@) must also be a member.", name, String(n), w.vlanName(n)))
            }
            if let n = native { untagged = [n] }
            tagged = Set(ids).subtracting(untagged)
            pvid = native ?? bp.pvid
            frameTypes = native == nil ? MikroTikState.onlyTagged : MikroTikState.admitAll
        }

        var set: [String] = [], back: [String] = []
        if pvid != bp.pvid { set.append("pvid=\(pvid)"); back.append("pvid=\(bp.pvid)") }
        if frameTypes != bp.frameTypes { set.append("frame-types=\(frameTypes)"); back.append("frame-types=\(q(bp.frameTypes))") }
        if !set.isEmpty {
            s.commands.append("\(bridgePortSet(name)) \(set.joined(separator: " "))")
            s.undo.append("\(bridgePortSet(name)) \(back.joined(separator: " "))")
            w.setBridgePort(name, pvid: pvid, frameTypes: frameTypes)
        }

        // Existing static entries: add or remove the port so its lists match the target.
        for i in w.bridgeVLANs.indices where w.isStaticEntry(i) {
            let entry = w.bridgeVLANs[i]
            let inTagged = entry.tagged.contains(name), inUntagged = entry.untagged.contains(name)
            let wantTagged = Set(entry.ids.map { tagged.contains($0) })
            let wantUntagged = Set(entry.ids.map { untagged.contains($0) })

            var tagIt = inTagged
            if wantTagged.count > 1 {
                s.warnings.append(sharedEntry(entry.vlanIDs))
                continue
            } else if let want = wantTagged.first {
                tagIt = want
            }
            var untagIt = inUntagged
            if wantUntagged.count > 1 {
                // The PVID already makes the port an untagged member; only a configured membership
                // that has to go for some of the entry's VLANs needs the entry split.
                if inUntagged {
                    s.warnings.append(sharedEntry(entry.vlanIDs))
                    continue
                }
            } else if let want = wantUntagged.first {
                untagIt = want
            }

            var newTagged = entry.tagged.filter { $0 != name }
            if tagIt { newTagged.append(name) }
            var newUntagged = entry.untagged.filter { $0 != name }
            if untagIt { newUntagged.append(name) }

            var change: [String] = [], restore: [String] = []
            if tagIt != inTagged {
                newTagged = w.sortedMembers(newTagged)
                change.append("tagged=\(MikroTikQuote.list(newTagged))")
                restore.append("tagged=\(MikroTikQuote.list(entry.tagged))")
                w.bridgeVLANs[i].tagged = newTagged
            }
            if untagIt != inUntagged {
                newUntagged = w.sortedMembers(newUntagged)
                change.append("untagged=\(MikroTikQuote.list(newUntagged))")
                restore.append("untagged=\(MikroTikQuote.list(entry.untagged))")
                w.bridgeVLANs[i].untagged = newUntagged
            }
            guard !change.isEmpty else { continue }
            s.commands.append("/interface bridge vlan set \(vlanFind(bridge, entry.vlanIDs)) \(change.joined(separator: " "))")
            s.undo.append("/interface bridge vlan set \(vlanFind(bridge, entry.vlanIDs)) \(restore.joined(separator: " "))")
        }

        // Tagged VLANs without a static entry (they only exist through a PVID or a VLAN interface).
        for id in tagged.sorted() where w.staticEntryIndex(containing: id) == nil {
            s.commands.append("/interface bridge vlan add bridge=\(q(bridge)) vlan-ids=\(id) tagged=\(q(name))")
            s.undo.append("/interface bridge vlan remove \(vlanFind(bridge, String(id)))")
            w.bridgeVLANs.append(.init(bridge: bridge, vlanIDs: String(id), ids: [id], tagged: [name]))
        }
        return s
    }

    // MARK: VLANs

    static func planVLAN(_ e: VLANEdit, state w: inout MikroTikState) -> PlannedChange? {
        switch e {
        case let .add(name, id, desc):
            var warnings: [String] = []
            if w.vlanID(named: name) != nil { warnings.append(t("A VLAN named '%@' already exists.", name)) }
            if let other = w.vlanNames[id] { warnings.append(t("VLAN %@ is already used by '%@'.", String(id), other)) }
            if !(1...4094).contains(id) { warnings.append(t("The VLAN number must be between 1 and 4094.")) }
            let summary = t("VLAN %@ '%@' will be added", String(id), name)
            guard let bridge = w.bridge, w.vlanFiltering else {
                return PlannedChange(kind: .vlan, subject: name, summary: summary, commands: [], warnings: warnings + [needsFiltering])
            }
            // Bridge VLAN entries have no name: keep the chosen name as the comment when there's no description.
            let comment = desc.flatMap { $0.isEmpty ? nil : $0 } ?? (name == "vlan\(id)" ? nil : name)
            var cmd = "/interface bridge vlan add bridge=\(q(bridge)) vlan-ids=\(id)"
            if let comment { cmd += " comment=\(MikroTikQuote.quoted(comment))" }
            w.bridgeVLANs.append(.init(bridge: bridge, vlanIDs: String(id), ids: [id], comment: comment))
            if w.vlanNames[id] == nil { w.vlanNames[id] = name }
            return PlannedChange(kind: .vlan, subject: name, summary: summary, commands: [cmd], warnings: warnings,
                                 undo: ["/interface bridge vlan remove \(vlanFind(bridge, String(id)))"])

        case let .update(name, newID, desc):
            guard let id = w.vlanID(named: name) else {
                return PlannedChange(kind: .vlan, subject: name, summary: t("VLAN not found"), commands: [],
                                     warnings: [t("There is no VLAN named '%@'.", name)])
            }
            let entryIndex = w.staticEntryIndex(containing: id)
            let currentDesc = entryIndex.flatMap { w.bridgeVLANs[$0].comment }
            let idChange = newID.flatMap { $0 == id ? nil : $0 }
            let descChange = desc.flatMap { $0 == (currentDesc ?? "") ? nil : $0 }
            guard idChange != nil || descChange != nil else { return nil }
            var cmds: [String] = [], undo: [String] = [], parts: [String] = [], warnings: [String] = []
            if let n = idChange { parts.append(t("number: %@ → %@", String(id), String(n))) }
            if let d = descChange { parts.append(t("description: %@ → %@", currentDesc ?? "—", d.isEmpty ? "—" : d)) }
            let summary = t("VLAN '%@': %@", name, parts.joined(separator: " · "))
            guard let bridge = w.bridge, w.vlanFiltering else {
                return PlannedChange(kind: .vlan, subject: name, summary: summary, commands: [], warnings: [needsFiltering])
            }

            if let n = idChange {
                if let other = w.vlanNames[n] { warnings.append(t("VLAN %@ is already used by '%@'.", String(n), other)) }
                if !(1...4094).contains(n) { warnings.append(t("The VLAN number must be between 1 and 4094.")) }
                if let i = entryIndex {
                    let old = w.bridgeVLANs[i]
                    if old.ids.count > 1 {
                        warnings.append(sharedEntry(old.vlanIDs))
                    } else {
                        cmds.append("/interface bridge vlan set \(vlanFind(bridge, old.vlanIDs)) vlan-ids=\(n)")
                        undo.append("/interface bridge vlan set \(vlanFind(bridge, String(n))) vlan-ids=\(q(old.vlanIDs))")
                        w.bridgeVLANs[i].vlanIDs = String(n)
                        w.bridgeVLANs[i].ids = [n]
                    }
                }
                for i in w.bridgePorts.indices {
                    let p = w.bridgePorts[i]
                    guard p.bridge == bridge, !p.disabled, !p.dynamic, p.pvid == id else { continue }
                    cmds.append("\(bridgePortSet(p.interface)) pvid=\(n)")
                    undo.append("\(bridgePortSet(p.interface)) pvid=\(id)")
                    w.bridgePorts[i].pvid = n
                }
                for i in w.vlanInterfaces.indices where w.vlanInterfaces[i].vlanID == id && w.vlanInterfaces[i].interface == bridge {
                    let vi = w.vlanInterfaces[i]
                    cmds.append("/interface vlan set [find name=\(q(vi.name))] vlan-id=\(n)")
                    undo.append("/interface vlan set [find name=\(q(vi.name))] vlan-id=\(id)")
                    w.vlanInterfaces[i].vlanID = n
                }
                if w.vlanNames[n] == nil {
                    w.vlanNames[n] = w.vlanNames[id]
                    w.vlanNames[id] = nil
                }
            }

            if let d = descChange {
                if let i = entryIndex {
                    let current = w.bridgeVLANs[i]
                    cmds.append("/interface bridge vlan set \(vlanFind(bridge, current.vlanIDs)) comment=\(MikroTikQuote.quoted(d))")
                    undo.append("/interface bridge vlan set \(vlanFind(bridge, current.vlanIDs)) comment=\(MikroTikQuote.quoted(current.comment ?? ""))")
                    w.bridgeVLANs[i].comment = d.isEmpty ? nil : d
                } else if !d.isEmpty {
                    // The VLAN only exists dynamically (a PVID): a static entry holds the description.
                    let vid = idChange ?? id
                    cmds.append("/interface bridge vlan add bridge=\(q(bridge)) vlan-ids=\(vid) comment=\(MikroTikQuote.quoted(d))")
                    undo.append("/interface bridge vlan remove \(vlanFind(bridge, String(vid)))")
                    w.bridgeVLANs.append(.init(bridge: bridge, vlanIDs: String(vid), ids: [vid], comment: d))
                }
            }
            guard !cmds.isEmpty || !warnings.isEmpty else { return nil }
            return PlannedChange(kind: .vlan, subject: name, summary: summary, commands: cmds, warnings: warnings,
                                 undo: Array(undo.reversed()))

        case let .rename(from, to):
            guard let id = w.vlanID(named: from) else {
                return PlannedChange(kind: .vlan, subject: from, summary: t("VLAN not found"), commands: [],
                                     warnings: [t("There is no VLAN named '%@'.", from)])
            }
            let summary = t("VLAN '%@' will be renamed to '%@'", from, to)
            var warnings: [String] = []
            if w.vlanID(named: to) != nil { warnings.append(t("A VLAN named '%@' already exists.", to)) }
            guard let bridge = w.bridge,
                  let i = w.vlanInterfaces.firstIndex(where: { $0.name == from && $0.vlanID == id && $0.interface == bridge }) else {
                warnings.append(t("RouterOS bridge VLANs have no names of their own. Netdeck shows the name of the VLAN's interface, or vlan and its number."))
                return PlannedChange(kind: .vlan, subject: from, summary: summary, commands: [], warnings: warnings)
            }
            w.vlanInterfaces[i].name = to
            w.vlanNames[id] = to
            return PlannedChange(kind: .vlan, subject: from, summary: summary,
                                 commands: ["/interface vlan set [find name=\(q(from))] name=\(q(to))"], warnings: warnings,
                                 undo: ["/interface vlan set [find name=\(q(to))] name=\(q(from))"])

        case let .delete(name):
            guard let id = w.vlanID(named: name) else {
                return PlannedChange(kind: .vlan, subject: name, summary: t("VLAN not found"), commands: [],
                                     warnings: [t("There is no VLAN named '%@'.", name)])
            }
            let summary = t("VLAN '%@' will be deleted", name)
            guard let bridge = w.bridge, w.vlanFiltering else {
                return PlannedChange(kind: .vlan, subject: name, summary: summary, commands: [], warnings: [needsFiltering])
            }
            var warnings: [String] = []
            let users = w.ports(using: id)
            if !users.isEmpty {
                warnings.append(t("'%@' is used on %@. Move those ports to another VLAN first.", name, users.joined(separator: ", ")))
            }
            if let vi = w.vlanInterfaces.first(where: { $0.vlanID == id && $0.interface == bridge }) {
                warnings.append(t("VLAN '%@' has the VLAN interface '%@' on the router. Remove that interface first.", name, vi.name))
            }
            var cmds: [String] = [], undo: [String] = []
            if let i = w.staticEntryIndex(containing: id) {
                let entry = w.bridgeVLANs[i]
                if entry.ids.count == 1 {
                    cmds.append("/interface bridge vlan remove \(vlanFind(bridge, entry.vlanIDs))")
                    undo.append(reAdd(entry, bridge: bridge))
                    w.bridgeVLANs.remove(at: i)
                } else {
                    let restIDs = entry.ids.filter { $0 != id }
                    let rest = MikroTikParsers.vlanIDString(restIDs)
                    cmds.append("/interface bridge vlan set \(vlanFind(bridge, entry.vlanIDs)) vlan-ids=\(q(rest))")
                    undo.append("/interface bridge vlan set \(vlanFind(bridge, rest)) vlan-ids=\(q(entry.vlanIDs))")
                    w.bridgeVLANs[i].vlanIDs = rest
                    w.bridgeVLANs[i].ids = restIDs
                }
            }
            w.vlanNames[id] = nil
            guard !cmds.isEmpty || !warnings.isEmpty else { return nil }
            return PlannedChange(kind: .vlan, subject: name, summary: summary, commands: cmds, warnings: warnings, undo: undo)
        }
    }
}
