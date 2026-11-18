import Foundation

/// Turns staged edits into TP-Link configuration commands, as typed after `configure`. Everything about a port
/// goes in its interface context: `description`, `shutdown`, and VLAN membership as a general port
/// (`switchport general allowed vlan 10 untagged`, `... 20,30 tagged`, `switchport pvid 10`,
/// `no switchport general allowed vlan 1`). New memberships come before old ones are removed, so a port is
/// never left without a VLAN on the way.
public enum TPLinkPlanner {
    struct KnownVLAN: Equatable {
        var name: String
        var id: Int
    }

    public static func plan(snapshot: SwitchSnapshot, ports: [PortEdit], vlans: [VLANEdit]) -> ChangePlan {
        let state: TPLinkState
        if case let .tplink(s) = snapshot.vendor { state = s } else { state = TPLinkState() }
        var known = snapshot.config.vlans.compactMap { v in v.vlanID.map { KnownVLAN(name: v.name, id: $0) } }
        var changes: [PlannedChange] = []
        for edit in vlans {
            if let c = planVLAN(edit, vlans: &known, snapshot: snapshot, portEdits: ports) { changes.append(c) }
        }
        for edit in ports {
            if let c = planPort(edit, vlans: known, snapshot: snapshot, state: state) { changes.append(c) }
        }
        if state.controllerManaged, !changes.isEmpty {
            changes[0].warnings.append(t("An Omada controller manages this switch, and it only takes show commands. Netdeck reads it but doesn't change it; make changes in the controller."))
        }
        return ChangePlan(changes: changes)
    }

    // MARK: Ports

    static func planPort(_ e: PortEdit, vlans: [KnownVLAN], snapshot: SwitchSnapshot, state: TPLinkState) -> PlannedChange? {
        let p = e.port
        guard let sp = snapshot.port(named: p) else { return nil }
        let cfg = state.ports[p] ?? TPLinkPortConfig()

        var body: [String] = [], parts: [String] = [], warnings: [String] = []
        var disable = false, enable = false
        func id(_ name: String) -> Int? { vlans.first { $0.name == name }?.id }
        func name(_ id: Int) -> String? { vlans.first { $0.id == id }?.name }

        let currentDescription = sp.description ?? ""
        if let d = e.description, d != currentDescription {
            if d.count > 16 || d.contains(where: { "\"()<>,\\&".contains($0) }) {
                warnings.append(t("%@: port descriptions on this switch are at most 16 characters, without quotes, brackets or < > , \\ &.", p))
            }
            body.append(d.isEmpty ? "no description" : "description \"\(d)\"")
            parts.append(t("description: %@ → %@", currentDescription.isEmpty ? "—" : currentDescription, d.isEmpty ? "—" : d))
        }

        if let on = e.enabled, on != !sp.configDisabled {
            if on { enable = true; parts.append(t("will be enabled")) } else { disable = true; parts.append(t("will be disabled")) }
        }

        let shownMode = sp.mode ?? cfg.mode ?? .access
        let shownVLANs = sp.vlans
        let modeChanges = e.mode.map { $0 != shownMode } ?? false
        let vlansChange = e.vlans.map { $0 != shownVLANs } ?? false
        let nativeChanges: Bool = {
            guard let nv = e.nativeVlanID else { return false }
            return nv != cfg.native
        }()

        var membership: [String] = []
        if modeChanges || vlansChange || nativeChanges {
            if let lag = cfg.lag {
                warnings.append(t("%@ belongs to %@; its VLANs follow the LAG. Netdeck doesn't change them.", p, lag))
            } else if cfg.unusual {
                warnings.append(t("%@ has a VLAN setup Netdeck can't show as access or trunk (%@). Change it on the switch.", p, cfg.summary))
            } else {
                let target = e.mode ?? shownMode
                if modeChanges { parts.append(t("mode: %@ → %@", ChangePlanner.label(shownMode), ChangePlanner.label(target))) }
                let wanted = e.vlans ?? shownVLANs
                for v in wanted where id(v) == nil { warnings.append(t("%@: there is no VLAN named '%@'.", p, v)) }
                if wanted.isEmpty { warnings.append(t("%@: the port must stay a member of at least one VLAN.", p)) }
                if wanted != shownVLANs {
                    parts.append(t("VLAN: %@ → %@", shownVLANs.isEmpty ? "—" : shownVLANs.joined(separator: ", "),
                                   wanted.isEmpty ? "—" : wanted.joined(separator: ", ")))
                }
                let wantedIDs = wanted.compactMap(id)

                // The untagged VLAN (also the PVID) after the change, and the tagged ones.
                let untagged: Int?
                if target == .access {
                    if wanted.count > 1 { warnings.append(t("%@: an access port can carry only one VLAN.", p)) }
                    untagged = wantedIDs.first
                } else if let nv = e.nativeVlanID {
                    untagged = nv
                    if let n = nv, let nm = name(n), !wanted.contains(nm) {
                        warnings.append(t("%@: untagged VLAN %@ (%@) must also be a member.", p, String(n), nm))
                    }
                } else if let n = cfg.native, wantedIDs.contains(n) {
                    untagged = n
                } else {
                    untagged = nil
                }
                let tagged = target == .access ? [] : wantedIDs.filter { $0 != untagged }
                if target == .trunk, nativeChanges {
                    parts.append(t("untagged VLAN: %@ → %@", cfg.native.map(String.init) ?? "—", untagged.map(String.init) ?? "—"))
                }

                let now = Set(cfg.untagged + cfg.tagged)
                if let u = untagged, !cfg.untagged.contains(u) { membership.append("switchport general allowed vlan \(u) untagged") }
                if let u = untagged, u != cfg.pvid { membership.append("switchport pvid \(u)") }
                let addTagged = tagged.filter { !cfg.tagged.contains($0) }
                if !addTagged.isEmpty { membership.append("switchport general allowed vlan \(TPLinkParsers.vlanListString(addTagged)) tagged") }
                let keep = Set(tagged + [untagged].compactMap { $0 })
                let remove = now.subtracting(keep)
                if !remove.isEmpty, !keep.isEmpty {
                    membership.append("no switchport general allowed vlan \(TPLinkParsers.vlanListString(Array(remove)))")
                }
                // Names that aren't VLANs stay in the commands as typed; the warning keeps them from being sent.
                for v in wanted where id(v) == nil {
                    membership.append("switchport general allowed vlan \(v) \(target == .access ? "untagged" : "tagged")")
                }
            }
        }

        var inner: [String] = []
        if disable { inner.append("shutdown") }
        inner += body + membership
        if enable { inner.append("no shutdown") }
        guard !inner.isEmpty || !warnings.isEmpty else { return nil }
        let commands = inner.isEmpty ? [] : ["interface \(TPLinkParsers.longName(p))"] + inner.map { "  " + $0 } + ["  exit"]
        return PlannedChange(kind: .port, subject: p, summary: parts.joined(separator: " · "), commands: commands, warnings: warnings)
    }

    // MARK: VLANs

    static func planVLAN(_ e: VLANEdit, vlans: inout [KnownVLAN], snapshot: SwitchSnapshot, portEdits: [PortEdit]) -> PlannedChange? {
        func notFound(_ name: String) -> PlannedChange {
            PlannedChange(kind: .vlan, subject: name, summary: t("VLAN not found"), commands: [], warnings: [t("There is no VLAN named '%@'.", name)])
        }
        switch e {
        case let .add(name, id, desc):
            var warnings: [String] = []
            if vlans.contains(where: { $0.name == name }) { warnings.append(t("A VLAN named '%@' already exists.", name)) }
            if let other = vlans.first(where: { $0.id == id }) { warnings.append(t("VLAN %@ is already used by '%@'.", String(id), other.name)) }
            if !(1...4094).contains(id) { warnings.append(t("The VLAN number must be between 1 and 4094.")) }
            warnings += nameProblems(name)
            if let d = desc, !d.isEmpty { warnings.append(t("This switch's VLANs have no description. Leave it empty.")) }
            vlans.append(KnownVLAN(name: name, id: id))
            return PlannedChange(kind: .vlan, subject: name, summary: t("VLAN %@ '%@' will be added", String(id), name),
                                 commands: ["vlan \(id)", "  name \"\(name)\"", "  exit"], warnings: warnings)

        case let .update(name, id, desc):
            guard let current = vlans.first(where: { $0.name == name }) else { return notFound(name) }
            var parts: [String] = [], warnings: [String] = []
            if let id, id != current.id {
                parts.append(t("number: %@ → %@", String(current.id), String(id)))
                warnings.append(t("The switch can't change a VLAN's number. Add a VLAN with the new number and move the ports to it."))
            }
            if let desc, !desc.isEmpty {
                parts.append(t("description: %@ → %@", "—", desc))
                warnings.append(t("This switch's VLANs have no description. Leave it empty."))
            }
            guard !parts.isEmpty else { return nil }
            return PlannedChange(kind: .vlan, subject: name, summary: t("VLAN '%@': %@", name, parts.joined(separator: " · ")),
                                 commands: [], warnings: warnings)

        case let .rename(from, to):
            guard let current = vlans.first(where: { $0.name == from }) else { return notFound(from) }
            var warnings: [String] = []
            if current.id == 1 { warnings.append(t("The default VLAN (1) can't be renamed or deleted.")) }
            if vlans.contains(where: { $0.name == to && $0.id != current.id }) { warnings.append(t("A VLAN named '%@' already exists.", to)) }
            warnings += nameProblems(to)
            if let i = vlans.firstIndex(where: { $0.name == from }) { vlans[i].name = to }
            return PlannedChange(kind: .vlan, subject: from, summary: t("VLAN '%@' will be renamed to '%@'", from, to),
                                 commands: ["vlan \(current.id)", "  name \"\(to)\"", "  exit"], warnings: warnings)

        case let .delete(name):
            guard let current = vlans.first(where: { $0.name == name }) else { return notFound(name) }
            var warnings: [String] = []
            if current.id == 1 { warnings.append(t("The default VLAN (1) can't be renamed or deleted.")) }
            // Ports whose only VLAN this is would be left without one.
            let users = snapshot.ports.filter { port in
                guard port.vlans == [name] else { return false }
                if let edit = portEdits.first(where: { $0.port == port.name }), let moved = edit.vlans { return moved.contains(name) }
                return true
            }.map(\.name)
            if !users.isEmpty {
                warnings.append(t("'%@' is used on %@. Move those ports to another VLAN first.", name, users.joined(separator: ", ")))
            }
            vlans.removeAll { $0.id == current.id }
            return PlannedChange(kind: .vlan, subject: name, summary: t("VLAN '%@' will be deleted", name),
                                 commands: ["no vlan \(current.id)"], warnings: warnings)
        }
    }

    // MARK: Restoring

    /// Commands that take `current` back to `target` for everything Netdeck changes: VLANs and their names, port
    /// descriptions, `shutdown`, VLAN membership and PVID. Used to undo a change without a restart, with the
    /// startup configuration as the target. New VLANs first, removed ones last.
    public static func restore(from current: TPLinkRunningConfig, to target: TPLinkRunningConfig) -> [String] {
        var out: [String] = []
        for (id, name) in target.vlans.sorted(by: { $0.key < $1.key }) where id != 1 {
            guard let now = current.vlans[id] else {
                out += ["vlan \(id)"] + (name.isEmpty ? [] : ["  name \"\(name)\""]) + ["  exit"]
                continue
            }
            if !name.isEmpty, now != name { out += ["vlan \(id)", "  name \"\(name)\"", "  exit"] }
        }
        let names = Set(current.interfaces.keys).union(target.interfaces.keys)
            .filter(TPLinkParsers.isFrontPort)
            .sorted { TPLinkSnapshotBuilder.order($0).lexicographicallyPrecedes(TPLinkSnapshotBuilder.order($1)) }
        for name in names {
            let now = current.interfaces[name], want = target.interfaces[name]
            var inner: [String] = []
            if (now?.description ?? "") != (want?.description ?? "") {
                inner.append(want?.description.flatMap { $0.isEmpty ? nil : "description \"\($0)\"" } ?? "no description")
            }
            if (now?.shutdown ?? false) != (want?.shutdown ?? false) {
                inner.append(want?.shutdown == true ? "shutdown" : "no shutdown")
            }
            if now?.channelGroup == nil, want?.channelGroup == nil {
                let a = TPLinkPortConfig(now), b = TPLinkPortConfig(want)
                let addUntagged = b.untagged.filter { !a.untagged.contains($0) }
                let addTagged = b.tagged.filter { !a.tagged.contains($0) }
                let remove = Set(a.untagged + a.tagged).subtracting(b.untagged + b.tagged)
                if !addUntagged.isEmpty { inner.append("switchport general allowed vlan \(TPLinkParsers.vlanListString(addUntagged)) untagged") }
                if !addTagged.isEmpty { inner.append("switchport general allowed vlan \(TPLinkParsers.vlanListString(addTagged)) tagged") }
                if a.pvid != b.pvid { inner.append("switchport pvid \(b.pvid)") }
                if !remove.isEmpty { inner.append("no switchport general allowed vlan \(TPLinkParsers.vlanListString(Array(remove)))") }
            }
            if !inner.isEmpty { out += ["interface \(TPLinkParsers.longName(name))"] + inner.map { "  " + $0 } + ["  exit"] }
        }
        for id in current.vlans.keys.sorted() where id != 1 && target.vlans[id] == nil { out.append("no vlan \(id)") }
        return out
    }

    /// VLAN names on TP-Link switches: at most 16 characters, none of `" < > , \ &`.
    static func nameProblems(_ name: String) -> [String] {
        name.isEmpty || name.count > 16 || name.contains(where: { "\"<>,\\&".contains($0) })
            ? [t("'%@': VLAN names on this switch are 1–16 characters and can't contain \" < > , \\ or &.", name)] : []
    }
}
