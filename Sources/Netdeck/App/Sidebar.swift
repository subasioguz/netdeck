import NetdeckCore
import SwiftUI

/// Custom sidebar on the window frame (§2). Location grouping is kept inside `SidebarGroups`
/// so it can be removed without touching anything else.
struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 38)   // traffic lights
            HStack(spacing: 9) {
                BrandLogo()
                Text(t("Netdeck")).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text1)
            }
            .padding(.horizontal, 6).padding(.bottom, 16)

            allDevicesRow.padding(.bottom, 14)

            // Plain stack while it fits; scrolls only when the list outgrows the window.
            ViewThatFits(in: .vertical) {
                groups
                NDScroll { groups }
            }
            Spacer(minLength: 8)
            if let id = model.selection.deviceID, let d = model.device(id) {
                ConnectionBox(device: d, session: model.session(for: id)).padding(.bottom, 8)
            }
            SettingsLink {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 12, weight: .medium))
                    Text(t("Settings"))
                    Spacer()
                    Text("⌘,").foregroundStyle(Theme.text4)
                }
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text2)
                .padding(.horizontal, 8).frame(height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.bottom, 12)
        .frame(width: 248)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var groups: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.devices.isEmpty {
                // First run (§3.10): a plain "Devices" heading and a dashed "Add device" row.
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(t("Devices")).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text3)
                        Spacer()
                        Button { model.sheet = .addDevice(location: nil) } label: {
                            Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: 22, height: 22).contentShape(Rectangle())
                        }
                        .buttonStyle(PlainLinkStyle(color: Theme.text3)).help(t("Add device"))
                    }
                    .padding(.leading, 8).padding(.trailing, 3)
                    Button { model.sheet = .addDevice(location: nil) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "plus").font(.system(size: 12.5, weight: .medium))
                            Text(t("Add device")).font(.system(size: 12.5, weight: .medium))
                            Spacer()
                        }
                        .padding(.horizontal, 12).frame(height: 40)
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Theme.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainLinkStyle(color: Theme.text3))
                }
            } else {
                SidebarGroups()
            }
        }
    }

    private var allDevicesRow: some View {
        let active = model.selection == .overview
        return Button { model.selection = .overview } label: {
            HStack(spacing: 9) {
                Image(systemName: "square.stack.3d.up").font(.system(size: 12.5, weight: .medium)).frame(width: 18)
                Text(t("All devices")).font(.system(size: 13, weight: active ? .semibold : .medium))
                Spacer()
                Text(String(model.devices.count)).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(Theme.text3)
            }
            .foregroundStyle(Theme.text1)
            .padding(.horizontal, 10).frame(height: 34)
            .background { if active { Color.clear.card(radius: 10) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Location groups (or one flat "Devices" list when grouping is off).
struct SidebarGroups: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: String?
    @State private var draft = ""

    var body: some View {
        if model.groupByLocation {
            ForEach(model.locations, id: \.self) { loc in group(loc, devices: model.devices(in: loc), named: true) }
            Button { model.addLocation(model.nextLocationName()) } label: {
                Label(t("Add location"), systemImage: "plus").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(PlainLinkStyle(color: Theme.text3)).padding(.horizontal, 8)
        } else {
            group(t("Devices"), devices: model.devices, named: false)
        }
    }

    @ViewBuilder
    private func group(_ name: String, devices: [DeviceProfile], named: Bool) -> some View {
        let collapsed = model.collapsedLocations.contains(name)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if renaming == name {
                    TextField("", text: $draft).textFieldStyle(.plain).font(Typo.microHeading)
                        .onSubmit { model.renameLocation(name, to: draft); renaming = nil }
                } else {
                    MicroHeading(text: name)
                }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.text4)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                Spacer()
                Text(String(devices.count)).font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(Theme.text4)
            }
            .padding(.horizontal, 8).frame(height: 22).contentShape(Rectangle())
            .onTapGesture {
                if collapsed { model.collapsedLocations.remove(name) } else { model.collapsedLocations.insert(name) }
            }
            .contextMenu {
                if named {
                    Button(t("Rename location")) { draft = name; renaming = name }
                    Button(t("Delete location"), role: .destructive) { model.deleteLocation(name) }.disabled(!devices.isEmpty)
                }
            }
            if !collapsed {
                ForEach(devices) { d in DeviceRow(device: d).deviceDrag(d.id) }
                if devices.isEmpty && named {
                    Button { model.sheet = .addDevice(location: name) } label: {
                        Label(t("Add a device here"), systemImage: "plus").font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 34)
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Theme.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }
                    .buttonStyle(PlainLinkStyle(color: Theme.text3))
                }
            }
        }
        .deviceDrop { ids in
            guard named else { return false }
            ids.forEach { model.move($0, to: name) }
            return true
        }
    }
}

struct DeviceRow: View {
    @Environment(AppModel.self) private var model
    var device: DeviceProfile

    var body: some View {
        let selectedSection: DeviceSection? = {
            if case let .device(id, s) = model.selection, id == device.id { return s }
            return nil
        }()
        let session = model.session(for: device.id)
        VStack(spacing: 4) {
            Button { model.selection = .device(device.id, selectedSection ?? (model.isBasic(device.id) ? .overview : .ports)) } label: {
                HStack(spacing: 9) {
                    TypeTile(kind: device.kind, size: 30, dark: selectedSection != nil)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name).font(Typo.bodyStrong).foregroundStyle(Theme.text1).lineLimit(1)
                        Text(session?.snapshot?.model ?? device.detected?.model ?? device.kind.title)
                            .font(Typo.micro).foregroundStyle(Theme.text3).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    DeviceBadge(session: session)
                    StatusDot(status: model.status(of: device.id))
                }
                .padding(.horizontal, 6).frame(height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let active = selectedSection, let session {
                VStack(spacing: 1) {
                    ForEach(sections(session), id: \.0) { section, count in
                        Button { model.selection = .device(device.id, section) } label: {
                            HStack {
                                Text(section.title).font(.system(size: 12.5, weight: active == section ? .semibold : .regular))
                                Spacer()
                                if let count { Text(count).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Theme.text3) }
                            }
                            .foregroundStyle(active == section ? Theme.text1 : Theme.text2)
                            .padding(.horizontal, 10).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(active == section ? Theme.surface3 : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 4).padding(.bottom, 6)
            }
        }
        .padding(selectedSection != nil ? 4 : 0)
        .background { if selectedSection != nil { Color.clear.card(radius: 12) } }
    }

    private func sections(_ s: DeviceSession) -> [(DeviceSection, String?)] {
        if model.isBasic(device.id) {
            // §3.11: only the overview, plus history when Netdeck can keep this platform's config.
            let exports = (s.detection ?? device.detected)?.platform.exportsConfig == true
            return exports ? [(.overview, nil), (.history, nil)] : [(.overview, nil)]
        }
        guard let snap = s.snapshot else {
            return [(.ports, nil), (.vlans, nil), (.connected, nil), (.history, nil)]
        }
        let copper = snap.ports.filter { $0.kind == .copper }.count
        let sfp = snap.ports.count - copper
        let devicesSeen = Set(snap.macTable.map(\.mac)).count
        return [(.ports, "\(copper) + \(sfp)"), (.vlans, String(VLANRooms(snapshot: snap, edits: s.vlanEdits).rows.filter { !$0.deleted }.count)),
                (.connected, String(devicesSeen)), (.history, nil)]
    }
}

/// Staged count (accent capsule) or countdown (warn capsule), §2.
struct DeviceBadge: View {
    var session: DeviceSession?
    var body: some View {
        if let p = session?.pending {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(Format.countdown(p.deadline.timeIntervalSince(ctx.date)))
                    .font(.system(size: 11, weight: .bold).monospacedDigit()).foregroundStyle(Color(hex: 0x3A2A06))
                    .padding(.horizontal, 6).frame(height: 18).background(Capsule().fill(Theme.warn))
            }
        } else if let n = session?.stagedCount, n > 0 {
            Text(String(n)).font(.system(size: 11, weight: .bold).monospacedDigit()).foregroundStyle(.white)
                .frame(minWidth: 18).padding(.horizontal, 3).frame(height: 18).background(Capsule().fill(Theme.accent))
        }
    }
}

/// Connection box at the bottom of the sidebar.
struct ConnectionBox: View {
    var device: DeviceProfile
    var session: DeviceSession?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .medium))
                Text(typeLabel).font(Typo.captionStrong)
            }
            .foregroundStyle(Theme.text2)
            Text(endpoint).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle)
            row(t("Last read"), session?.snapshot.map { Format.time($0.takenAt) } ?? "—")
            row(t("Last backup"), session?.backups.first.map { Format.time($0.date) } ?? "—")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface3.opacity(0.6)))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(Theme.text3); Spacer(); Text(value).foregroundStyle(Theme.text2).monospacedDigit() }
            .font(Typo.micro)
    }

    private var icon: String {
        switch device.connection.type { case .serial: return "powerplug"; case .ssh: return "terminal"; case .api: return "globe" }
    }
    private var typeLabel: String {
        switch device.connection.type { case .serial: return t("Serial console"); case .ssh: return t("SSH"); case .api: return t("API (HTTPS)") }
    }
    private var endpoint: String {
        switch device.connection {
        case let .serial(path, baud): return "\((path as NSString).lastPathComponent) · \(t("%@ baud", String(baud)))"
        case let .ssh(host, port): return port == 22 ? host : "\(host):\(port)"
        case let .api(url): return url
        }
    }
}
