import NetdeckCore
import SwiftUI

/// Three-column inspector under the stage (§3.2, §4.7): identity | settings | connected device.
struct PortInspector: View {
    @Environment(AppModel.self) private var model
    var device: DeviceProfile
    var port: SwitchPort
    var session: DeviceSession
    var colors: VLANColorMap
    var snapshot: SwitchSnapshot
    /// 1280-wide windows: columns 270 | flexible | 290 and option cards without their long hint (§2).
    var compact = false

    private var edit: PortEdit? { session.edit(for: port.name) }
    private var enabled: Bool { edit?.enabled ?? port.isEnabled }
    private var mode: PortMode { edit?.mode ?? port.mode ?? (port.vlans.count > 1 ? .trunk : .access) }
    private var vlans: [String] { edit?.vlans ?? port.vlans }
    private var desc: String { edit?.description ?? port.description ?? "" }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            identity.frame(width: compact ? 250 : 280).padding(.horizontal, 20)
            divider
            settings.frame(maxWidth: .infinity).padding(.horizontal, 20)
            divider
            ConnectedColumn(port: port, session: session, deviceID: device.id).frame(width: compact ? 270 : 300).padding(.horizontal, 20)
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var divider: some View { Rectangle().fill(Theme.border).frame(width: 1).frame(maxHeight: .infinity) }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    titleRow(staged: edit != nil)
                    titleRow(staged: false)
                }
                Text(location).font(Typo.caption).foregroundStyle(Theme.text3).lineLimit(1)
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("Port enabled")).font(Typo.bodyStrong).foregroundStyle(Theme.text1).lineLimit(1)
                    Text(t("Turning it off disconnects the device on it.")).font(Typo.micro).foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                NDSwitch(isOn: Binding(get: { enabled }, set: { session.stage(PortEdit(port: port.name, enabled: $0)) }))
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(edit?.enabled != nil ? Theme.accentSoft.opacity(0.55) : Theme.surface2))
            if edit?.enabled != nil {
                WasRow(old: port.isEnabled ? t("Up") : t("Disabled")) { session.stage(PortEdit(port: port.name, enabled: port.isEnabled)) }
            }
            VStack(spacing: 0) {
                ValueRow(label: t("Speed"), value: port.speedText)
                ValueRow(label: t("Speed setting"), value: t("Automatic"))
                ValueRow(label: t("Name on the switch"), value: port.name, mono: true)
                if let zone = port.zone { ValueRow(label: t("Security zone"), value: zone, mono: true) }
            }
        }
    }

    private func titleRow(staged: Bool) -> some View {
        HStack(spacing: 8) {
            Text(port.name).font(Typo.portTitle).tracking(-0.3).foregroundStyle(Theme.text1).lineLimit(1).fixedSize()
            statusPill(port, enabled: enabled)
            if staged { Pill(text: t("Change staged"), kind: .accent, icon: "pencil") }
        }
    }

    private var location: String {
        guard snapshot.platform == .juniperJunos, snapshot.junosModel?.rearPIC != nil else {
            return port.kind == .copper ? t("Port %@ · copper", port.label ?? String(port.number))
                                        : t("Port %@ · module slot", port.label ?? String(port.number))
        }
        guard port.kind == .copper else { return t("Port %@", String(port.number)) + " · SFP+" }
        let block = String(port.number / 12 + 1)
        return port.isTopRow ? t("Port %@ · block %@, top row · copper", String(port.number), block)
                             : t("Port %@ · block %@, bottom row · copper", String(port.number), block)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: t("Description"))
                NDTextField(placeholder: t("Description"),
                            text: Binding(get: { desc }, set: { session.stage(PortEdit(port: port.name, description: $0)) }),
                            changed: edit?.description != nil)
                if edit?.description != nil {
                    WasRow(old: port.description ?? "—") { session.stage(PortEdit(port: port.name, description: port.description ?? "")) }
                }
            }
            if port.isRouted || !snapshot.hasSwitching {
                routed
            } else {
                vlanSettings
            }
        }
    }

    /// A layer 3 port: its addresses instead of VLAN choices.
    private var routed: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel(text: t("Routed port"))
            VStack(spacing: 0) {
                if port.addresses.isEmpty {
                    ValueRow(label: t("Address"), value: "—")
                } else {
                    ForEach(port.addresses, id: \.self) { a in ValueRow(label: t("Address"), value: a == "dhcp" ? t("Automatic (DHCP)") : a, mono: a != "dhcp") }
                }
            }
            Text(t("This port routes traffic itself instead of joining a VLAN. Netdeck changes only its description and whether it is on."))
                .font(Typo.micro).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var vlanSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: t("How many networks on this port?"))
                HStack(spacing: 10) {
                    OptionCard(title: compact ? t("One network (access)") : t("One network"),
                               subtitle: compact ? nil : t("One VLAN room. For servers, modems, iDRAC. (access)"), selected: mode == .access) {
                        session.stage(PortEdit(port: port.name, mode: .access, vlans: Array(vlans.prefix(1))))
                    }
                    OptionCard(title: compact ? t("Several networks (trunk)") : t("Several networks"),
                               subtitle: compact ? nil : t("Several VLANs share one cable. For another switch or a hypervisor. (trunk)"),
                               selected: mode == .trunk) {
                        session.stage(PortEdit(port: port.name, mode: .trunk))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                if edit?.mode != nil {
                    WasRow(old: (port.mode ?? .access) == .access ? t("One network (access)") : t("Several networks (trunk)")) {
                        session.stage(PortEdit(port: port.name, mode: port.mode ?? .access, vlans: port.vlans))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: t("VLAN (room)"))
                VLANPicker(all: snapshot.config.vlans, selected: vlans, multiple: mode == .trunk, colors: colors,
                           changed: edit?.vlans != nil) { session.stage(PortEdit(port: port.name, vlans: $0)) }
                if edit?.vlans != nil {
                    WasRow(old: port.vlans.isEmpty ? "—" : port.vlans.joined(separator: ", ")) {
                        session.stage(PortEdit(port: port.name, vlans: port.vlans))
                    }
                } else {
                    Text(t("Devices in the same VLAN see each other; devices in other VLANs don’t.")).font(Typo.micro).foregroundStyle(Theme.text3)
                }
            }
        }
    }
}

/// "● Was ~~old~~ · ↶ Undo" under a changed field.
struct WasRow: View {
    var old: String
    var undo: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.accent).frame(width: 6, height: 6)
            Text(t("Was")).foregroundStyle(Theme.text3)
            Text(old).strikethrough().foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Button(action: undo) { Label(t("Undo"), systemImage: "arrow.uturn.backward") }
                .buttonStyle(PlainLinkStyle())
        }
        .font(Typo.caption)
    }
}

struct VLANPicker: View {
    var all: [JunosConfig.VLAN]
    var selected: [String]
    var multiple: Bool
    var colors: VLANColorMap
    var changed: Bool
    var onChange: ([String]) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(all.sorted { ($0.vlanID ?? 0) < ($1.vlanID ?? 0) }) { v in
                let on = selected.contains(v.name)
                Button {
                    if multiple { onChange(on ? selected.filter { $0 != v.name } : selected + [v.name]) } else { onChange([v.name]) }
                } label: {
                    VLANChip(name: v.name, vlanID: v.vlanID, color: on ? colors.color(v.name) : .slate)
                        .opacity(on ? 1 : 0.55)
                        .overlay(Capsule().strokeBorder(on ? colors.color(v.name).base : .clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(changed ? Theme.accentSoft.opacity(0.55) : Theme.surface2))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(changed ? Theme.accent.opacity(0.55) : .clear, lineWidth: 1))
    }
}

/// Wrapping row layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews) {
            for (i, x) in zip(row.items, row.xs) {
                subviews[i].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), proposal: .unspecified)
            }
        }
    }
    private struct Row { var items: [Int] = []; var xs: [CGFloat] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }
    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for (i, v) in subviews.enumerated() {
            let size = v.sizeThatFits(.unspecified)
            if rows[rows.count - 1].width + size.width > width, !rows[rows.count - 1].items.isEmpty {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var r = rows[rows.count - 1]
            r.xs.append(r.width); r.items.append(i)
            r.width += size.width + spacing; r.height = max(r.height, size.height)
            rows[rows.count - 1] = r
        }
        return rows
    }
}

struct ConnectedColumn: View {
    @Environment(AppModel.self) private var model
    var port: SwitchPort
    var session: DeviceSession
    var deviceID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FieldLabel(text: t("Connected device"))
            if let peer = PortPeer.of(port, session: session) {
                HStack(spacing: 10) {
                    AvatarCircle(symbol: peer.symbol, avatar: peer.avatar, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(peer.name).font(Typo.bodyStrong).foregroundStyle(Theme.text1).lineLimit(1)
                            Image(systemName: "pencil").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.text3)
                        }
                        Text(peer.sub).font(Typo.caption).foregroundStyle(Theme.text3).lineLimit(1)
                    }
                }
                VStack(spacing: 0) {
                    ValueRow(label: t("MAC"), value: peer.mac ?? "—", mono: true)
                    ValueRow(label: t("IP"), value: "—")
                    ValueRow(label: t("LLDP"), value: peer.lldp ?? t("The device doesn't announce itself"))
                }
                Button {
                    if let mac = peer.mac { model.connectedState[deviceID, default: ConnectedViewState()].selectedMAC = mac.lowercased() }
                    model.selection = .device(deviceID, .connected)
                } label: {
                    HStack(spacing: 4) { Text(t("Open in Connected devices")); Image(systemName: "arrow.right") }
                }
                .buttonStyle(PlainLinkStyle())
            } else {
                HStack(spacing: 10) {
                    AvatarCircle(symbol: "cable.connector", avatar: .slate, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("No cable")).font(Typo.bodyStrong).foregroundStyle(Theme.text2)
                        if let w = port.warning { Text(w).font(Typo.caption).foregroundStyle(Theme.warnInk).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            }
        }
    }
}

// MARK: - Nothing selected (§3.2)

struct NothingSelected: View {
    var snapshot: SwitchSnapshot
    var session: DeviceSession
    var onSelect: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "cursorarrow.click").font(.system(size: 20, weight: .medium)).foregroundStyle(Theme.text3)
                Text(t("Click a port")).font(Typo.portTitle).foregroundStyle(Theme.text1)
                Text(t("Click a port on the panel to see and edit it.")).font(Typo.callout).foregroundStyle(Theme.text2)
            }
            .frame(width: 280, alignment: .leading).padding(.horizontal, 20)
            Rectangle().fill(Theme.border).frame(width: 1).frame(maxHeight: .infinity)
            list(Format.plural(warnings.count, t("%@ warning", "1"), t("%@ warnings", String(warnings.count))), warnings.map { p in
                (p.slotKey, p.name, p.warning ?? "", "exclamationmark.triangle.fill", Avatar.butter)
            })
            Rectangle().fill(Theme.border).frame(width: 1).frame(maxHeight: .infinity)
            list(t("Connected devices"), snapshot.ports.compactMap { p in
                PortPeer.of(p, session: session).map { (p.slotKey, $0.name, $0.sub, $0.symbol, $0.avatar) }
            })
        }
        .padding(.vertical, 18)
    }

    private var warnings: [SwitchPort] { snapshot.ports.filter { $0.warning != nil } }

    private func list(_ title: String, _ rows: [(String, String, String, String, Avatar)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: title)
            ForEach(rows.prefix(4), id: \.0) { row in
                Button { onSelect(row.0) } label: {
                    HStack(spacing: 10) {
                        AvatarCircle(symbol: row.3, avatar: row.4, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.1).font(Typo.bodyStrong).foregroundStyle(Theme.text1)
                            Text(row.2).font(Typo.caption).foregroundStyle(Theme.text3)
                        }
                        .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text4)
                    }
                    .padding(.vertical, 4).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
    }
}

// MARK: - Inspector while waiting for confirmation (§3.9)

struct TrialInspector: View {
    var session: DeviceSession
    var pending: DeviceSession.PendingCommit
    @State private var checked: Set<Int> = []

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(text: t("Changes on trial"))
                ForEach(Array(pending.summary.enumerated()), id: \.offset) { _, line in
                    let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "clock.fill").font(.system(size: 10)).foregroundStyle(Theme.warn).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(parts.first ?? line).font(.system(size: 12.5, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text1)
                            if parts.count > 1 { Text(parts[1]).font(Typo.caption).foregroundStyle(Theme.text2).lineLimit(2) }
                        }
                    }
                }
            }
            .frame(width: 280, alignment: .leading).padding(.horizontal, 20)
            Rectangle().fill(Theme.border).frame(width: 1).frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(text: t("Check before confirming"))
                check(0, t("Is the internet working?"), action: t("Test"))
                check(1, t("Does %@ open?", t("Server %@ iDRAC", "2")), action: t("Open"))
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good)
                    Text(t("Netdeck is still connected to the switch")).font(Typo.body).foregroundStyle(Theme.text1)
                }
                .frame(height: 30)
                Text(t("If something went wrong, choose \"Roll back now\" or wait: at %@ the switch goes back on its own.", Format.time(pending.deadline)))
                    .font(Typo.caption).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
            Rectangle().fill(Theme.border).frame(width: 1).frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 0) {
                FieldLabel(text: t("What happens next?")).padding(.bottom, 10)
                step(t("%@ · Applied", Format.time(pending.appliedAt)), t("commit confirmed %@ · backup taken", String(Int(pending.deadline.timeIntervalSince(pending.appliedAt) / 60))), Theme.good, last: false)
                step(t("Now · Waiting for you"), t("If you confirm, it becomes permanent and goes into the history"), Theme.warn, last: false)
                step(t("%@ · Automatic rollback", Format.time(pending.deadline)), t("Without confirmation the switch returns to #%@", "1"), Theme.borderStrong, last: true)
            }
            .frame(width: 300, alignment: .leading).padding(.horizontal, 20)
        }
        .padding(.vertical, 18)
    }

    /// Manual checks: Netdeck never probes the network on its own here; the user ticks them.
    private func check(_ i: Int, _ title: String, action: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: checked.contains(i) ? "checkmark.circle.fill" : "circle").foregroundStyle(checked.contains(i) ? Theme.good : Theme.text4)
            Text(title).font(Typo.body).foregroundStyle(Theme.text1).lineLimit(1)
            Spacer(minLength: 6)
            Button(action) { if checked.contains(i) { checked.remove(i) } else { checked.insert(i) } }
                .buttonStyle(SecondaryButtonStyle()).controlSize(.small)
        }
        .frame(height: 34)
    }

    private func step(_ title: String, _ sub: String, _ color: Color, last: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Circle().fill(color).frame(width: 10, height: 10).padding(.top, 4)
                if !last { Rectangle().fill(Theme.border).frame(width: 2).frame(maxHeight: .infinity) }
            }
            .frame(width: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Typo.bodyStrong).foregroundStyle(Theme.text1).monospacedDigit()
                Text(sub).font(Typo.caption).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, last ? 0 : 12)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Table of all ports (list icon, §3.2, §4.8)

struct PortTable: View {
    var snapshot: SwitchSnapshot
    var session: DeviceSession
    var colors: VLANColorMap
    @Binding var selected: String?

    private let widths: [CGFloat] = [110, 200, 120, 220, 130]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array([t("Port"), t("Description"), t("Status"), t("VLAN"), t("Speed")].enumerated()), id: \.offset) { i, h in
                    Text(h).frame(width: widths[i], alignment: .leading)
                }
                Text(t("Connected device")).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.text3)
            .padding(.leading, 20).frame(height: 30)
            .background(Theme.surface2)
            NDScroll {
                VStack(spacing: 0) {
                    ForEach(snapshot.ports) { p in row(p) }
                }
            }
        }
    }

    private func row(_ p: SwitchPort) -> some View {
        let edit = session.edit(for: p.name)
        let vlans = edit?.vlans ?? p.vlans
        let isSel = selected == p.slotKey
        return Button { selected = isSel ? nil : p.slotKey } label: {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text(p.name).font(.system(size: 12.5, weight: .medium, design: .monospaced))
                    if edit != nil { Circle().fill(Theme.accent).frame(width: 6, height: 6) }
                }
                .frame(width: widths[0], alignment: .leading)
                Text(edit?.description ?? p.description ?? "—").foregroundStyle(Theme.text2).lineLimit(1).frame(width: widths[1], alignment: .leading)
                statusPill(p, enabled: edit?.enabled ?? p.isEnabled).frame(width: widths[2], alignment: .leading)
                HStack(spacing: 4) {
                    ForEach(vlans.prefix(2), id: \.self) { VLANChip(name: $0, vlanID: nil, color: colors.color($0), size: .small) }
                    if vlans.count > 2 { Text("+\(vlans.count - 2)").font(Typo.micro).foregroundStyle(Theme.text3) }
                }
                .frame(width: widths[3], alignment: .leading)
                Text(p.speedText).foregroundStyle(Theme.text2).frame(width: widths[4], alignment: .leading)
                Text(PortPeer.of(p, session: session)?.name ?? "—").foregroundStyle(Theme.text1).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(Typo.body)
            .padding(.leading, 20).frame(height: 46)
            .background(isSel ? Theme.accentSoft.opacity(0.6) : .clear)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
