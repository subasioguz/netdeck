import NetdeckCore
import SwiftUI

/// Ports | Rooms (§3.3): VLAN rooms under the faceplate, wired to their ports.
struct RoomsStage: View {
    @Environment(AppModel.self) private var model
    var snapshot: SwitchSnapshot
    var session: DeviceSession
    var colors: VLANColorMap
    @Binding var selected: String?
    @Binding var editing: String?
    var onAllDetails: (String) -> Void

    private let top: CGFloat = 22, gapBelow: CGFloat = 78, cw: CGFloat = 156, ch: CGFloat = 50

    struct Room { var vlan: JunosConfig.VLAN; var ports: [SwitchPort]; var x: CGFloat = 0; var width: CGFloat = 0; var cols = 1 }

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width
            let panelW = W - 40
            let ports = PanelBuilder.ports(snapshot: snapshot, session: session, colors: colors)
            let s = PanelScale(width: panelW, ports: ports)
            let panelH = panelW / FrontGeometry.aspect(ports, hasCables: false)
            let roomsY = top + panelH + gapBelow
            let rooms = layout(width: W, scale: s, ports: ports)
            let cards = cardFrames(rooms, y: roomsY)
            ZStack(alignment: .topLeading) {
                StageBackground()
                FrontPanelView(model: snapshot.model, vendor: snapshot.platform.vendor, hostname: session.profile.name, ports: ports,
                               selected: Set([selected].compactMap { $0 }), showsCables: false,
                               onTap: { p in selected = p.slotKey; editing = p.slotKey })
                    .frame(width: panelW, height: panelH).offset(x: 20, y: top)
                // Wires
                ForEach(rooms.flatMap(\.ports), id: \.slotKey) { p in
                    if let pp = ports.first(where: { $0.slotKey == p.slotKey }), let frame = cards[p.slotKey] {
                        wire(pp, port: p, to: CGPoint(x: frame.midX, y: frame.minY), scale: s)
                    }
                }
                ForEach(rooms, id: \.vlan.name) { room in roomView(room).frame(width: room.width).offset(x: room.x, y: roomsY - 38) }
                ForEach(rooms.flatMap(\.ports), id: \.slotKey) { p in
                    if let f = cards[p.slotKey] {
                        Button { selected = p.slotKey; editing = editing == p.slotKey ? nil : p.slotKey } label: { card(p) }
                            .buttonStyle(.plain).frame(width: f.width, height: f.height).offset(x: f.minX, y: f.minY)
                    }
                }
                emptyRooms(rooms).frame(width: W - 32, alignment: .trailing).offset(x: 16, y: geo.size.height - 40)
                if let key = editing, let p = snapshot.ports.first(where: { $0.slotKey == key }) {
                    let f = cards[key] ?? CGRect(x: W / 2 - 270, y: roomsY, width: 0, height: 0)
                    let px = min(max(14, f.midX - 270), W - 554)
                    let below = f.maxY + 300 < geo.size.height
                    RoomEditPopover(port: p, session: session, colors: colors, snapshot: snapshot, notchX: f.midX - px, notchOnTop: below,
                                    onClose: { editing = nil }, onAllDetails: { onAllDetails(key) })
                        .frame(width: 540)
                        .offset(x: px, y: below ? f.maxY + 10 : max(8, f.minY - 290))
                }
            }
        }
    }

    // MARK: Layout

    private func roomPorts() -> [(JunosConfig.VLAN, [SwitchPort])] {
        var byVLAN: [String: [SwitchPort]] = [:]
        for p in snapshot.ports {
            let edit = session.edit(for: p.name)
            let vlans = edit?.vlans ?? p.vlans
            let enabled = edit?.enabled ?? p.isEnabled
            guard let v = vlans.first, enabled || p.transceiver != nil else { continue }
            byVLAN[v, default: []].append(p)
        }
        return snapshot.config.vlans.compactMap { v in byVLAN[v.name].map { (v, $0) } }
    }

    private func layout(width W: CGFloat, scale s: PanelScale, ports panel: [PanelPort]) -> [Room] {
        var rooms = roomPorts().map { Room(vlan: $0.0, ports: $0.1) }
        func anchorX(_ p: SwitchPort) -> CGFloat {
            let r = panel.first { $0.slotKey == p.slotKey }?.frame ?? .zero
            return 20 + s.x(r.midX)
        }
        let avail = W - 28 - CGFloat(max(0, rooms.count - 1)) * 12
        for maxCols in stride(from: 3, through: 1, by: -1) {
            for i in rooms.indices {
                rooms[i].cols = min(rooms[i].ports.count, maxCols)
                rooms[i].width = CGFloat(rooms[i].cols) * (cw + 8) - 8 + 20
            }
            if rooms.map(\.width).reduce(0, +) <= avail { break }
        }
        // Each room as close to its ports as possible, left to right, no overlap.
        let ideal = rooms.map { r in r.ports.map(anchorX).reduce(0, +) / CGFloat(max(1, r.ports.count)) }
        let order = rooms.indices.sorted { ideal[$0] < ideal[$1] }
        var x: CGFloat = 14
        var placed: [Room] = []
        for i in order {
            var r = rooms[i]
            r.x = max(x, ideal[i] - r.width / 2)
            x = r.x + r.width + 12
            placed.append(r)
        }
        var right = W - 14
        for i in placed.indices.reversed() {
            placed[i].x = min(placed[i].x, right - placed[i].width)
            right = placed[i].x - 12
        }
        return placed
    }

    private func cardFrames(_ rooms: [Room], y: CGFloat) -> [String: CGRect] {
        var out: [String: CGRect] = [:]
        for r in rooms {
            for (i, p) in r.ports.enumerated() {
                let col = i % r.cols, row = i / r.cols
                out[p.slotKey] = CGRect(x: r.x + 10 + CGFloat(col) * (cw + 8), y: y + CGFloat(row) * (ch + 8), width: cw, height: ch)
            }
        }
        return out
    }

    // MARK: Pieces

    private func wire(_ pp: PanelPort, port: SwitchPort, to end: CGPoint, scale s: PanelScale) -> some View {
        let r = FrontGeometry.rect(for: pp)
        let start = CGPoint(x: 20 + s.x(r.midX), y: top + s.y(pp.kind == .sfp ? r.maxY : FrontGeometry.chassisHeight))
        let live = port.linkUp || port.transceiver != nil
        let color = colors.color((session.edit(for: port.name)?.vlans ?? port.vlans).first ?? "default").base
        var path = Path()
        path.move(to: start)
        let dy = (end.y - start.y) * 0.55
        path.addCurve(to: end, control1: CGPoint(x: start.x, y: start.y + dy), control2: CGPoint(x: end.x, y: end.y - dy))
        return ZStack(alignment: .topLeading) {
            path.stroke(color.opacity(live ? 1 : 0.75), style: StrokeStyle(lineWidth: live ? 3 : 1.6, lineCap: .round, dash: live ? [] : [4, 4]))
            Circle().fill(color).frame(width: 6, height: 6).position(start)
        }
    }

    private func roomView(_ room: Room) -> some View {
        let c = colors.color(room.vlan.name)
        let rows = Int(ceil(Double(room.ports.count) / Double(room.cols)))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(c.base).frame(width: 10, height: 10)
                Text(room.vlan.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(c.ink)
                if let id = room.vlan.vlanID { Text(String(id)).font(Typo.micro.monospacedDigit()).foregroundStyle(c.ink.opacity(0.7)) }
                Spacer(minLength: 4)
                let slots = room.ports.allSatisfy { $0.kind == .sfp }
                Text(slots ? Format.plural(room.ports.count, t("%@ slot", "1"), t("%@ slots", String(room.ports.count)))
                            : Format.plural(room.ports.count, t("%@ port", "1"), t("%@ ports", String(room.ports.count))))
                    .font(Typo.micro).foregroundStyle(c.ink.opacity(0.8))
            }
            .lineLimit(1)
            .frame(height: 20)
            Color.clear.frame(height: CGFloat(rows) * (ch + 8) - 8)
        }
        .padding(10)
        // Opaque under the soft tint, so wires end at the room edge in dark mode too.
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(c.soft)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(c.base.opacity(0.22), lineWidth: 1))
    }

    private func card(_ p: SwitchPort) -> some View {
        let peer = PortPeer.of(p, session: session)
        let staged = session.edit(for: p.name) != nil
        let dac = p.kind == .sfp && p.transceiver != nil
        let isSel = selected == p.slotKey
        let filled = peer != nil || dac
        return HStack(spacing: 8) {
            if let peer { AvatarCircle(symbol: peer.symbol, avatar: peer.avatar, size: 26) }
            else { AvatarCircle(symbol: dac ? "cable.connector" : "cable.connector.slash", avatar: .slate, size: 26) }
            VStack(alignment: .leading, spacing: 1) {
                // The module's own name ("25G DAC"), plus "Seen as 1G" when the switch reads it slower (§9).
                Text(peer?.name ?? (dac ? (p.transceiver?.shortName ?? "DAC") + (p.warning != nil ? " · " + t("Seen as 1G") : "") : t("No cable")))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(filled ? Theme.text1 : Theme.text2)
                HStack(spacing: 4) {
                    Circle().fill(p.warning != nil ? Theme.HW.ledAmber : (p.linkUp ? Theme.HW.ledGreen : Theme.text4)).frame(width: 5, height: 5)
                    Text(peer == nil && !dac ? (p.description ?? p.name) : p.name).font(.system(size: 11, design: peer == nil && !dac ? .default : .monospaced))
                        .foregroundStyle(Theme.text3)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if staged { Circle().fill(Theme.accent).frame(width: 7, height: 7) }
        }
        .padding(9)
        .frame(width: cw, height: ch)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(filled ? Theme.surface : Theme.surface.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(isSel ? Theme.accent : (p.warning != nil ? Theme.warnLine : (filled ? Theme.border : Theme.borderStrong)),
                          style: StrokeStyle(lineWidth: isSel ? 1.5 : 1, dash: filled || isSel ? [] : [3, 3])))
        .shadow(color: .black.opacity(filled ? 0.05 : 0), radius: 2, y: 1)
    }

    @ViewBuilder
    private func emptyRooms(_ rooms: [Room]) -> some View {
        let used = Set(rooms.map(\.vlan.name))
        let empty = snapshot.config.vlans.filter { !used.contains($0.name) }
        if !empty.isEmpty {
            HStack(spacing: 6) {
                Text(t("Rooms with no ports yet")).font(Typo.caption).foregroundStyle(Theme.text3)
                ForEach(empty) { VLANChip(name: $0.name, vlanID: $0.vlanID, color: colors.color($0.name), size: .small) }
            }
        }
    }
}

/// The Ports inspector's edit form as a popover on a room card (§3.3, 540 wide, notch 16).
struct RoomEditPopover: View {
    var port: SwitchPort
    var session: DeviceSession
    var colors: VLANColorMap
    var snapshot: SwitchSnapshot
    var notchX: CGFloat
    var notchOnTop: Bool
    var onClose: () -> Void
    var onAllDetails: () -> Void

    var body: some View {
        let edit = session.edit(for: port.name)
        let enabled = edit?.enabled ?? port.isEnabled
        let mode = edit?.mode ?? port.mode ?? .access
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(port.name).font(Typo.cardTitle).foregroundStyle(Theme.text1)
                statusPill(port, enabled: enabled)
                if edit != nil { Pill(text: t("Change staged"), kind: .accent, icon: "pencil") }
                Spacer(minLength: 8)
                Text(t("Port enabled")).font(Typo.caption).foregroundStyle(Theme.text2).fixedSize()
                NDSwitch(isOn: Binding(get: { enabled }, set: { session.stage(PortEdit(port: port.name, enabled: $0)) }))
                Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle()).keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: t("Description"))
                    NDTextField(placeholder: t("Description"),
                                text: Binding(get: { edit?.description ?? port.description ?? "" },
                                              set: { session.stage(PortEdit(port: port.name, description: $0)) }),
                                changed: edit?.description != nil)
                    if edit?.description != nil {
                        WasRow(old: port.description ?? "—") { session.stage(PortEdit(port: port.name, description: port.description ?? "")) }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: t("VLAN (room)"))
                    VLANPicker(all: snapshot.config.vlans, selected: edit?.vlans ?? port.vlans, multiple: mode == .trunk, colors: colors,
                               changed: edit?.vlans != nil) { session.stage(PortEdit(port: port.name, vlans: $0)) }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: t("How many networks on this port?"))
                Segmented(options: [(PortMode.access, t("One network (access)"), nil), (.trunk, t("Several networks (trunk)"), nil)],
                          selection: Binding(get: { mode }, set: { session.stage(PortEdit(port: port.name, mode: $0)) }))
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 8) {
                if let peer = PortPeer.of(port, session: session) {
                    AvatarCircle(symbol: peer.symbol, avatar: peer.avatar, size: 24)
                    Text(peer.name).font(Typo.bodyStrong).foregroundStyle(Theme.text1)
                    Text(peer.mac ?? "").font(Typo.mono).foregroundStyle(Theme.text3)
                } else {
                    Text(t("No cable")).font(Typo.body).foregroundStyle(Theme.text3)
                }
                Spacer()
                Button(action: onAllDetails) { HStack(spacing: 4) { Text(t("All details")); Image(systemName: "arrow.right") } }
                    .buttonStyle(PlainLinkStyle())
            }
            .lineLimit(1)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
        .overlay(alignment: notchOnTop ? .topLeading : .bottomLeading) {
            Rectangle().fill(Theme.surface).frame(width: 16, height: 16).rotationEffect(.degrees(45))
                .offset(x: min(max(20, notchX - 8), 504), y: notchOnTop ? -7 : 7)
        }
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 32, y: 24)
        .shadow(color: .black.opacity(0.08), radius: 3, y: 2)
    }
}
