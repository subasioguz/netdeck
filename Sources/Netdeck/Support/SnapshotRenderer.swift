import AppKit
import NetdeckCore
import SwiftUI

/// `Netdeck --render <dir> [light|dark]` renders key views to PNG and exits. Used to check the UI
/// against docs/DESIGN.md without clicking through the app.
@MainActor
enum SnapshotRenderer {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        let dark = args.contains("dark")
        RenderMode.active = true
        L10n.language = args.contains("tr") ? .tr : .en
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // `--only a,b` renders just the named views (prefix match), for quick iteration.
        let only = args.firstIndex(of: "--only").flatMap { $0 + 1 < args.count ? args[$0 + 1].split(separator: ",").map(String.init) : nil }
        for (name, view, size) in RenderCatalog.views() where only.map({ $0.contains { name.hasPrefix($0) } }) ?? true {
            render(view, size: size, dark: dark, to: dir.appendingPathComponent("\(name)\(dark ? "-dark" : "").png"))
        }
        exit(0)
    }

    static func render(_ view: AnyView, size: CGSize, dark: Bool, to url: URL) {
        let content = view
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        NSApp?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        guard let cg = renderer.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// Views to render; extended as screens are built. Everything runs on the offline sample switch.
@MainActor
enum RenderCatalog {
    static let window = CGSize(width: 1440, height: 900)

    static func sampleModel(staged: Bool = true, pending: Bool = false) -> AppModel {
        let model = AppModel(persists: false)
        model.addSampleDevice()
        let id = DemoData.profile().id
        if let s = model.session(for: id) {
            if staged {
                s.stage(PortEdit(port: "ge-0/0/2", description: "SRV02-IDRAC"))
                s.stage(PortEdit(port: "ge-0/0/3", enabled: true, vlans: ["cust-01"]))
                s.stage(PortEdit(port: "ge-0/0/24", description: "IPMI-CUST01-01B"))
            }
            if pending {
                let now = Date()
                // Summaries come from the planner, as after a real apply (and in the rendered language).
                let scratch = DeviceSession(profile: DemoData.profile(), snapshot: DemoData.snapshot())
                scratch.stage(PortEdit(port: "ge-0/0/2", description: "SRV02-IDRAC"))
                scratch.stage(PortEdit(port: "ge-0/0/3", enabled: true, vlans: ["cust-01"]))
                s.setOfflinePending(.init(comment: "Netdeck: ge-0/0/2", appliedAt: now.addingTimeInterval(-28), deadline: now.addingTimeInterval(272),
                                          summary: scratch.plan.changes.map { "\($0.subject): \($0.summary)" }))
            }
        }
        model.portsState[id] = PortsViewState(selected: "0/0/2")
        return model
    }

    static func root(_ model: AppModel) -> AnyView { AnyView(RootView().environment(model)) }

    static func views() -> [(String, AnyView, CGSize)] {
        let snap = DemoData.snapshot()
        let ports = PanelBuilder.ports(snapshot: snap, session: nil, colors: VLANColorMap.default(for: snap))
        let id = DemoData.profile().id
        var out: [(String, AnyView, CGSize)] = [
            ("faceplate", AnyView(
                FrontPanelView(model: snap.model, vendor: snap.platform.vendor, hostname: snap.hostname, ports: ports, selected: ["0/0/2"])
                    .padding(20).background(Theme.stageMid)), CGSize(width: 1100, height: 240)),
            ("firstrun", root(AppModel(persists: false)), window),
        ]
        let overview = sampleModel()
        overview.selection = .overview
        out.append(("overview", root(overview), window))

        let ports1 = sampleModel()
        out.append(("ports", root(ports1), window))

        let nothing = sampleModel(staged: false)
        nothing.portsState[id]?.selected = nil
        out.append(("ports-nothing", root(nothing), window))

        let list = sampleModel()
        list.portsState[id]?.list = true
        out.append(("ports-list", root(list), window))

        let rooms = sampleModel()
        rooms.portsState[id]?.mode = .rooms
        out.append(("rooms", root(rooms), window))
        let roomsEdit = sampleModel()
        roomsEdit.portsState[id]?.mode = .rooms
        roomsEdit.portsState[id]?.roomEditing = "0/0/2"
        out.append(("rooms-edit", root(roomsEdit), window))

        let rear = sampleModel()
        rear.portsState[id]?.face = .rear
        out.append(("rear", root(rear), window))

        let countdown = sampleModel(staged: false, pending: true)
        out.append(("countdown", root(countdown), window))
        let globalBanner = sampleModel(staged: false, pending: true)
        globalBanner.selection = .overview
        out.append(("overview-waiting", root(globalBanner), window))
        // How a trial ends (§3.9): green for 3 s after Confirm, grey when the timer ran out (edits staged again).
        let now = Date()
        let confirmed = sampleModel(staged: false)
        confirmed.session(for: id)?.setOfflineTrialEnd(.confirmed(at: now))
        out.append(("countdown-confirmed", root(confirmed), window))
        let timedOut = sampleModel()
        timedOut.session(for: id)?.setOfflineTrialEnd(.timedOut(deadline: now.addingTimeInterval(-40), restaged: 3))
        out.append(("countdown-timedout", root(timedOut), window))
        let overviewEnded = sampleModel()
        overviewEnded.selection = .overview
        overviewEnded.session(for: id)?.setOfflineTrialEnd(.timedOut(deadline: now.addingTimeInterval(-40), restaged: 3))
        out.append(("overview-timedout", root(overviewEnded), window))
        let overviewConfirmed = sampleModel(staged: false)
        overviewConfirmed.selection = .overview
        overviewConfirmed.session(for: id)?.setOfflineTrialEnd(.confirmed(at: now))
        out.append(("overview-confirmed", root(overviewConfirmed), window))

        let review = sampleModel()
        if let s = review.session(for: id) {
            out.append(("review", AnyView(ReviewSheet(session: s, isSample: true, timer: 5, showDetails: true).environment(review)),
                        CGSize(width: 800, height: 862)))
        }
        // VLANs: cust-01 selected (ge-0/0/3 joins with a staged change), a staged rename of cust-01-oob.
        let vlans = sampleModel()
        vlans.selection = .device(id, .vlans)
        if let s = vlans.session(for: id) { s.stage(VLANEdit.rename(from: "cust-01-oob", to: "cust-01-ipmi")) }
        vlans.vlansState[id] = VLANsViewState(selected: "cust-01")
        out.append(("vlans", root(vlans), window))
        let vlansRename = sampleModel()
        vlansRename.selection = .device(id, .vlans)
        if let s = vlansRename.session(for: id) {
            s.stage(VLANEdit.rename(from: "cust-01-oob", to: "cust-01-ipmi"))
            VLANsScreen.addVLAN(model: vlansRename, deviceID: id, session: s)
        }
        vlansRename.vlansState[id] = VLANsViewState(selected: "cust-01-oob")
        out.append(("vlans-rename", root(vlansRename), window))
        out.append(("vlans-1280", root(vlans), CGSize(width: 1280, height: 800)))

        // Connected devices: Server 1 iDRAC selected (description suggestion), ge-0/0/0 collapsed.
        let connected = sampleModel()
        connected.selection = .device(id, .connected)
        connected.connectedState[id] = ConnectedViewState(selectedMAC: "b0:7b:25:00:00:0b")
        out.append(("connected", root(connected), window))
        let connectedAll = sampleModel(staged: false)
        connectedAll.selection = .device(id, .connected)
        connectedAll.connectedState[id] = ConnectedViewState(selectedMAC: LocalMACs.sampleAddress)
        out.append(("connected-thismac", root(connectedAll), CGSize(width: 1280, height: 800)))

        let small = sampleModel()
        out.append(("ports-1280", root(small), CGSize(width: 1280, height: 800)))

        out += historyViews()
        out += connectionViews()
        out += addDeviceViews()
        out += settingsViews()
        return out
    }

    // MARK: Add device and Settings (shown over the window, like the mockups)

    /// The window with a dimmed scrim and a sheet or panel on top, as macOS shows it.
    static func overlay(_ model: AppModel, behind: AppModel? = nil, top: CGFloat, radius: CGFloat, scrim: Double = 0.32,
                        @ViewBuilder _ panel: () -> some View) -> AnyView {
        AnyView(ZStack(alignment: .top) {
            RootView().environment(behind ?? model)
            Color.dynamic(Color(hex: 0x141418, opacity: scrim), Color.black.opacity(0.55))
            panel().environment(model)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .compositingGroup()
                .modifier(SheetShadow(radius: radius))
                .padding(.top, top)
        })
    }

    static let samplePort = "/dev/cu.usbserial-1410"

    static func addForm(location: String? = nil, setup: (AddDeviceForm) -> Void = { _ in }) -> AddDeviceForm {
        let form = AddDeviceForm(location: location, deviceID: "render-new", ports: [samplePort])
        form.password = "netdeck123"
        setup(form)
        return form
    }

    static func addDeviceViews() -> [(String, AnyView, CGSize)] {
        var out: [(String, AnyView)] = []
        func sheet(_ model: AppModel, _ form: AddDeviceForm) -> AnyView {
            overlay(model, top: 18, radius: 18) { AddDeviceSheet(form: form) }
        }
        // First run, nothing tested yet.
        out.append(("add-device", sheet(AppModel(persists: false), addForm())))
        // 07: the switch was recognized and is fully supported.
        let ex4300 = Detection(platform: .juniperJunos, model: "EX4300-48T", osVersion: "21.2R3.8", hostname: "sw-01", kind: .switchDevice,
                               serial: "PE0000000001")
        out.append(("add-device-full", sheet(AppModel(persists: false), addForm { $0.result = .full(ex4300) })))
        // 07b: manual brand/family picker; the cable is held by the sample switch (staged changes, no timer).
        let manual = sampleModel()
        manual.selection = .overview
        out.append(("add-device-manual", sheet(manual, addForm(location: manual.locations.first) { $0.manual = true })))
        // Same cable while sw-01 waits for confirmation: testing and adding are blocked.
        let blocked = sampleModel(staged: false, pending: true)
        blocked.selection = .overview
        out.append(("add-device-blocked", sheet(blocked, addForm(location: blocked.locations.first))))
        // 07c: a MikroTik router over SSH, recognized with basic support.
        let basic = sampleModel(staged: false, pending: true)
        basic.selection = .overview
        let mikrotik = Detection(platform: .mikrotikRouterOS, model: "RB5009UG+S+", osVersion: "7.16", hostname: "gw-01", kind: .router,
                                 uptime: "12d4h3m", serial: "HEX0000001")
        out.append(("add-device-basic", sheet(basic, addForm(location: basic.locations.first) { f in
            f.kind = .router
            f.connection = .ssh
            f.host = "192.168.88.1"
            f.username = "admin"
            f.result = .basic(mikrotik)
        })))
        // Already in the list: the primary button becomes Open.
        let dupModel = deviceModel(switchProfile()) { s in s.setOfflinePhase(.ready) }
        dupModel.selection = .overview
        out.append(("add-device-duplicate", sheet(dupModel, addForm { $0.result = .duplicate(switchProfile(), ex4300) })))
        // Failures: the §3.13 cards in compact form.
        out.append(("add-device-failed", sheet(AppModel(persists: false), addForm { $0.result = .failed(.wrongPassword) })))
        out.append(("add-device-failed-cable", sheet(AppModel(persists: false), addForm { f in
            f.ports = []
            f.result = .failed(.cableNotFound(path: samplePort))
        })))
        out.append(("add-device-failed-ssh", sheet(AppModel(persists: false), addForm { f in
            f.connection = .ssh
            f.host = "192.0.2.10"
            f.username = "admin"
            f.result = .failed(.sshUnreachable(detail: "ssh: connect to host 192.0.2.10 port 22: Operation timed out"))
        })))
        // A server: only the API, which isn't available yet.
        out.append(("add-device-server", sheet(AppModel(persists: false), addForm { $0.kind = .server })))
        return out.map { ($0.0, $0.1, window) }
    }

    static func settingsViews() -> [(String, AnyView, CGSize)] {
        SettingsTab.allCases.map { tab in
            let model = sampleModel(staged: false, pending: true)
            model.selection = .overview
            let behind = sampleModel(staged: false, pending: true)
            behind.selection = .overview
            if tab == .devices {
                // A few saved devices besides the sample switch.
                var gw = DeviceProfile(id: "render-gw-01", name: "gw-01", kind: .router, location: model.locations.last,
                                       connection: .ssh(host: "192.168.88.1", port: 22), username: "admin")
                gw.detected = Detection(platform: .mikrotikRouterOS, model: "RB5009UG+S+", osVersion: "7.16", hostname: "gw-01", kind: .router)
                var sw2 = switchProfile()
                sw2.id = "render-sw-02"
                sw2.name = "sw-02"
                sw2.location = model.locations.last
                sw2.connection = .ssh(host: "10.0.10.2", port: 22)
                model.add(gw)
                model.add(sw2)
            }
            return ("settings-\(tab.rawValue)", overlay(model, behind: behind, top: 64, radius: 16, scrim: 0.18) { SettingsView(tab: tab) }, window)
        }
    }

    // MARK: History & backups

    static func historyViews() -> [(String, AnyView, CGSize)] {
        let id = DemoData.profile().id
        var out: [(String, AnyView, CGSize)] = []
        // #1 selected (the default: #0 only confirmed it), compared with #2, switch diff.
        let history = sampleModel()
        history.selection = .device(id, .history)
        out.append(("history", root(history), window))
        out.append(("history-1280", root(history), CGSize(width: 1280, height: 800)))
        // The current version's full configuration.
        let full = sampleModel()
        full.selection = .device(id, .history)
        full.historyState[id] = HistoryViewState(selected: .commit(0), tab: .full)
        out.append(("history-full", root(full), window))
        // The local backup Netdeck took when the sample opened.
        let backup = sampleModel()
        backup.selection = .device(id, .history)
        backup.historyState[id] = HistoryViewState(filter: .backups, selected: .backup("sample"))
        out.append(("history-backup", root(backup), window))
        // Going back to #2 goes through the review sheet.
        let rollback = sampleModel(staged: false)
        if let s = rollback.session(for: id) {
            out.append(("history-rollback-review", AnyView(ReviewSheet(session: s, isSample: true, timer: 5, showDetails: true, mode: .rollback(index: 2))
                .environment(rollback)), CGSize(width: 800, height: 862)))
        }
        return out
    }

    // MARK: Connecting, connection errors, basic support

    /// A real-looking (non-sample) device with an offline session in the given state. Nothing connects.
    static func deviceModel(_ profile: DeviceProfile, snapshot: SwitchSnapshot? = nil, setup: (DeviceSession) -> Void) -> AppModel {
        let model = AppModel(persists: false)
        var profile = profile
        // The sample profile says "Home"; use the first default location in the rendered language.
        if profile.location == "Home" { profile.location = model.locations.first }
        model.add(profile)
        let session = DeviceSession(profile: profile, snapshot: snapshot ?? DemoData.snapshot())
        if snapshot == nil { session.setOfflineSnapshot(nil) }
        setup(session)
        model.installSession(session, for: profile.id)
        model.selection = .device(profile.id, model.isBasic(profile.id) ? .overview : .ports)
        return model
    }

    static func switchProfile() -> DeviceProfile {
        var p = DemoData.profile()
        p.id = "render-sw-01"
        p.detected = Detection(platform: .juniperJunos, model: "EX4300-48T", osVersion: "21.2R3.8", hostname: "sw-01", kind: .switchDevice)
        return p
    }

    static func marks(upTo fraction: Double, now: Date) -> [DeviceSession.ProgressMark] {
        // Times like a 9600 baud console: open 0.4 s, login 3.1 s, then the read steps.
        let steps: [(String, Double, Double)] = [
            ("Opening connection", 0, 14.0), ("Logging in", 0.05, 13.6), ("Reading device info", 0.1, 10.5),
            ("Reading configuration", 0.2125, 9.8), ("Reading port status", 0.325, 3.9), ("Reading MAC table", 0.4375, 2.6),
        ]
        return steps.filter { $0.1 <= fraction + 0.0001 }.map { DeviceSession.ProgressMark(title: t($0.0), fraction: $0.1, at: now.addingTimeInterval(-$0.2)) }
    }

    static func connectionViews() -> [(String, AnyView, CGSize)] {
        var out: [(String, AnyView, CGSize)] = []
        let now = Date()
        let connecting = deviceModel(switchProfile()) { s in
            s.setOfflinePhase(.connecting(step: t("Reading MAC table"), fraction: 0.4375), marks: marks(upTo: 0.4375, now: now))
        }
        out.append(("connecting", root(connecting), window))
        var recent = DemoData.snapshot()
        recent.takenAt = now.addingTimeInterval(-19 * 3600)
        let lastKnown = deviceModel(switchProfile(), snapshot: recent) { s in
            s.setOfflinePhase(.connecting(step: t("Reading configuration"), fraction: 0.2125), marks: marks(upTo: 0.2125, now: now))
        }
        out.append(("connecting-lastknown", root(lastKnown), window))

        let errors: [(String, ConnectionFailure)] = [
            ("error-password", .wrongPassword),
            ("error-cable", .cableNotFound(path: "/dev/cu.usbserial-1410")),
            ("error-noresponse", .notResponding(seconds: 15)),
            ("error-ssh", .sshUnreachable(detail: "The SSH session ended (exit code 255).\nssh: connect to host 192.0.2.10 port 22: Operation timed out")),
            ("error-dropped", .droppedWhileReading(detail: "The serial connection closed.")),
        ]
        for (name, failure) in errors {
            var profile = switchProfile()
            if case .sshUnreachable = failure { profile.connection = .ssh(host: "192.0.2.10", port: 22) }
            let m = deviceModel(profile) { s in s.setOfflinePhase(.failed("render"), failure: failure) }
            out.append((name, root(m), window))
        }
        // Someone else's uncommitted changes, found while the review sheet checked a change.
        let foreign = deviceModel(switchProfile(), snapshot: DemoData.snapshot()) { s in
            s.setOfflinePhase(.ready)
            s.setOfflineForeignCandidate("""
            [edit interfaces ge-0/0/12]
            -   description PRINTER-2F;
            +   description LAB-PRINTER;
            [edit vlans]
            +   lab {
            +       vlan-id 200;
            +   }
            """)
        }
        out.append(("error-foreign", root(foreign), window))
        out.append(("error-foreign-discard", AnyView(ReviewSheet(session: foreign.session(for: "render-sw-01")!, isSample: false, timer: 5,
                                                                 mode: .discardForeign).environment(foreign)), CGSize(width: 800, height: 760)))

        // Basic support: a MikroTik router Netdeck recognized but can't manage yet.
        var router = DeviceProfile(id: "render-gw-01", name: "gw-01", kind: .router, location: "Home",
                                   connection: .ssh(host: "192.168.88.1", port: 22), username: "admin")
        let found = Detection(platform: .mikrotikRouterOS, model: "RB5009UG+S+", osVersion: "7.16", hostname: "gw-01", kind: .router,
                              uptime: "12d4h3m", serial: "HEX0000001")
        router.detected = found
        let basic = deviceModel(router) { s in s.setOfflinePhase(.unsupported(found)) }
        out.append(("basic", root(basic), window))

        // Faceplates of other models (generic layout from the port list).
        out.append(("faceplate-models", AnyView(
            VStack(spacing: 18) {
                ForEach(Array(DemoData.layoutSamples().enumerated()), id: \.offset) { _, snap in
                    FrontPanelView(model: snap.model, vendor: snap.platform.vendor, hostname: snap.hostname,
                                   ports: PanelBuilder.ports(snapshot: snap, session: nil, colors: VLANColorMap.default(for: snap)))
                }
            }
            .padding(20).background(Theme.stageMid)), CGSize(width: 1100, height: 2900)))

        // Appliances over HTTPS: a Dell server and a Synology NAS.
        for (name, sample, kind, url) in [("appliance-server", DemoData.sampleServer(), DeviceKind.server, "https://192.0.2.30"),
                                          ("appliance-nas", DemoData.sampleNAS(), DeviceKind.storage, "https://192.0.2.20:5001")] {
            let p = DeviceProfile(id: "render-\(name)", name: sample.hostname ?? name, kind: kind, location: "Home",
                                  connection: .api(url: url), username: "netdeck")
            let m = deviceModel(p) { s in s.setOfflineAppliance(sample) }
            m.selection = .device(p.id, .overview)
            out.append((name, root(m), window))
        }
        return out
    }
}

/// `sheet` shadow (§1.5): light black 22% r32 y24 + 8% r3 y2; dark black 60% r40 y30 + a white 8% edge.
private struct SheetShadow: ViewModifier {
    var radius: CGFloat
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.white.opacity(scheme == .dark ? 0.08 : 0), lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0.6 : 0.22), radius: scheme == .dark ? 40 : 32, y: scheme == .dark ? 30 : 24)
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.08), radius: 3, y: 2)
    }
}
