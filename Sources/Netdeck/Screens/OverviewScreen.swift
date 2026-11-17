import NetdeckCore
import SwiftUI

/// All devices (§3.1).
struct OverviewScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(t("All devices")).font(Typo.title1).tracking(-0.4).foregroundStyle(Theme.text1)
                        Text(Format.plural(model.locations.count, t("%@ location", "1"), t("%@ locations", String(model.locations.count)))
                             + " · " + Format.plural(model.devices.count, t("%@ device", "1"), t("%@ devices", String(model.devices.count))))
                            .font(Typo.callout).foregroundStyle(Theme.text3)
                    }
                    Text(t("Each device has its own connection, staged changes and confirmation timer.")).font(Typo.callout).foregroundStyle(Theme.text3)
                }
                Spacer()
                Button { model.readAllAgain() } label: { Label(t("Read all again"), systemImage: "arrow.clockwise") }
                    .buttonStyle(SecondaryButtonStyle())
                Button { model.sheet = .addDevice(location: nil) } label: { Label(t("Add device"), systemImage: "plus") }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .frame(height: 52).padding(.horizontal, 4)
            if !model.waiting.isEmpty { GlobalConfirmationBanner(waiting: model.waiting) }
            ForEach(model.trialEnds, id: \.device.id) { e in
                TrialEndBanner(device: e.device, session: e.session, end: e.end, global: true)
            }
            NDScroll {
                VStack(alignment: .leading, spacing: 20) {
                    let locs = model.groupByLocation ? model.locations : [t("Devices")]
                    ForEach(Array(locs.enumerated()), id: \.element) { i, loc in
                        let devices = model.groupByLocation ? model.devices(in: loc) : model.devices
                        LocationSection(name: loc, devices: devices, showsPlaceholders: i == 0,
                                        neighbour: model.devices.first?.name ?? "")
                    }
                    SerialCablesCard()
                }
                .padding(.bottom, 8)
            }
        }
    }
}

struct LocationSection: View {
    @Environment(AppModel.self) private var model
    var name: String
    var devices: [DeviceProfile]
    var showsPlaceholders: Bool
    var neighbour: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                MicroHeading(text: name)
                Text(devices.count == 1 ? t("%@ device", "1") : t("%@ devices", String(devices.count))).font(Typo.micro).foregroundStyle(Theme.text4)
                Spacer()
                Menu {
                    Button(t("Add a device here")) { model.sheet = .addDevice(location: name) }
                    Button(t("Delete location"), role: .destructive) { model.deleteLocation(name) }.disabled(!devices.isEmpty)
                } label: { Image(systemName: "ellipsis").foregroundStyle(Theme.text3) }
                .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain).fixedSize()
            }
            .padding(.horizontal, 4)
            if devices.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "folder").font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.text3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("No devices in this location yet")).font(Typo.bodyStrong).foregroundStyle(Theme.text2)
                        Text(t("When the servers move to the data center, drag %@ here or add a new device.", neighbour))
                            .font(Typo.caption).foregroundStyle(Theme.text3)
                    }
                    Spacer()
                    Button { model.sheet = .addDevice(location: name) } label: { Label(t("Add a device here"), systemImage: "plus") }
                        .buttonStyle(SecondaryButtonStyle())
                }
                .padding(.horizontal, 18).frame(height: 68)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.borderStrong, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                .deviceDrop { ids in ids.forEach { model.move($0, to: name) }; return true }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 12) { ForEach(devices) { DeviceCard(device: $0) } }
                    if showsPlaceholders {
                        VStack(spacing: 12) {
                            ComingSoonCard(kind: .router, title: t("Router"),
                                           text: t("Watch and manage your gateway and internet connection from here too."), button: t("Add router"))
                            ComingSoonCard(kind: .storage, title: t("Storage (NAS)"), text: t("Disk health, shares and backups at a glance."),
                                           button: t("Add storage"))
                        }
                        .frame(width: 236)
                    }
                }
            }
        }
    }
}

struct DeviceCard: View {
    @Environment(AppModel.self) private var model
    var device: DeviceProfile

    var body: some View {
        let session = model.session(for: device.id)
        let snap = session?.snapshot
        let waiting = session?.pending != nil
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                TypeTile(kind: device.kind, size: 40, dark: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text1)
                    Text([snap?.model, snap?.version.junos.map { "Junos \($0)" }].compactMap { $0 }.joined(separator: " · "))
                        .font(Typo.caption).foregroundStyle(Theme.text3)
                }
                Spacer()
                DeviceStatusPill(device: device, session: session, isSample: model.isSample(device.id))
            }
            ZStack {
                StageBackground(radius: 12)
                if let snap, let session {
                    FrontPanelView(model: snap.model, vendor: "Juniper", hostname: device.name,
                                   ports: PanelBuilder.ports(snapshot: snap, session: session, colors: model.colors(for: device.id)))
                        .padding(.horizontal, 24).padding(.vertical, 14)
                        .allowsHitTesting(false)
                } else {
                    FrontPanelView(model: device.detected?.model ?? "", vendor: "", hostname: device.name, ports: [], skeleton: true)
                        .padding(.horizontal, 24).padding(.vertical, 14).opacity(0.5)
                }
            }
            .frame(height: 150)
            if let snap {
                let st = PortStats(snap)
                HStack(spacing: 8) {
                    metric("\(st.enabled) / \(st.total)", t("enabled ports"))
                    metric(String(st.up), t("up"))
                    metric(String(st.warnings), t("warnings"), warn: st.warnings > 0)
                    metric(String(st.devicesSeen), t("devices seen"))
                    metric(String(session?.stagedCount ?? 0), t("staged changes"), accent: (session?.stagedCount ?? 0) > 0)
                }
            }
            HStack {
                Text(t("Last read %@ · Last backup %@", snap.map { Format.relativeDay($0.takenAt) } ?? "—",
                       session?.backups.first.map { Format.relativeDay($0.date) } ?? "—"))
                    .font(Typo.caption).foregroundStyle(Theme.text3)
                Spacer()
                Button { model.selection = .device(device.id, .ports) } label: {
                    HStack(spacing: 4) { Text(t("Open")); Image(systemName: "arrow.right") }
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(18)
        .card()
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(waiting ? Theme.warnLine : .clear, lineWidth: 1.5))
    }

    private func metric(_ value: String, _ label: String, warn: Bool = false, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 17, weight: .semibold).monospacedDigit())
                .foregroundStyle(warn ? Theme.warnInk : (accent ? Theme.accentInk : Theme.text1))
            Text(label).font(Typo.micro).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.tail)
        }
        .help(label)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface2))
    }
}

/// Not-yet-supported kinds (§3.1). Hidden in App Store builds (§10.6).
struct ComingSoonCard: View {
    var kind: DeviceKind
    var title: String
    var text: String
    var button: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TypeTile(kind: kind, size: 36)
                Spacer()
                Pill(text: t("Coming soon"), kind: .neutral)
            }
            Text(title).font(Typo.cardTitle).foregroundStyle(Theme.text1)
            Text(text).font(Typo.caption).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { } label: { Label(button, systemImage: "plus") }.buttonStyle(SecondaryButtonStyle()).disabled(true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 186, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.borderStrong, lineWidth: 1.5))
    }
}

struct SerialCablesCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "cable.connector.horizontal").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text2)
                Text(t("Serial cables")).font(Typo.cardTitle).foregroundStyle(Theme.text1)
                Text(t("A serial cable can serve only one device at a time.")).font(Typo.caption).foregroundStyle(Theme.text3)
            }
            if model.serialCables.isEmpty {
                Text("—").font(Typo.body).foregroundStyle(Theme.text4)
            }
            ForEach(model.serialCables, id: \.self) { path in
                let owner = model.serialOwner(path)
                let canEnd = model.canEndSession(on: path)
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.surface3).frame(width: 32, height: 32)
                        .overlay(Image(systemName: "powerplug").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text1))
                    VStack(alignment: .leading, spacing: 2) {
                        Text((path as NSString).lastPathComponent).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text1)
                        Text(t("USB serial adapter · %@ baud", baudFor(path))).font(Typo.caption).foregroundStyle(Theme.text3)
                    }
                    if let owner {
                        Pill(text: t("In use by %@", owner.name), kind: .accent, dot: true)
                        Text(canEnd ? t("This serial cable is currently used by %@.", owner.name)
                                    : t("%@ is waiting for confirmation. Finish that first.", owner.name))
                            .font(Typo.caption).foregroundStyle(canEnd ? Theme.text2 : Theme.warnInk).lineLimit(1)
                    }
                    Spacer()
                    if owner != nil {
                        Button(t("End session")) { model.endSession(on: path) }.buttonStyle(SecondaryButtonStyle()).disabled(!canEnd)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface2))
            }
        }
        .padding(18)
        .card()
    }

    private func baudFor(_ path: String) -> String {
        for d in model.devices { if case let .serial(p, b) = d.connection, p == path { return String(b) } }
        return "9600"
    }
}

/// First run: no devices yet (§3.10 first run).
struct FirstRunView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                StageBackground()
                FrontPanelView(model: "", vendor: "", hostname: "", ports: [], skeleton: true)
                    .padding(.horizontal, 60).opacity(0.55)
            }
            .frame(width: 760, height: 190)
            VStack(spacing: 8) {
                Text(t("Add your first device")).font(Typo.title1).tracking(-0.4).foregroundStyle(Theme.text1)
                Text(t("Netdeck connects over a serial cable, SSH or an API, reads the device and draws it. Nothing changes until you review and confirm."))
                    .font(Typo.callout).foregroundStyle(Theme.text2).multilineTextAlignment(.center).frame(maxWidth: 460)
            }
            HStack(spacing: 10) {
                Button { model.sheet = .addDevice(location: nil) } label: { Label(t("Add device"), systemImage: "plus") }
                    .buttonStyle(PrimaryButtonStyle(large: true))
                Button { model.addSampleDevice() } label: { Label(t("Try with a sample switch"), systemImage: "eye") }
                    .buttonStyle(SecondaryButtonStyle(large: true))
            }
            Text(t("The sample switch is built in. Nothing is sent anywhere.")).font(Typo.caption).foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card()
    }
}
