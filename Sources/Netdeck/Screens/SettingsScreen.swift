import AppKit
import NetdeckCore
import SwiftUI

enum SettingsTab: String, CaseIterable, Hashable {
    case general, devices, safety, backups

    var title: String {
        switch self {
        case .general: return t("General")
        case .devices: return t("Devices")
        case .safety: return t("Safety")
        case .backups: return t("Backups")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .devices: return "square.stack.3d.up"
        case .safety: return "checkmark.shield"
        case .backups: return "externaldrive"
        }
    }
}

/// Settings window (§3.14, `11-settings.png`): ⌘,, 700 wide, toolbar tabs. Every value lives in
/// `AppModel` (UserDefaults) and applies at once; a language change re-renders this window too.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: SettingsTab

    init(tab: SettingsTab = .general) {
        _tab = State(initialValue: tab)
    }

    static let width: CGFloat = 700

    var body: some View {
        Group {
            if RenderMode.active {
                RenderedSettingsWindow(tab: tab) { pane(tab) }
            } else {
                TabView(selection: $tab) {
                    ForEach(SettingsTab.allCases, id: \.self) { tab in
                        pane(tab)
                            .tabItem { Label(tab.title, systemImage: tab.symbol) }
                            .tag(tab)
                    }
                }
                .frame(width: Self.width)
                .containerBackground(Theme.surface, for: .window)
            }
        }
        .id(model.localeVersion)
    }

    @ViewBuilder
    private func pane(_ tab: SettingsTab) -> some View {
        Group {
            switch tab {
            case .general: GeneralSettings()
            case .devices: DevicesSettings()
            case .safety: SafetySettings()
            case .backups: BackupSettings()
            }
        }
        .padding(.horizontal, 26).padding(.top, 18).padding(.bottom, 22)
        .frame(width: Self.width, alignment: .top)
        .background(Theme.surface)
    }
}

// MARK: - Layout pieces

/// Label column right-aligned at 170, control column on the right (`.srow`).
private struct SettingsRow<Content: View>: View {
    var label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label).font(Typo.bodyStrong).foregroundStyle(Theme.text1)
                .multilineTextAlignment(.trailing).lineLimit(2)
                .frame(width: 170, alignment: .trailing).padding(.top, 5)
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SettingsHelp: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.text3).lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
    }
}

private struct SettingsDivider: View {
    var body: some View { Rectangle().fill(Theme.border).frame(height: 1) }
}

/// Switch + label on one line (`.tgl`).
private struct SettingsToggle: View {
    @Binding var isOn: Bool
    var label: String
    var locked = false

    var body: some View {
        HStack(spacing: 10) {
            NDSwitch(isOn: $isOn).disabled(locked).opacity(locked ? 0.55 : 1)
                .accessibilityLabel(label)
            Text(label).font(Typo.body).foregroundStyle(Theme.text1)
                .onTapGesture { if !locked { withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() } } }
                .accessibilityHidden(true)
            if locked { Image(systemName: "lock.fill").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.text3) }
        }
        .padding(.top, 4)
    }
}

/// White box with hairline rows (`.locs`).
private struct ListBox<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            SettingsRow(label: t("Language")) {
                Picker("", selection: $model.language) {
                    ForEach(L10n.Language.allCases) { lang in
                        Text(lang == .system ? t("System") : lang.nativeName).tag(lang)
                    }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 240, alignment: .leading)
                SettingsHelp(text: t("System follows your macOS language, currently %@. If that language isn't available, Netdeck uses English. Switch output (commands, diffs, logs) is never translated.",
                                     Self.macOSLanguageName))
                SettingsHelp(text: t("The menu bar updates the next time Netdeck opens."))
            }
            SettingsRow(label: t("Appearance")) {
                Segmented(options: [(AppearanceSetting.system, t("System"), nil), (.light, t("Light"), nil), (.dark, t("Dark"), nil)],
                          selection: $model.appearance)
            }
            SettingsDivider()
            SettingsRow(label: t("Device list")) {
                SettingsToggle(isOn: $model.groupByLocation, label: t("Group devices by location"))
                SettingsHelp(text: t("Turn this off to show one plain Devices list in the sidebar. Locations are only stored on this Mac."))
                LocationsList().padding(.top, 10)
                    .opacity(model.groupByLocation ? 1 : 0.5)
                    .disabled(!model.groupByLocation)
            }
            SettingsDivider()
            SettingsRow(label: t("Notifications")) {
                SettingsToggle(isOn: $model.notifyBeforeTimeout, label: t("Notify me 1 minute before a confirmation timer runs out"))
                SettingsHelp(text: t("The switch rolls back on its own if you don't confirm in time. The notification is only a reminder."))
            }
        }
    }

    /// The first macOS preferred language, named in the UI language ("English", "Türkçe" → "Turkish").
    static var macOSLanguageName: String {
        let code = Locale.preferredLanguages.first.map { Locale(identifier: $0).language.languageCode?.identifier ?? $0 } ?? "en"
        let name = L10n.locale.localizedString(forLanguageCode: code) ?? code
        return name.prefix(1).uppercased(with: L10n.locale) + name.dropFirst()
    }
}

/// Locations: drag to reorder, rename inline, add, delete when empty (§6.8).
private struct LocationsList: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: String?
    @State private var draft = ""
    @State private var hovered: String?
    @State private var dropTarget: String?
    @FocusState private var fieldFocused: Bool

    private static let dragPrefix = "netdeck-location:"

    var body: some View {
        ListBox {
            ForEach(model.locations, id: \.self) { loc in
                row(loc)
                Rectangle().fill(Theme.border).frame(height: 1)
            }
            Button(action: addLocation) {
                HStack(spacing: 10) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: 16)
                    Text(t("Add location")).font(.system(size: 12.5))
                    Spacer()
                }
                .foregroundStyle(Theme.text3)
                .padding(.horizontal, 12).frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func row(_ loc: String) -> some View {
        let count = model.devices(in: loc).count
        let canDelete = count == 0 && model.locations.count > 1
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.text3).frame(width: 16)
            if renaming == loc {
                TextField("", text: $draft).textFieldStyle(.plain).font(.system(size: 12.5, weight: .semibold))
                    .focused($fieldFocused)
                    .onSubmit { commitRename(loc) }
                    .onExitCommand { renaming = nil }
                    .onAppear { fieldFocused = true }
            } else {
                Text(loc.uppercased(with: L10n.locale)).font(.system(size: 12.5, weight: .semibold)).tracking(0.3)
                    .foregroundStyle(Theme.text1).lineLimit(1)
                    .onTapGesture(count: 2) { startRename(loc) }
            }
            Spacer(minLength: 8)
            if hovered == loc && renaming != loc {
                Button { startRename(loc) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.plain).foregroundStyle(Theme.text3).help(t("Rename location"))
                if canDelete {
                    Button { model.deleteLocation(loc) } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundStyle(Theme.dangerInk).help(t("Delete location"))
                }
            }
            Text(count == 1 ? t("%@ device", "1") : t("%@ devices", String(count)))
                .font(.system(size: 12)).foregroundStyle(Theme.text3).monospacedDigit()
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12).frame(height: 36)
        .background(dropTarget == loc ? Theme.accentSoft : .clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? loc : (hovered == loc ? nil : hovered) }
        .contextMenu {
            Button(t("Rename location")) { startRename(loc) }
            Button(t("Delete location"), role: .destructive) { model.deleteLocation(loc) }.disabled(!canDelete)
        }
        .locationDrag(Self.dragPrefix + loc)
        .locationDrop(isTargeted: { dropTarget = $0 ? loc : (dropTarget == loc ? nil : dropTarget) }) { payload in
            guard payload.hasPrefix(Self.dragPrefix) else { return false }
            model.moveLocation(String(payload.dropFirst(Self.dragPrefix.count)), onto: loc)
            return true
        }
    }

    private func startRename(_ loc: String) {
        draft = loc
        renaming = loc
    }

    private func commitRename(_ loc: String) {
        model.renameLocation(loc, to: draft)
        renaming = nil
    }

    private func addLocation() {
        let name = model.nextLocationName()
        model.addLocation(name)
        startRename(name)
    }
}

private extension View {
    /// Drag a location name (Settings list); skipped in renders.
    @ViewBuilder func locationDrag(_ payload: String) -> some View {
        if RenderMode.active { self } else { self.draggable(payload) }
    }

    /// Drop a dragged location onto another row; skipped in renders.
    @ViewBuilder func locationDrop(isTargeted: @escaping (Bool) -> Void, _ action: @escaping (String) -> Bool) -> some View {
        if RenderMode.active {
            self
        } else {
            self.dropDestination(for: String.self) { items, _ in items.first.map(action) ?? false } isTargeted: { isTargeted($0) }
        }
    }
}

// MARK: - Devices

private struct DevicesSettings: View {
    @Environment(AppModel.self) private var model
    @State private var removing: DeviceProfile?
    @AppStorage(DeviceProfile.useSystemSSHKey) private var useSystemSSH = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsRow(label: t("Devices")) {
                ListBox {
                    if model.devices.isEmpty {
                        Text(t("No devices yet")).font(.system(size: 12.5)).foregroundStyle(Theme.text3)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).frame(height: 40)
                    }
                    ForEach(Array(model.devices.enumerated()), id: \.element.id) { i, d in
                        if i > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                        row(d)
                    }
                }
                SettingsHelp(text: t("Device details stay on this Mac. Passwords are kept in the macOS Keychain."))
            }
            // The system ssh can't run inside the App Sandbox, so the choice only exists outside the Mac App Store.
            if !AppPaths.isSandboxed {
                SettingsRow(label: t("SSH")) {
                    SettingsToggle(isOn: $useSystemSSH, label: t("Use the system ssh command (outside the Mac App Store)"))
                    SettingsHelp(text: t("Netdeck has its own SSH client. Turn this on for devices it can't talk to, such as older ones that only offer RSA host keys or older ciphers. Applies to the next connection."))
                }
            }
        }
        .alert(removing.map { t("Remove %@?", $0.name) } ?? "", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
               presenting: removing) { d in
            Button(t("Remove"), role: .destructive) {
                Keychain.deletePassword(for: d.id)
                model.remove(d.id)
            }
            Button(t("Cancel"), role: .cancel) {}
        } message: { _ in
            Text(t("Netdeck forgets this device and its saved password. Nothing changes on the device, and its backups stay in the backup folder."))
        }
    }

    private func row(_ d: DeviceProfile) -> some View {
        let waiting = model.status(of: d.id) == .awaiting
        let model1 = model.session(for: d.id)?.snapshot?.model ?? d.detected?.model ?? d.kind.title
        return HStack(spacing: 10) {
            TypeTile(kind: d.kind, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(d.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text1).lineLimit(1)
                    if model.isSample(d.id) { Pill(text: t("Sample switch"), kind: .accent, small: true) }
                }
                Text("\(model1) · \(d.connectionLabel)").font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if model.groupByLocation, let loc = d.location ?? model.locations.first {
                Text(loc.uppercased(with: L10n.locale)).font(.system(size: 10.5, weight: .semibold)).tracking(0.5)
                    .foregroundStyle(Theme.text3).lineLimit(1)
            }
            NDMenu {
                Button(t("Remove") + "…", role: .destructive) { removing = d }.disabled(waiting)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text3)
                    .frame(width: 26, height: 24).contentShape(Rectangle())
            }
            .help(waiting ? t("%@ is waiting for confirmation. Finish that first.", d.name) : "")
        }
        .padding(.leading, 10).padding(.trailing, 6).frame(height: 48)
    }
}

// MARK: - Safety

private struct SafetySettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            SettingsRow(label: t("Default safety timer")) {
                Segmented(options: [3, 5, 10].map { ($0, t("%@ min", String($0)), nil) }, selection: $model.defaultTimerMinutes)
                SettingsHelp(text: t("The changes run as a %@-minute trial. If you don't confirm, the switch rolls back on its own, even if you lose the connection.",
                                     String(model.defaultTimerMinutes)))
                SettingsHelp(text: t("The review sheet starts with this value; you can change it for each apply."))
            }
            SettingsDivider()
            SettingsRow(label: t("Before applying")) {
                SettingsToggle(isOn: .constant(true), label: t("Always back up before applying"), locked: true)
                SettingsHelp(text: t("Netdeck saves the current configuration before every change. This can't be turned off."))
            }
        }
    }
}

// MARK: - Backups

private struct BackupSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsRow(label: t("Backup folder")) {
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "folder").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text3)
                        Text(displayPath).font(.system(size: 12.5)).foregroundStyle(Theme.text1)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(displayPath)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface2))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                    Button(t("Show in Finder"), action: showInFinder).buttonStyle(SecondaryButtonStyle()).fixedSize()
                }
                SettingsHelp(text: t("One folder per device. Each backup is the configuration as plain text, in set commands."))
            }
        }
    }

    private var displayPath: String {
        guard let url = model.backupsFolder else { return "~/Library/Application Support/Netdeck/backups" }
        // The real home folder: inside the App Sandbox the home directory APIs return the app's container.
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }

    private func showInFinder() {
        guard let url = model.backupsFolder else { return }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Render chrome

/// `ImageRenderer` can't draw the native settings toolbar; renders draw the window like the mockup
/// (`.setwin`): traffic lights, title, icon tabs.
private struct RenderedSettingsWindow<Pane: View>: View {
    var tab: SettingsTab
    @ViewBuilder var pane: () -> Pane

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(tab.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text1)
                HStack(spacing: 8) {
                    ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { c in
                        Circle().fill(Color(hex: UInt32(c))).frame(width: 12, height: 12)
                            .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                    }
                    Spacer()
                }
                .padding(.leading, 14)
            }
            .frame(height: 40)
            HStack(spacing: 4) {
                ForEach(SettingsTab.allCases, id: \.self) { t in
                    let on = t == tab
                    VStack(spacing: 3) {
                        Image(systemName: t.symbol).font(.system(size: 17, weight: .regular)).frame(height: 22)
                        Text(t.title).font(.system(size: 11.5, weight: on ? .semibold : .regular))
                    }
                    .foregroundStyle(on ? Theme.text1 : Theme.text2)
                    .frame(width: 82).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? Theme.surface3 : .clear))
                }
            }
            .padding(.bottom, 10)
            Rectangle().fill(Theme.border).frame(height: 1)
            pane()
        }
        .frame(width: SettingsView.width)
        .background(Theme.surface)
    }
}
