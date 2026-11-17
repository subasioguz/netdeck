import AppKit
import NetdeckCore
import SwiftUI

/// Sections of a device screen. Part of the navigation contract: the sidebar nav and the
/// device screen both switch on this.
enum DeviceSection: String, CaseIterable, Hashable {
    case ports, vlans, connected, history, overview

    var title: String {
        switch self {
        case .ports: return t("Ports")
        case .vlans: return t("VLANs")
        case .connected: return t("Connected devices")
        case .history: return t("History & backups")
        case .overview: return t("Overview")
        }
    }
}

enum AppSelection: Hashable {
    case overview
    case device(String, DeviceSection)

    var deviceID: String? { if case let .device(id, _) = self { return id }; return nil }
}

/// Sheets presented over the main window. Everything that would write to a device goes through
/// one of the review modes (§10.14).
enum AppSheet: Identifiable {
    case addDevice(location: String?)
    case review(deviceID: String)
    /// "Go back to this version…": a rollback to commit `index`, reviewed first.
    case rollback(deviceID: String, index: Int)
    /// "Discard these changes…": throwing away someone else's uncommitted candidate, reviewed first.
    case discardForeign(deviceID: String)

    var id: String {
        switch self {
        case let .addDevice(l): return "add-\(l ?? "")"
        case let .review(d): return "review-\(d)"
        case let .rollback(d, i): return "rollback-\(d)-\(i)"
        case let .discardForeign(d): return "discard-\(d)"
        }
    }
}

/// One entry of History & backups: a switch commit (rollback index) or a local backup (its ID).
enum HistoryVersion: Hashable {
    case commit(Int)
    case backup(String)
}

/// Per-device view state of History & backups.
struct HistoryViewState: Equatable {
    enum Filter: Hashable { case all, commits, backups }
    enum Tab: Hashable { case diff, full }
    var filter: Filter = .all
    var selected: HistoryVersion?
    /// Compare from (`nil` = the version before the selected one).
    var base: HistoryVersion?
    /// Compare to (`nil` = the selected version).
    var target: HistoryVersion?
    var tab: Tab = .diff
    /// First index of each collapsed range the user opened.
    var expanded: Set<Int> = []
}

/// Per-device view state of the Ports screen, kept across navigation.
struct PortsViewState: Equatable {
    var selected: String?
    var face: PanelFace = .front
    var mode: PortsMode = .ports
    var list = false
    var rear: RearItem? = .qsfp(0)
    var roomEditing: String?
}

/// Per-device view state of the VLANs screen (`VLANsScreen.Row.id` of the selected room).
struct VLANsViewState: Equatable {
    var selected: String?
}

/// Per-device view state of the Connected devices screen.
struct ConnectedViewState: Equatable {
    var selectedMAC: String?
    var filter: String?              // port name; nil = all ports
    var hideUnnamed = false
    var expanded: Set<String> = []   // ports whose full MAC list is shown
    var search = ""
}

enum AppearanceSetting: String, CaseIterable { case system, light, dark }

@MainActor @Observable
final class AppModel {
    private(set) var devices: [DeviceProfile] = []
    private var sessions: [String: DeviceSession] = [:]
    var selection: AppSelection = .overview
    var sheet: AppSheet?
    var portsState: [String: PortsViewState] = [:]
    var vlansState: [String: VLANsViewState] = [:]
    var connectedState: [String: ConnectedViewState] = [:]
    var historyState: [String: HistoryViewState] = [:]
    /// Switch diffs already fetched, keyed by device, read time and the compared pair.
    var compareCache: [String: String] = [:]
    /// Foreign candidate diffs the user chose to live with ("Continue read-only"), per device.
    var readOnlyAcknowledged: [String: String] = [:]
    /// Bumped on language change so the whole tree re-renders with the new strings.
    private(set) var localeVersion = 0

    var locations: [String] { didSet { defaults.set(locations, forKey: Keys.locations) } }
    var collapsedLocations: Set<String> = []
    var groupByLocation: Bool { didSet { defaults.set(groupByLocation, forKey: Keys.group) } }
    var defaultTimerMinutes: Int { didSet { defaults.set(defaultTimerMinutes, forKey: Keys.timer) } }
    /// Settings → General: a reminder 1 minute before a confirmation timer runs out.
    var notifyBeforeTimeout: Bool { didSet { defaults.set(notifyBeforeTimeout, forKey: Keys.notify) } }
    /// Height of the main window, so sheets can cap themselves to it (Add device).
    var windowHeight: CGFloat = 900
    var language: L10n.Language {
        didSet {
            defaults.set(language.rawValue, forKey: Keys.language)
            L10n.language = language
            localeVersion += 1
        }
    }
    var appearance: AppearanceSetting {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance); applyAppearance() }
    }

    /// `/dev/cu.*` path → device ID currently holding that serial cable (§6.7).
    private(set) var serialOwners: [String: String] = [:]
    private var colorMaps: [String: VLANColorMap] = [:]

    /// Running connect/read per device, so the connecting screen can cancel it.
    private var readTasks: [String: Task<Void, Never>] = [:]
    /// Devices whose open session is being read again (not cancellable, see `canCancelRead`).
    private var refreshing: Set<String> = []
    private let reminders = TrialReminders()
    private let store = DeviceStore()
    private let defaults: UserDefaults
    private let persists: Bool

    private enum Keys {
        static let locations = "netdeck.locations", group = "netdeck.groupByLocation", timer = "netdeck.defaultTimer"
        static let language = "netdeck.language", appearance = "netdeck.appearance", colors = "netdeck.vlanColors."
        static let notify = "netdeck.notifyBeforeTimeout"
    }

    /// `persists: false` gives an in-memory model (renders, previews).
    init(persists: Bool = true, defaults: UserDefaults = .standard) {
        self.persists = persists
        self.defaults = persists ? defaults : UserDefaults(suiteName: "netdeck.ephemeral.\(UUID().uuidString)")!
        let d = self.defaults
        locations = d.stringArray(forKey: Keys.locations) ?? [t("Home"), t("Data center")]
        groupByLocation = d.object(forKey: Keys.group) as? Bool ?? true
        defaultTimerMinutes = d.object(forKey: Keys.timer) as? Int ?? 5
        notifyBeforeTimeout = d.object(forKey: Keys.notify) as? Bool ?? true
        appearance = AppearanceSetting(rawValue: d.string(forKey: Keys.appearance) ?? "") ?? .system
        if persists {
            language = L10n.Language(rawValue: d.string(forKey: Keys.language) ?? "") ?? .system
            L10n.language = language
        } else {
            language = L10n.language   // renders and previews keep the language they were started with
        }
        if persists { devices = store.load() }
    }

    func applyAppearance() {
        switch appearance {
        case .system: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: Devices and sessions

    func device(_ id: String) -> DeviceProfile? { devices.first { $0.id == id } }

    func session(for id: String) -> DeviceSession? {
        if let s = sessions[id] { return s }
        guard let p = device(id) else { return nil }
        // Staged edits are kept on disk and restored here (§6.1); never for the sample switch or renders.
        let s: DeviceSession = Self.isSample(p)
            ? DeviceSession(profile: p, snapshot: DemoData.snapshot())
            : DeviceSession(profile: p, stagedStore: persists ? StagedEditsStore() : nil) { [weak self] updated in self?.update(updated) }
        sessions[id] = s
        return s
    }

    /// Renders and previews: shows a prepared offline session for a device.
    func installSession(_ s: DeviceSession, for id: String) { sessions[id] = s }

    /// Basic support (§3.11): the device was recognized but Netdeck has no driver for it.
    func isBasic(_ id: String) -> Bool {
        guard let d = device(id), !isAppliance(id) else { return false }
        let s = sessions[id]
        if case .unsupported = s?.phase { return true }
        // A recognized model whose family isn't fully supported (Juniper SRX, MX, QFX).
        if let found = s?.detection ?? d.detected, found.support != .full { return true }
        if s?.snapshot != nil { return false }
        if let p = d.effectivePlatform { return p.support != .full }
        return false
    }

    /// A server BMC or NAS reached over HTTPS: shown as an information screen (Overview only).
    func isAppliance(_ id: String) -> Bool {
        guard let d = device(id) else { return false }
        if sessions[id]?.appliance != nil { return true }
        if case .api = d.connection { return true }
        return false
    }

    static func isSample(_ p: DeviceProfile) -> Bool { p.id.hasPrefix("demo-") }
    func isSample(_ id: String) -> Bool { device(id).map(Self.isSample) ?? false }

    func add(_ profile: DeviceProfile) {
        devices.removeAll { $0.id == profile.id }
        devices.append(profile)
        if let l = profile.location, !locations.contains(l) { locations.append(l) }
        save()
    }

    func update(_ profile: DeviceProfile) {
        guard let i = devices.firstIndex(where: { $0.id == profile.id }) else { return }
        devices[i] = profile
        sessions[profile.id]?.syncProfile(name: profile.name, location: profile.location)
        save()
    }

    func remove(_ id: String) {
        devices.removeAll { $0.id == id }
        sessions[id] = nil
        if persists { StagedEditsStore().remove(deviceID: id) }
        serialOwners = serialOwners.filter { $0.value != id }
        if selection.deviceID == id { selection = .overview }
        save()
    }

    /// First-run "Try with a sample switch": an offline session over `DemoData`, nothing is ever sent.
    func addSampleDevice() {
        var p = DemoData.profile()
        p.location = locations.first
        add(p)
        selection = .device(p.id, .ports)
    }

    private func save() {
        guard persists else { return }
        // The sample switch lives in memory only.
        try? store.save(devices.filter { !Self.isSample($0) })
    }

    func move(_ deviceID: String, to location: String) {
        guard var p = device(deviceID) else { return }
        p.location = location
        update(p)
    }

    // MARK: Locations (stored on this Mac only, §6.8)

    func devices(in location: String) -> [DeviceProfile] {
        devices.filter { ($0.location ?? locations.first) == location }
    }

    func addLocation(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !locations.contains(n) else { return }
        locations.append(n)
    }

    func renameLocation(_ old: String, to new: String) {
        let n = new.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, let i = locations.firstIndex(of: old), !locations.contains(n) else { return }
        locations[i] = n
        for d in devices where d.location == old { move(d.id, to: n) }
    }

    func deleteLocation(_ name: String) {
        guard devices(in: name).isEmpty else { return }
        locations.removeAll { $0 == name }
    }

    /// Settings → locations list: `name` dropped onto `target` takes its place (after it when moving
    /// down, before it when moving up).
    func moveLocation(_ name: String, onto target: String) {
        guard name != target, let from = locations.firstIndex(of: name), locations.contains(target) else { return }
        var l = locations
        l.remove(at: from)
        let to = l.firstIndex(of: target) ?? l.endIndex
        l.insert(name, at: from <= to ? to + 1 : to)
        locations = l
    }

    func nextLocationName() -> String {
        var i = locations.count + 1
        while locations.contains(t("Location %@", String(i))) { i += 1 }
        return t("Location %@", String(i))
    }

    // MARK: VLAN colors (per device, UserDefaults, never written to the switch)

    func colors(for deviceID: String) -> VLANColorMap {
        if let m = colorMaps[deviceID] { return m }
        guard let snap = sessions[deviceID]?.snapshot else { return VLANColorMap(indexByName: ["default": -1]) }
        let saved = defaults.dictionary(forKey: Keys.colors + deviceID) as? [String: Int] ?? [:]
        let map = VLANColorMap.default(for: snap, existing: saved)
        colorMaps[deviceID] = map
        if map.indexByName != saved { defaults.set(map.indexByName, forKey: Keys.colors + deviceID) }
        return map
    }

    func setColor(_ index: Int, vlan: String, deviceID: String) {
        var map = colors(for: deviceID)
        map.indexByName[vlan] = index
        colorMaps[deviceID] = map
        defaults.set(map.indexByName, forKey: Keys.colors + deviceID)
    }

    // MARK: Serial cables (one session per /dev/cu.*)

    /// USB serial adapters visible right now (directory listing only; nothing is opened).
    var detectedSerialPorts: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names.filter { $0.hasPrefix("cu.usbserial") || $0.hasPrefix("cu.usbmodem") || $0.hasPrefix("cu.SLAB") }
            .map { "/dev/" + $0 }.sorted()
    }

    /// Adapters to show: detected ones plus the ones devices are configured for.
    var serialCables: [String] {
        Array(Set(detectedSerialPorts + devices.compactMap(\.serialPath))).sorted()
    }

    func serialOwner(_ path: String) -> DeviceProfile? {
        if let id = serialOwners[path] { return device(id) }
        // The sample switch is shown as holding its (fictional) cable while it is open.
        return devices.first { Self.isSample($0) && $0.serialPath == path && sessions[$0.id] != nil }
    }

    /// Takes the cable for `deviceID`; returns false while another device on it awaits confirmation.
    @discardableResult
    func claimSerial(_ path: String, for deviceID: String) -> Bool {
        if let owner = serialOwners[path], owner != deviceID {
            guard sessions[owner]?.pending == nil else { return false }
            Task { await sessions[owner]?.disconnect() }
        }
        serialOwners[path] = deviceID
        return true
    }

    /// Takes the cable for `deviceID` and waits until its previous session has logged out, so the
    /// port is free when the caller opens it. False while that device awaits confirmation.
    func takeSerial(_ path: String, for deviceID: String) async -> Bool {
        if let owner = serialOwners[path], owner != deviceID {
            guard sessions[owner]?.pending == nil else { return false }
            serialOwners[path] = deviceID
            await sessions[owner]?.disconnect()
            return true
        }
        serialOwners[path] = deviceID
        return true
    }

    /// Gives back every cable `deviceID` holds without ending anything (a cancelled add-device test).
    func releaseSerials(of deviceID: String) {
        serialOwners = serialOwners.filter { $0.value != deviceID }
    }

    /// The device that holds `path` and is waiting for confirmation (the cable can't be taken now).
    func serialBlocker(_ path: String) -> DeviceProfile? {
        guard let owner = serialOwner(path), sessions[owner.id]?.pending != nil else { return nil }
        return owner
    }

    func canEndSession(on path: String) -> Bool {
        guard let owner = serialOwner(path) else { return false }
        return sessions[owner.id]?.pending == nil
    }

    func endSession(on path: String) {
        guard let owner = serialOwner(path), canEndSession(on: path) else { return }
        serialOwners[path] = nil
        if let s = sessions[owner.id], !s.isOffline { Task { await s.disconnect() } }
    }

    // MARK: Adding devices (§3.10)

    /// A device already in the list that is the one just found: same serial number, or same
    /// platform, model and hostname. The sample switch never counts.
    func existingDevice(matching found: Detection) -> DeviceProfile? {
        let real = devices.filter { !Self.isSample($0) }
        if let serial = found.serial, !serial.isEmpty,
           let d = real.first(where: { ($0.detected?.serial ?? sessions[$0.id]?.snapshot?.hardware.serial) == serial }) {
            return d
        }
        guard let host = found.hostname, !host.isEmpty else { return nil }
        return real.first { d in
            guard let known = d.detected ?? sessions[d.id]?.detection else { return false }
            return known.platform == found.platform && known.hostname == host && known.model == found.model
        }
    }

    /// Name for a device added before Netdeck read its hostname: "Switch", "Switch 2"…, or the SSH host.
    func provisionalName(kind: DeviceKind, connection: DeviceProfile.Connection) -> String {
        switch connection {
        case let .ssh(host, _): return host
        case let .api(url): return URL(string: url)?.host ?? url
        case .serial:
            let names = Set(devices.map(\.name))
            var name = kind.title, i = 2
            while names.contains(name) { name = "\(kind.title) \(i)"; i += 1 }
            return name
        }
    }

    /// Add device after a successful test: the tested session (already read) becomes the device's session.
    func addTested(_ session: DeviceSession, name: String, location: String?, password: String) throws {
        if !password.isEmpty { try Keychain.setPassword(password, for: session.profile.id) }
        var p = session.profile
        p.name = name
        p.location = location
        session.syncProfile(name: name, location: location)
        add(p)
        sessions[p.id] = session
        if let path = p.serialPath { serialOwners[path] = p.id }
        selection = .device(p.id, isBasic(p.id) || isAppliance(p.id) ? .overview : .ports)
    }

    /// Add device without a (successful) test: saves it, opens it and reads it once. When the name is
    /// provisional, the hostname the device reports replaces it.
    func addAndRead(_ profile: DeviceProfile, password: String, renameFromHostname: Bool) throws {
        if !password.isEmpty { try Keychain.setPassword(password, for: profile.id) }
        add(profile)
        selection = .device(profile.id, isAppliance(profile.id) ? .overview : .ports)
        guard let s = session(for: profile.id) else { return }
        let id = profile.id
        readTasks[id] = Task { [weak self] in
            // Wait for the cable's previous session to log out before opening the port.
            if let path = profile.serialPath, let self, await !self.takeSerial(path, for: id) { return }
            await s.connect(password: password.isEmpty ? nil : password)
            guard let self else { return }
            self.readTasks[id] = nil
            if renameFromHostname, let host = s.detection?.hostname, !host.isEmpty, var p = self.device(id), p.name == profile.name {
                p.name = host
                self.update(p)
            }
            if self.isBasic(id), self.selection == .device(id, .ports) { self.selection = .device(id, .overview) }
        }
    }

    /// Settings → Backups: where `BackupStore` keeps one folder per device.
    var backupsFolder: URL? { try? AppPaths.supportDirectory().appendingPathComponent("backups", isDirectory: true) }

    // MARK: Status and pending confirmations

    func status(of id: String) -> DeviceStatus {
        guard let s = sessions[id] else { return .offline }
        if s.pending != nil { return .awaiting }
        switch s.phase {
        case .connecting: return .connecting
        case .failed: return .failed
        case .ready, .working: return .connected
        case .unsupported: return .basic
        case .disconnected: return .offline
        }
    }

    struct Waiting: Identifiable {
        let device: DeviceProfile
        let session: DeviceSession
        let pending: DeviceSession.PendingCommit
        var id: String { device.id }
    }

    /// Every device waiting for confirmation, soonest deadline first.
    var waiting: [Waiting] {
        devices.compactMap { d in
            guard let s = sessions[d.id], let p = s.pending else { return nil }
            return Waiting(device: d, session: s, pending: p)
        }.sorted { $0.pending.deadline < $1.pending.deadline }
    }

    func openSessions() -> [DeviceSession] { devices.compactMap { sessions[$0.id] } }

    func readAllAgain() {
        for s in openSessions() where !s.isOffline && !s.isBusy { Task { await s.refresh() } }
    }

    // MARK: Connecting and reading (§3.12)

    /// Connects (or reconnects) and reads. The password comes from the Keychain unless given.
    /// Never retries on its own: a wrong password must not lock the account.
    func connect(_ id: String, password: String? = nil) {
        guard let d = device(id), !Self.isSample(d), let s = session(for: id), !s.isBusy else { return }
        if let path = s.profile.serialPath, !claimSerial(path, for: id) { return }
        let pw = password ?? Keychain.password(for: id)
        readTasks[id] = Task { [weak self] in
            await s.connect(password: pw)
            self?.readTasks[id] = nil
        }
    }

    /// "Read again": refreshes an open session, or connects when none is open.
    func read(_ id: String) {
        guard let s = session(for: id), !isSample(id), !s.isBusy else { return }
        guard s.isConnected else { connect(id); return }
        refreshing.insert(id)
        readTasks[id] = Task { [weak self] in
            await s.refresh()
            self?.readTasks[id] = nil
            self?.refreshing.remove(id)
        }
    }

    /// A read can be cancelled while it connects. A re-read of an open session can't: stopping it
    /// mid-command would leave the command's output arriving on the session that stays open, and the
    /// next command would be paired with the wrong output.
    func canCancelRead(_ id: String) -> Bool { !refreshing.contains(id) }

    /// Cancel on the connecting screen. The session logs out and keeps what it had.
    func cancelRead(_ id: String) {
        guard canCancelRead(id) else { return }
        readTasks[id]?.cancel()
        readTasks[id] = nil
    }

    /// Saves a new password to the Keychain and connects once with it.
    func saveAndConnect(_ id: String, password: String) throws {
        try Keychain.setPassword(password, for: id)
        connect(id, password: password)
    }

    /// Confirm / roll back from a banner. The sample switch only clears its simulated timer.
    func confirm(_ id: String) {
        guard let s = sessions[id] else { return }
        if s.isOffline { s.endOfflineTrial(confirmed: true) } else { Task { await s.confirm() } }
    }

    func rollBack(_ id: String) {
        guard let s = sessions[id] else { return }
        if s.isOffline { s.endOfflineTrial(confirmed: false) } else { Task { await s.revertNow() } }
    }

    // MARK: Confirmation timers (§3.9)

    /// Devices whose last trial ended and whose banner is still showing (green for 3 s, grey until closed).
    var trialEnds: [(device: DeviceProfile, session: DeviceSession, end: DeviceSession.TrialEnd)] {
        devices.compactMap { d in
            guard let s = sessions[d.id], s.pending == nil, let e = s.trialEnd else { return nil }
            return (d, s, e)
        }
    }

    /// Changes whenever a timer starts or ends, a green banner appears or the reminder setting flips;
    /// `TrialClock` restarts `runTrialClock()` on every change.
    var trialClockKey: [String] {
        var key: [String] = devices.compactMap { d in
            guard let s = sessions[d.id] else { return nil }
            var parts: [String] = []
            if let p = s.pending { parts.append("p\(p.deadline.timeIntervalSince1970)") }
            if case let .confirmed(at) = s.trialEnd { parts.append("c\(at.timeIntervalSince1970)") }
            return parts.isEmpty ? nil : d.id + ":" + parts.joined(separator: ",")
        }
        key.append(notifyBeforeTimeout ? "notify" : "quiet")
        return key
    }

    /// Keeps the reminders in step with the running timers, notices timers that ran out (the switch has
    /// rolled itself back) and retires the green "Changes are permanent" banner after 3 s. Local state
    /// only: it never sends anything to a device. Sleeps until the next moment something is due.
    func runTrialClock() async {
        reminders.sync(waiting.map { (id: $0.id, name: $0.device.name, deadline: $0.pending.deadline) }, enabled: notifyBeforeTimeout)
        while !Task.isCancelled {
            let now = Date()
            var next: Date?
            func due(_ d: Date) { next = min(next ?? d, d) }
            for d in devices {
                guard let s = sessions[d.id] else { continue }
                if let p = s.pending {
                    let end = p.deadline.addingTimeInterval(5)
                    if now < end { due(end) } else if !s.expireTrial(now: now) { due(now.addingTimeInterval(1)) }   // busy: look again shortly
                }
                if case let .confirmed(at) = s.trialEnd {
                    let end = at.addingTimeInterval(3)
                    if now < end { due(end) } else { s.clearTrialEnd() }
                }
            }
            guard let next else { return }
            try? await Task.sleep(for: .seconds(max(0.05, next.timeIntervalSince(now))))
        }
    }
}
