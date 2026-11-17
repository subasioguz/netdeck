import AppKit
import NetdeckCore
import SwiftUI

// MARK: - Form state

/// Everything the Add device sheet holds (§3.10): the form, the connection test and its result.
/// Testing uses the normal session connect path (`DeviceSession.connect`): it reads the device once,
/// and "Add and read" keeps that session, so nothing is read twice.
@MainActor @Observable
final class AddDeviceForm {
    enum Result {
        /// Recognized and fully supported (green card, `07`).
        case full(Detection)
        /// Recognized, not fully supported yet (accent card, `07c`).
        case basic(Detection)
        /// The device is already in the list; the primary button opens it.
        case duplicate(DeviceProfile, Detection)
        case failed(ConnectionFailure)
    }

    /// The new device's ID; the test session and the Keychain entry use it too.
    let deviceID: String
    var kind: DeviceKind = .switchDevice { didSet { if kind != oldValue { kindChanged() } } }
    var connection: ConnectionType = .serial
    var manual = false
    var platform: Platform = .juniperJunos { didSet { if platform != oldValue { familyID = platform.families.first?.id } } }
    var familyID: String? = Platform.juniperJunos.families.first?.id
    var serialPath: String?
    var baud = 9600
    var host = ""
    var sshPort = "22"
    var apiURL = ""
    var username = "root"
    var password = ""
    var showPassword = false
    var location: String?
    /// `/dev/cu.*` paths visible right now (a directory listing; nothing is opened).
    var ports: [String]

    private(set) var testing = false
    var result: Result?
    /// The session the last test opened. Kept connected so adding doesn't read again.
    private(set) var session: DeviceSession?
    private var testTask: Task<Void, Never>?
    /// What the result was tested with; editing any of it drops the result.
    private var testedSignature: String?
    var saveError: String?

    init(location: String? = nil, deviceID: String = UUID().uuidString, ports: [String] = SerialTransport.availablePorts()) {
        self.deviceID = deviceID
        self.location = location
        self.ports = ports
        serialPath = Self.preferredPort(in: ports)
    }

    static func preferredPort(in ports: [String]) -> String? {
        ports.first { $0.contains("usb") || $0.contains("SLAB") }
    }

    // MARK: Derived

    /// Brands offered for the chosen type (`Platform.kinds`), "Other" last.
    var brands: [Platform] {
        Platform.allCases.filter { $0 != .unknown && (kind == .other || $0.kinds.contains(kind)) } + [.unknown]
    }

    var family: PlatformFamily? { platform.families.first { $0.id == familyID } }

    func availability(_ c: ConnectionType) -> ConnectionAvailability { kind.availability(of: c) }

    var connectionValue: DeviceProfile.Connection? {
        guard availability(connection) == .available else { return nil }
        switch connection {
        case .serial:
            guard let serialPath else { return nil }
            return .serial(path: serialPath, baud: baud)
        case .ssh:
            let h = host.trimmingCharacters(in: .whitespaces)
            guard !h.isEmpty, let port = Int(sshPort.trimmingCharacters(in: .whitespaces)), (1...65535).contains(port) else { return nil }
            return .ssh(host: h, port: port)
        case .api:
            let u = apiURL.trimmingCharacters(in: .whitespaces)
            return u.isEmpty ? nil : .api(url: u)
        }
    }

    var trimmedUser: String { username.trimmingCharacters(in: .whitespaces) }
    var isComplete: Bool { connectionValue != nil && !trimmedUser.isEmpty }

    /// Fields a test depends on.
    var signature: String {
        [connection.rawValue, serialPath ?? "", String(baud), host, sshPort, apiURL, username, password,
         manual ? platform.rawValue : "auto"].joined(separator: "|")
    }

    func profile(name: String) -> DeviceProfile? {
        guard let c = connectionValue else { return nil }
        return DeviceProfile(id: deviceID, name: name, kind: kind, platform: manual ? platform : nil, location: location,
                             connection: c, username: trimmedUser)
    }

    /// A step of the running test, for the footer ("Reading configuration").
    var progressStep: String? {
        if case let .connecting(step, _) = session?.phase { return step }
        return nil
    }

    // MARK: Type change

    private func kindChanged() {
        if availability(connection) != .available,
           let first = ConnectionType.allCases.first(where: { availability($0) == .available }) {
            connection = first
        }
        if !brands.contains(platform) { platform = brands.first ?? .unknown }
    }

    // MARK: Testing

    func test(model: AppModel) {
        guard isComplete, !testing, let c = connectionValue, let p = profile(name: model.provisionalName(kind: kind, connection: c)) else { return }
        let old = session
        session = nil
        result = nil
        saveError = nil
        testing = true
        testedSignature = signature
        let password = password.isEmpty ? nil : password
        testTask = Task { [weak self, weak model] in
            if let old { await old.disconnect() }
            guard let self, let model, !Task.isCancelled else { return }
            if let path = p.serialPath, await !model.takeSerial(path, for: p.id) {
                self.testing = false
                return
            }
            let s = DeviceSession(profile: p) { [weak model] updated in model?.update(updated) }
            self.session = s
            await s.connect(password: password)
            guard self.session === s else { return }
            self.testing = false
            self.testTask = nil
            self.result = Self.evaluate(s, model: model)
        }
    }

    private static func evaluate(_ s: DeviceSession, model: AppModel) -> Result? {
        switch s.phase {
        case let .unsupported(found):
            if let d = model.existingDevice(matching: found) { return .duplicate(d, found) }
            return .basic(found)
        case .ready, .working:
            guard let found = s.detection else { return nil }
            if let d = model.existingDevice(matching: found) { return .duplicate(d, found) }
            return found.support == .full ? .full(found) : .basic(found)
        case let .failed(message):
            return .failed(s.failure ?? .other(message))
        case .connecting, .disconnected:
            return nil   // cancelled
        }
    }

    /// Drops the result when the form no longer matches what was tested.
    func formChanged(model: AppModel) {
        guard let testedSignature, testedSignature != signature else { return }
        discardTest(model: model)
    }

    /// Cancels a running test, logs out of a tested session and gives the cable back.
    func discardTest(model: AppModel) {
        testTask?.cancel()
        testTask = nil
        testing = false
        testedSignature = nil
        result = nil
        if let s = session {
            session = nil
            Task { await s.disconnect() }
        }
        model.releaseSerials(of: deviceID)
    }

    // MARK: Adding

    /// Adds the device (or opens the one already in the list). Returns false when nothing happened.
    func commit(model: AppModel) -> Bool {
        saveError = nil
        do {
            switch result {
            case let .duplicate(existing, _):
                discardTest(model: model)
                model.selection = .device(existing.id, model.isBasic(existing.id) ? .overview : .ports)
            case let .full(found), let .basic(found):
                guard let s = session else { return false }
                let name = found.hostname.flatMap { $0.isEmpty ? nil : $0 } ?? s.profile.name
                try model.addTested(s, name: name, location: location, password: password)
                session = nil
            case .failed, nil:
                if testing { discardTest(model: model) }
                if let s = session { session = nil; Task { await s.disconnect() } }
                guard let c = connectionValue, let p = profile(name: model.provisionalName(kind: kind, connection: c)) else { return false }
                try model.addAndRead(p, password: password, renameFromHostname: true)
            }
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }
}

// MARK: - Sheet

/// Add device (§3.10, `07-add-device.png`, `07b`, `07c`). 860 wide; header and footer stay put, the body scrolls.
struct AddDeviceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var form: AddDeviceForm
    @State private var bodyHeight: CGFloat = 560
    @State private var added = false

    init(location: String?) {
        _form = State(initialValue: AddDeviceForm(location: location))
    }

    /// Renders and previews: a prepared form.
    init(form: AddDeviceForm) {
        _form = State(initialValue: form)
    }

    static let width: CGFloat = 860
    private static let headerHeight: CGFloat = 76
    private static let footerHeight: CGFloat = 69

    /// Room for the body: the sheet stays 18 pt inside the window at the top and bottom.
    private var bodyCap: CGFloat {
        max(280, min(model.windowHeight, 900) - 36 - Self.headerHeight - Self.footerHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            header.frame(height: Self.headerHeight, alignment: .top)
            scrollingBody
            footer
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: RenderMode.active)
        .background(Theme.surface)
        .onAppear {
            if form.location == nil, model.groupByLocation { form.location = model.locations.first }
        }
        .onDisappear { if !added { form.discardTest(model: model) } }
        .onChange(of: form.signature) { form.formChanged(model: model) }
        .task(id: form.connection) { await watchPorts() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.primary).frame(width: 40, height: 40)
                .overlay(Image(systemName: "plus").font(.system(size: 18, weight: .medium)).foregroundStyle(Theme.onPrimary))
            VStack(alignment: .leading, spacing: 3) {
                Text(t("Add device")).font(Typo.sheetTitle).tracking(-0.27).foregroundStyle(Theme.text1).frame(height: 24)
                Text(t("Netdeck only reads while adding. Nothing on the device is changed."))
                    .font(Typo.callout).foregroundStyle(Theme.text3).lineLimit(1).frame(height: 18)
            }
            Spacer(minLength: 12)
            // Where the device lands; hidden on first run, when the sidebar shows no locations yet.
            if model.groupByLocation, model.locations.count > 1, !model.devices.isEmpty { locationMenu.padding(.top, 5) }
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .medium)).frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(GhostButtonStyle()).padding(.top, 5)
            .accessibilityLabel(t("Close"))
        }
        .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 12)
    }

    private var locationMenu: some View {
        FieldMenu {
            ForEach(model.locations, id: \.self) { loc in
                Button { form.location = loc } label: {
                    if loc == form.location { Label(loc, systemImage: "checkmark") } else { Text(loc) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.text3)
                Text(form.location ?? model.locations.first ?? "").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text2).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(Theme.text3)
            }
            .padding(.horizontal, 10).frame(height: 26)
            .background(Capsule().fill(Theme.surface2))
            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
        }
        .fixedSize()
        .help(t("Location"))
    }

    // MARK: Body

    @ViewBuilder
    private var scrollingBody: some View {
        if RenderMode.active {
            content.fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: bodyCap, alignment: .top).clipped()
        } else {
            ScrollView(.vertical) {
                content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bodyHeight = $0 }
            }
            .scrollIndicators(.automatic)
            .frame(height: min(bodyHeight, bodyCap))
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            AddField(label: t("What are you adding?")) { typeTiles }
            HStack(alignment: .top, spacing: 12) {
                AddField(label: t("Connection")) { connectionOptions }
                AddField(label: t("Brand and model")) { brandOptions }
            }
            if form.manual { brandPicker }
            details
            resultCard
        }
        .padding(.horizontal, 24).padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Type tiles

    private var typeTiles: some View {
        HStack(spacing: 8) {
            ForEach(DeviceKind.allCases) { kind in
                let on = form.kind == kind
                Button { form.kind = kind } label: {
                    VStack(spacing: 0) {
                        TypeTile(kind: kind, size: 32, dark: on)
                        Text(kind.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text1)
                            .lineLimit(1).minimumScaleFactor(0.85).padding(.top, 7)
                        Text(kind.hint).font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                            .lineLimit(1).minimumScaleFactor(0.8).padding(.top, 6)
                    }
                    .padding(.horizontal, 6).padding(.top, 9).padding(.bottom, 9)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? Theme.surface2 : Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(on ? Theme.text1 : Theme.borderStrong, lineWidth: on ? 1.5 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(kind.hint)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    // MARK: Connection and brand options

    private var connectionOptions: some View {
        VStack(spacing: 6) {
            option(.serial, t("Serial console"), t("USB serial cable to the console port. No network needed."))
            option(.ssh, t("SSH"), t("Over the network, through the management port."))
            option(.api, t("API (HTTPS)"), t("Redfish or REST · iDRAC, Synology, TrueNAS"))
        }
    }

    private func option(_ c: ConnectionType, _ title: String, _ subtitle: String) -> some View {
        let availability = form.availability(c)
        let note: String? = {
            switch availability {
            case .available: return nil
            case .notAvailable: return t("Not available for this type")
            }
        }()
        return AddOptionCard(title: title, subtitle: subtitle, selected: form.connection == c && availability == .available,
                             disabled: availability != .available, note: note) { form.connection = c }
    }

    private var brandOptions: some View {
        VStack(spacing: 6) {
            AddOptionCard(title: t("Detect automatically (recommended)"), subtitle: t("After connecting, Netdeck reads the vendor, model and OS."),
                          selected: !form.manual) { form.manual = false }
            AddOptionCard(title: t("Let me pick the brand and model"), subtitle: t("Choose from a list. Useful if detection fails."),
                          selected: form.manual) { form.manual = true }
        }
    }

    // MARK: Manual brand / family picker (07b)

    private var brandPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t("Brand")).font(Typo.captionStrong).foregroundStyle(Theme.text2)
            TileGrid(items: form.brands, columns: 4) { p in
                PickTile(title: p.brand, subtitle: p.products, support: p.support, selected: form.platform == p) { form.platform = p }
            }
            .padding(.bottom, 4)
            if !form.platform.families.isEmpty {
                (Text(t("%@ family", form.platform.vendor)).foregroundStyle(Theme.text2)
                 + Text(" · " + t("the exact model and OS version are still read after connecting")).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text3))
                    .font(Typo.captionStrong).lineLimit(1)
                TileGrid(items: form.platform.families, columns: 4) { f in
                    PickTile(title: t("%@ series", f.name), subtitle: f.role, support: f.support, selected: form.familyID == f.id) {
                        form.familyID = f.id
                    }
                }
            }
        }
    }

    // MARK: Connection details

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if form.availability(form.connection) != .available {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").font(.system(size: 12.5, weight: .medium))
                    Text(t("Netdeck can't connect to this type of device yet."))
                }
                .font(.system(size: 12)).foregroundStyle(Theme.text3)
            } else {
                switch form.connection {
                case .serial:
                    HStack(alignment: .top, spacing: 12) {
                        AddField(label: t("Port")) { portPicker }
                        AddField(label: t("Speed (baud)")) {
                            Segmented(options: [9600, 19200, 115200].map { ($0, String($0), nil) }, selection: $form.baud, stretch: true)
                        }
                    }
                case .ssh:
                    HStack(alignment: .top, spacing: 12) {
                        AddField(label: t("Address")) { NDTextField(placeholder: "192.168.1.1", text: $form.host) }
                        AddField(label: t("Port")) { NDTextField(placeholder: "22", text: $form.sshPort) }
                    }
                case .api:
                    AddField(label: t("URL")) { NDTextField(placeholder: "https://192.168.1.10", text: $form.apiURL) }
                }
                HStack(alignment: .top, spacing: 12) {
                    AddField(label: t("Username")) { NDTextField(placeholder: "root", text: $form.username) }
                    AddField(label: t("Password")) { PasswordInput(text: $form.password, visible: $form.showPassword) }
                }
                detailsNote
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface2))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    /// The device holding the chosen cable, unless it's this test.
    private var cableOwner: DeviceProfile? {
        guard form.connection == .serial, let path = form.serialPath, let owner = model.serialOwner(path), owner.id != form.deviceID else { return nil }
        return owner
    }

    /// The cable is held by a device waiting for confirmation: testing and adding wait.
    private var cableBlocked: Bool {
        guard form.connection == .serial, let path = form.serialPath else { return false }
        return model.serialBlocker(path) != nil
    }

    @ViewBuilder
    private var detailsNote: some View {
        if let owner = cableOwner {
            let blocked = cableBlocked
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: blocked ? "exclamationmark.triangle" : "info.circle").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(blocked ? Theme.warnInk : Theme.accentInk).padding(.top, 1)
                (Text(t("This serial cable is currently used by %@.", owner.name)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text1)
                 + Text(" ")
                 + Text(blocked ? t("%@ is waiting for confirmation. Finish that first.", owner.name)
                                : t("Testing will end that session first. %@ keeps its staged changes.", owner.name)))
                    .font(.system(size: 12)).foregroundStyle(Theme.text2).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(blocked ? Theme.warnSoft : Theme.accentSoft))
        } else {
            HStack(spacing: 6) {
                Image(systemName: "key").font(.system(size: 12, weight: .medium))
                Text(form.connection == .serial
                     ? t("Stored in the macOS Keychain. It never leaves this Mac. 9600 is the Junos console default.")
                     : t("Stored in the macOS Keychain. It never leaves this Mac."))
                    .lineLimit(1)
            }
            .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
        }
    }

    private var portPicker: some View {
        FieldMenu {
            if form.ports.isEmpty { Text(t("No serial adapters found")) }
            ForEach(form.ports, id: \.self) { path in
                Button { form.serialPath = path } label: {
                    let name = (path as NSString).lastPathComponent
                    let text = model.serialOwner(path).map { "\(name) · \(t("In use by %@", $0.name))" } ?? name
                    if path == form.serialPath { Label(text, systemImage: "checkmark") } else { Text(text) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "cable.connector.horizontal").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text3)
                if let path = form.serialPath {
                    Text((path as NSString).lastPathComponent).font(Typo.body).foregroundStyle(Theme.text1).lineLimit(1).truncationMode(.middle)
                } else {
                    Text(form.ports.isEmpty ? t("No serial adapters found") : t("Choose port")).font(Typo.body).foregroundStyle(Theme.text4).lineLimit(1)
                }
                Spacer(minLength: 6)
                if let path = form.serialPath {
                    if let owner = cableOwner {
                        Pill(text: t("In use by %@", owner.name), kind: .accent, small: true)
                    } else if form.ports.contains(path) {
                        Pill(text: t("Plugged in"), kind: .good, small: true)
                    }
                }
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.text3)
            }
            .padding(.leading, 10).padding(.trailing, 8).frame(height: 32)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.borderStrong, lineWidth: 1))
            .contentShape(Rectangle())
        }
    }

    /// Lists /dev/cu.* every two seconds while the serial details show. Only a directory listing.
    private func watchPorts() async {
        guard !RenderMode.active, form.connection == .serial else { return }
        while !Task.isCancelled {
            let now = SerialTransport.availablePorts()
            if now != form.ports {
                form.ports = now
                if form.serialPath == nil { form.serialPath = AddDeviceForm.preferredPort(in: now) }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    // MARK: Result card

    @ViewBuilder
    private var resultCard: some View {
        switch form.result {
        case let .full(found):
            HStack(alignment: .center, spacing: 14) {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.good).frame(width: 40, height: 40)
                    .overlay(Image(systemName: "checkmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 3) {
                    Text(t("%@ · %@ · recognized as a %@", vendorModel(found), osLine(found),
                           (found.kind ?? form.kind).title.lowercased(with: L10n.locale)))
                        .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.text1)
                    Text(found.platform.isAppliance
                         ? t("Hostname %@ · serial %@ · health, storage and sensors, read only",
                             found.hostname ?? "—", found.serial ?? "—")
                         : t("Hostname %@ · serial %@ · full support: front panel, ports, VLANs, history",
                             found.hostname ?? "—", found.serial ?? form.session?.snapshot?.hardware.serial ?? "—"))
                        .font(Typo.caption).foregroundStyle(Theme.text2)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Pill(text: t("Full support"), kind: .good)
            }
            .resultBox(fill: Theme.goodSoft, line: Theme.goodLine)
        case let .basic(found):
            HStack(alignment: .top, spacing: 14) {
                TypeTile(kind: found.kind ?? form.kind, size: 40, dark: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(t("%@ recognized", vendorModel(found))).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.text1)
                    Text(t("%@ · Netdeck shows basic information for this device", osLine(found)))
                        .font(Typo.caption).foregroundStyle(Theme.text2)
                    HStack(spacing: 8) {
                        miniTile(t("Model"), found.model ?? "—")
                        miniTile(t("OS version"), osLine(found))
                        miniTile(t("Uptime"), found.uptime.map(BasicOverviewScreen.uptime) ?? "—")
                        miniTile(t("Shown as"), t("Info card, no panel"))
                    }
                    .padding(.top, 7)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Pill(text: t("Basic support"), kind: .accent)
            }
            .resultBox(fill: Theme.accentSoft, line: Theme.accent.opacity(0.25))
        case let .duplicate(existing, found):
            HStack(alignment: .center, spacing: 14) {
                TypeTile(kind: existing.kind, size: 40, dark: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(t("This is %@, which is already in your list.", existing.name))
                        .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.text1)
                    Text(found.summary).font(Typo.caption).foregroundStyle(Theme.text2)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if model.groupByLocation, let loc = existing.location ?? model.locations.first {
                    Pill(text: loc, kind: .outline, icon: "folder")
                }
            }
            .resultBox(fill: Theme.surface2, line: Theme.borderStrong)
        case let .failed(failure):
            if let c = form.connectionValue, let p = form.profile(name: model.provisionalName(kind: form.kind, connection: c)) {
                CompactFailureCard(failure: failure, profile: p)
            }
        case nil:
            EmptyView()
        }
    }

    private func miniTile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(Typo.micro).foregroundStyle(Theme.text3).lineLimit(1)
            Text(value).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text1).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: 150, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    /// "Juniper EX4300-48T", "MikroTik RB5009UG+S+".
    private func vendorModel(_ d: Detection) -> String { d.platform.vendor + (d.model.map { " " + $0 } ?? "") }

    /// "Junos 21.2R3.8", "RouterOS 7.16".
    private func osLine(_ d: Detection) -> String { d.osLine ?? d.platform.osName }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button { form.test(model: model) } label: { Label(t("Test connection"), systemImage: "terminal") }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!form.isComplete || form.testing || cableBlocked)
            status
            Spacer(minLength: 12)
            Button(t("Cancel"), action: close).buttonStyle(SecondaryButtonStyle(large: true)).keyboardShortcut(.cancelAction)
            Button(primaryTitle, action: commit).buttonStyle(PrimaryButtonStyle(large: true))
                .keyboardShortcut(.defaultAction)
                .disabled(!primaryEnabled)
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
        .frame(height: Self.footerHeight)
        .background(Theme.surface2)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    @ViewBuilder
    private var status: some View {
        HStack(spacing: 8) {
            if let saveError {
                dot(Theme.danger)
                Text(saveError).foregroundStyle(Theme.dangerInk)
            } else if form.testing {
                if reduceMotion {
                    Image(systemName: "ellipsis.circle").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
                } else {
                    ProgressView().controlSize(.mini)
                }
                Text(t("Testing…")) + Text(form.progressStep.map { " · " + $0 } ?? "").foregroundStyle(Theme.text4)
            } else {
                switch form.result {
                case let .full(found), let .duplicate(_, found):
                    dot(Theme.good)
                    Text(t("Login OK · %@", found.model ?? found.platform.vendor))
                case let .basic(found):
                    dot(Theme.accent)
                    Text(t("Login OK · %@", vendorModel(found)))
                case .failed:
                    dot(Theme.danger)
                    Text(t("Couldn't connect"))
                case nil:
                    Text(t("Not tested yet"))
                }
            }
        }
        .font(Typo.caption).foregroundStyle(Theme.text3).lineLimit(1)
    }

    private var saveError: String? { form.saveError }

    private func dot(_ color: Color) -> some View { Circle().fill(color).frame(width: 7, height: 7) }

    private var primaryTitle: String {
        switch form.result {
        case .duplicate: return t("Open")
        case .basic: return t("Add with basic info")
        default: return t("Add and read")
        }
    }

    private var primaryEnabled: Bool {
        if case .duplicate = form.result { return true }
        return form.isComplete && !form.testing && !cableBlocked
    }

    private func commit() {
        guard primaryEnabled, form.commit(model: model) else { return }
        added = true
        dismiss()
    }

    private func close() {
        form.discardTest(model: model)
        dismiss()
    }
}

// MARK: - Pieces

/// Label + control, `.field` in the mockups.
private struct AddField<Content: View>: View {
    var label: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(Typo.captionStrong).foregroundStyle(Theme.text2).lineLimit(1)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Option card with a radio (`.ao`): 9/11 padding, 11.5 pt subtitle, a pill when the option is off.
private struct AddOptionCard: View {
    var title: String
    var subtitle: String
    var selected: Bool
    var disabled = false
    var note: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Radio(selected: selected).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Typo.bodyStrong).foregroundStyle(Theme.text1).lineLimit(1)
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 6)
                if let note { Pill(text: note, kind: .neutral, small: true) }
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Theme.text1 : Theme.borderStrong, lineWidth: selected ? 1.5 : 1))
            .opacity(disabled ? 0.6 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(subtitle)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Brand or family tile of the manual picker (`.pk`), with its support pill in the corner.
private struct PickTile: View {
    var title: String
    var subtitle: String
    var support: Platform.Support
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top, spacing: 6) {
                    Text(title).font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(support == .full || selected ? Theme.text1 : Theme.text2).lineLimit(1)
                    Spacer(minLength: 4)
                    pill.padding(.top, -1).padding(.trailing, -2)
                }
                Text(subtitle).font(Typo.micro).foregroundStyle(Theme.text3).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Theme.surface2 : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Theme.text1 : Theme.borderStrong, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(support == .planned)
        .opacity(support == .planned ? 0.5 : 1)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var pill: some View {
        switch support {
        case .full: pillText(t("Supported"), .good)
        case .basic: pillText(t("Basic"), .outline)
        case .planned: EmptyView()   // not offered; the tile is disabled
        }
    }

    private func pillText(_ text: String, _ kind: PillKind) -> some View {
        Text(text).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
            .foregroundStyle(kind == .good ? Theme.goodInk : Theme.text2)
            .padding(.horizontal, 6).frame(height: 18)
            .background(Capsule().fill(kind == .good ? Theme.goodSoft : (kind == .neutral ? Theme.surface3 : .clear)))
            .overlay(Capsule().strokeBorder(kind == .good ? Theme.goodLine : (kind == .outline ? Theme.borderStrong : .clear), lineWidth: 1))
            .fixedSize()
    }
}

/// A fixed-column grid built from rows of equal-width cells (renders reliably, unlike lazy grids).
private struct TileGrid<Item: Hashable, Cell: View>: View {
    var items: [Item]
    var columns: Int
    @ViewBuilder var cell: (Item) -> Cell

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(stride(from: 0, to: items.count, by: columns)), id: \.self) { start in
                HStack(spacing: 6) {
                    ForEach(start..<start + columns, id: \.self) { i in
                        if i < items.count { cell(items[i]) } else { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                    }
                }
            }
        }
    }
}

/// Password input with a lock icon and a show/hide eye (`.input` with `.r`).
private struct PasswordInput: View {
    @Binding var text: String
    @Binding var visible: Bool
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text3)
            Group {
                if RenderMode.active {
                    Text(visible ? text : String(repeating: "•", count: text.count)).foregroundStyle(Theme.text1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if visible {
                    TextField("", text: $text).focused($focused)
                } else {
                    SecureField("", text: $text).focused($focused)
                }
            }
            .textFieldStyle(.plain).font(Typo.body)
            Button { visible.toggle() } label: {
                Image(systemName: visible ? "eye.slash" : "eye").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text3)
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 10).padding(.trailing, 6)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(focused ? Theme.accent : Theme.borderStrong, lineWidth: 1))
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.accent.opacity(focused ? 0.22 : 0), lineWidth: 3).padding(-1.5))
    }
}

/// A full-width `Menu` with our own label (`NDMenu` hugs its label). Renders show only the label.
struct FieldMenu<Label: View, Content: View>: View {
    @ViewBuilder var content: () -> Content
    @ViewBuilder var label: () -> Label

    var body: some View {
        if RenderMode.active {
            label()
        } else {
            Menu(content: content, label: label)
                .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain)
        }
    }
}

private extension View {
    func resultBox(fill: Color, line: Color) -> some View {
        padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(line, lineWidth: 1))
    }
}
