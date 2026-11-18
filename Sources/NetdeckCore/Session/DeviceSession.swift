import Foundation
import Observation

/// One connected device as the UI sees it: state, staged edits and the safe apply flow
/// (preview → timed apply → confirm / revert). All device I/O goes through a `DeviceDriver`.
@MainActor
@Observable
public final class DeviceSession {
    public enum Phase: Equatable, Sendable {
        case disconnected
        case connecting(step: String, fraction: Double)
        case ready
        case working(String)
        case failed(String)
        /// Reached the device, but no full driver exists for it yet.
        case unsupported(Detection)
    }

    public struct PendingCommit: Equatable, Sendable {
        public var comment: String
        public var appliedAt: Date
        public var deadline: Date
        public var summary: [String]

        public init(comment: String, appliedAt: Date, deadline: Date, summary: [String]) {
            self.comment = comment
            self.appliedAt = appliedAt
            self.deadline = deadline
            self.summary = summary
        }
    }

    /// A step of the connect/read progress as it happened (for the connecting screen's step times).
    public struct ProgressMark: Equatable, Sendable {
        public var title: String
        public var fraction: Double
        public var at: Date

        public init(title: String, fraction: Double, at: Date) {
            self.title = title
            self.fraction = fraction
            self.at = at
        }
    }

    public private(set) var profile: DeviceProfile
    public private(set) var phase: Phase = .disconnected {
        didSet {
            // UI bookkeeping only: remember when each progress step started.
            guard case let .connecting(step, fraction) = phase else { return }
            if case .connecting = oldValue {} else {
                progressMarks = []
                failure = nil
            }
            progressMarks.append(ProgressMark(title: step, fraction: fraction, at: .now))
        }
    }
    /// Progress steps of the current (or last) connect/read, oldest first.
    public private(set) var progressMarks: [ProgressMark] = []
    /// Why the last connect or read failed, classified for the error cards.
    public private(set) var failure: ConnectionFailure?
    /// When `detection` was last learned from the device.
    public private(set) var detectedAt: Date?
    public private(set) var snapshot: SwitchSnapshot?
    public private(set) var portEdits: [String: PortEdit] = [:] { didSet { persistStaged() } }
    public private(set) var vlanEdits: [VLANEdit] = [] { didSet { persistStaged() } }
    /// Staged rear QSFP+ role changes (EX4300). They run outside the safety timer.
    public private(set) var rearEdits: [RearPortEdit] = [] { didSet { persistStaged() } }
    /// What an HTTPS API device (server BMC, NAS) reported on the last read.
    public private(set) var appliance: ApplianceSnapshot?
    public private(set) var preview: PreviewResult?
    public private(set) var pending: PendingCommit?
    public private(set) var backups: [BackupStore.Backup] = []
    public private(set) var lastError: String?
    /// What the embedded SSH client negotiated with the device (nil over serial, HTTPS or the system ssh).
    public private(set) var sshAlgorithms: SSHAlgorithms?
    /// Set when the switch reports uncommitted candidate changes left by someone else.
    public private(set) var foreignCandidateDiff: String?
    /// Brand/model/OS learned on the last connect.
    public private(set) var detection: Detection?

    /// How the last confirmation trial ended, for the banners (UI state only).
    public enum TrialEnd: Equatable, Sendable {
        case confirmed(at: Date)
        /// The confirm timer ran out and the switch went back on its own; `restaged` edits are staged again.
        case timedOut(deadline: Date, restaged: Int)
    }
    public private(set) var trialEnd: TrialEnd?

    private var driver: (any DeviceDriver)?
    /// Platform of the driver in use, so a parked serial session logs back in with the same driver.
    private var driverPlatform: Platform?
    /// Serial consoles are physical ports anyone can walk up to, so Netdeck logs out after every
    /// operation and logs back in when it needs the switch again. `parked` = logged out on purpose.
    private var parked = false
    private var rememberedPassword: String?
    private var parksAfterUse: Bool { profile.serialPath != nil }
    private let backupStore: BackupStore
    private let stagedStore: StagedEditsStore?
    private let onProfileChange: (DeviceProfile) -> Void
    /// Snapshot and staged edits from just before the running trial, so a timed-out trial can stage them again.
    private var beforeTrial: (snapshot: SwitchSnapshot?, ports: [String: PortEdit], vlans: [VLANEdit])?

    /// `stagedStore` keeps staged edits on disk (§6.1); the edits saved there are restored here.
    public init(profile: DeviceProfile, stagedStore: StagedEditsStore? = StagedEditsStore(),
                onProfileChange: @escaping (DeviceProfile) -> Void = { _ in }) {
        self.profile = profile
        self.backupStore = BackupStore(deviceID: profile.id)
        self.stagedStore = stagedStore
        self.onProfileChange = onProfileChange
        self.backups = (try? backupStore.list()) ?? []
        restoreStaged()
    }

    /// For previews and tests: a session showing a fixed snapshot without a connection. Staged edits
    /// are kept on disk only when a store is given (the sample switch never keeps them).
    public init(profile: DeviceProfile, snapshot: SwitchSnapshot, stagedStore: StagedEditsStore? = nil) {
        self.profile = profile
        self.backupStore = BackupStore(deviceID: profile.id)
        self.stagedStore = stagedStore
        self.onProfileChange = { _ in }
        self.snapshot = snapshot
        self.phase = .ready
        restoreStaged()
        pruneNoOpEdits()
    }

    // MARK: Derived

    public var plan: ChangePlan {
        guard let snapshot else { return ChangePlan(changes: []) }
        let ports = portEdits.values.sorted {
            InterfaceName.sortKey(SwitchSnapshot.slotKey($0.port)).lexicographicallyPrecedes(InterfaceName.sortKey(SwitchSnapshot.slotKey($1.port)))
        }
        return Planner.plan(snapshot: snapshot, ports: ports, vlans: vlanEdits, rear: rearEdits)
    }

    public var pendingChangeCount: Int { plan.changes.count }
    /// Staged changes for badges: the planned count once the device has been read, else the stored edits.
    public var stagedCount: Int { snapshot == nil ? portEdits.count + vlanEdits.count + rearEdits.count : pendingChangeCount }

    /// How the device's platform handles changes (labels, history, timeout note).
    public var changeTraits: ChangeTraits {
        if let snapshot { return snapshot.changeTraits }
        if appliance != nil { return .readOnly }
        return (detection?.platform ?? profile.effectivePlatform ?? DriverFactory.fallbackPlatform(for: profile.connection.type)).changeTraits
    }

    /// The staged role for a rear QSFP+ port, if one is staged.
    public func rearEdit(pic: Int, port: Int) -> RearPortEdit? { rearEdits.first { $0.pic == pic && $0.port == port } }
    public var isConnected: Bool { (driver != nil || parked) && phase != .disconnected }
    public var isBusy: Bool {
        if case .connecting = phase { return true }
        if case .working = phase { return true }
        return false
    }

    public func alias(for mac: String) -> String? { profile.aliases[mac.lowercased()] }

    /// The port as it will look after staged edits (for the inspector and faceplate markers).
    public func edit(for port: String) -> PortEdit? { portEdits[port] }

    // MARK: Connection

    /// Platform to try first: the one the user picked, else the last one detected, else Junos.
    private var preferredPlatform: Platform {
        if let p = profile.platform, p != .unknown { return p }
        if let p = profile.detected?.platform, p != .unknown, DriverFactory.supports(p, over: profile.connection.type) { return p }
        return DriverFactory.fallbackPlatform(for: profile.connection.type)
    }

    public func connect(password: String?) async {
        guard driver == nil, !parked else { await refresh(); return }
        lastError = nil
        phase = .connecting(step: t("Opening connection"), fraction: 0)
        // Junos first, then the platform its prompt suggests (IOS for "switch#"), then the one `show version` names.
        await connect(platform: preferredPlatform, password: password, handoffs: 2)
    }

    /// Logs in with the platform's driver and reads. When the device turns out to be another platform
    /// Netdeck has a driver for, logs out and starts again with that driver (`handoffs` times at most).
    private func connect(platform: Platform, password: String?, handoffs: Int) async {
        var transport: Transport?
        guard let d = DriverFactory.make(platform: platform, profile: profile, password: password, madeTransport: { transport = $0 }) else {
            fail(CLIError.closed(t("Netdeck can't connect to this device over %@.", profile.connection.type.title)))
            return
        }
        do {
            phase = .connecting(step: t("Logging in"), fraction: 0.05)
            try await d.connect(username: profile.username, password: password)
            sshAlgorithms = transport?.sshAlgorithms
            driver = d
            driverPlatform = platform
            rememberedPassword = password
            try await load(reason: "on connect")
            phase = .ready
            await park()
        } catch let CLIError.unrecognizedPrompt(text) {
            await Self.logoutIgnoringCancellation(d)
            driver = nil
            driverPlatform = nil
            guard let found = DeviceDetector.detect(text), found.platform != platform else {
                fail(CLIError.unrecognizedPrompt(text))
                return
            }
            remember(found)
            if handoffs > 0, !Task.isCancelled, DriverFactory.supports(found.platform, over: profile.connection.type) {
                await connect(platform: found.platform, password: password, handoffs: handoffs - 1)
            } else {
                phase = .unsupported(found)
            }
        } catch DriverError.notSupported {
            // The driver reached the device but it isn't one it can manage (e.g. not Cisco after all).
            await Self.logoutIgnoringCancellation(d)
            driver = nil
            driverPlatform = nil
            // A guess from the prompt alone (e.g. "Switch#" taken for IOS) didn't hold: an unknown device.
            let unknown = Detection(platform: .unknown, kind: profile.kind)
            remember(unknown)
            phase = .unsupported(unknown)
        } catch {
            await Self.logoutIgnoringCancellation(d)
            driver = nil
            driverPlatform = nil
            fail(error)
        }
    }

    public func disconnect() async {
        if driver == nil, parked {
            parked = false
            rememberedPassword = nil
            phase = .disconnected
            return
        }
        guard let d = driver else { return }
        phase = .working(t("Logging out"))
        await Self.logoutIgnoringCancellation(d)
        driver = nil
        phase = .disconnected
    }

    private func refreshNow() async {
        guard driver != nil else { return }
        do {
            try await load(reason: "refresh")
            phase = .ready
        } catch { fail(error) }
    }

    private func load(reason: String) async throws {
        guard let d = driver else { throw TransportError.notOpen }
        let reading = try await d.read { step in
            Task { @MainActor in
                self.phase = .connecting(step: step.title, fraction: 0.1 + 0.9 * Double(step.index) / Double(step.total))
            }
        }
        let s: SwitchSnapshot
        switch reading {
        case let .appliance(a):
            appliance = a
            remember(a.detection)
            return
        case let .network(n):
            s = n
        }
        snapshot = s
        remember(Detection(platform: s.platform, model: s.model, osVersion: s.osVersion, hostname: s.hostname,
                           kind: s.kind, serial: s.hardware.serial))
        _ = try? backupStore.save(configText: s.configText, reason: reason)
        backups = (try? backupStore.list()) ?? []
        pruneNoOpEdits()
        if let p = pending, Date() > p.deadline.addingTimeInterval(5) {
            // The switch has rolled back on its own; reflect it.
            pending = nil
            lastError = t("The confirm timer ran out; the switch went back to its previous configuration.")
            restoreAfterTimeout(deadline: p.deadline, snapshotIsFresh: true)
        }
    }


    // MARK: Serial session lifecycle

    /// Logs back in when the session was parked, runs `op`, then logs out again on serial consoles.
    private func withDevice(_ op: () async -> Void) async {
        if driver == nil, parked {
            guard await relogin() else { return }
        }
        await op()
        await park()
    }

    private func relogin() async -> Bool {
        var transport: Transport?
        guard let d = DriverFactory.make(platform: driverPlatform ?? preferredPlatform, profile: profile, password: rememberedPassword,
                                         madeTransport: { transport = $0 }) else {
            return false
        }
        phase = .working(t("Logging in"))
        do {
            try await d.connect(username: profile.username, password: rememberedPassword)
            sshAlgorithms = transport?.sshAlgorithms
            driver = d
            phase = .ready
            return true
        } catch {
            await Self.logoutIgnoringCancellation(d)
            fail(error)
            return false
        }
    }

    /// Ends a serial console session after an operation; the next operation logs in again.
    private func park() async {
        guard parksAfterUse, let d = driver else { return }
        await Self.logoutIgnoringCancellation(d)
        driver = nil
        parked = true
    }

    /// Logout must finish even if the calling task was cancelled, or the console is left half-way
    /// through a login (e.g. at "Password:").
    static func logoutIgnoringCancellation(_ d: any DeviceDriver) async {
        await Task { await d.disconnect() }.value
    }

    public func refresh() async {
        await withDevice { await self.refreshNow() }
    }

    public func runPreview() async {
        await withDevice { await self.runPreviewNow() }
    }

    /// `acknowledgedUntimed` must be true when the plan has commands the timer can't undo (§3.8).
    public func apply(confirmMinutes: Int = 5, note: String? = nil, acknowledgedUntimed: Bool = false) async {
        await withDevice { await self.applyNow(confirmMinutes: confirmMinutes, note: note, acknowledgedUntimed: acknowledgedUntimed) }
    }

    public func confirm() async {
        await withDevice { await self.confirmNow() }
    }

    public func revertNow() async {
        await withDevice { await self.revertNowNow() }
    }

    public func rollback(to index: Int, confirmMinutes: Int = 5) async {
        await withDevice { await self.rollbackNow(to: index, confirmMinutes: confirmMinutes) }
    }

    public func discardForeignCandidate() async {
        await withDevice { await self.discardForeignCandidateNow() }
    }

    /// Sends a server power command, then reads again. The UI calls this only after the user confirmed
    /// the action. Sessions without a device (the samples, renders) do nothing.
    public func power(_ action: ApplianceSnapshot.PowerAction) async {
        guard !isOffline else { return }
        await withDevice { await self.powerNow(action) }
    }

    public func compare(rollback index: Int) async -> String {
        var out = ""
        await withDevice { out = await self.compareNow(rollback: index) }
        return out
    }

    public func compare(rollback older: Int, to newer: Int) async -> String {
        var out = ""
        await withDevice { out = await self.compareNow(rollback: older, to: newer) }
        return out
    }

    // MARK: Staging

    /// Merges an edit into the staged set. Fields left nil keep any earlier staged value.
    public func stage(_ edit: PortEdit) {
        var merged = portEdits[edit.port] ?? PortEdit(port: edit.port)
        if let v = edit.description { merged.description = v }
        if let v = edit.enabled { merged.enabled = v }
        if let v = edit.mode { merged.mode = v }
        if let v = edit.vlans { merged.vlans = v }
        if let v = edit.nativeVlanID { merged.nativeVlanID = v }
        portEdits[edit.port] = merged
        preview = nil
        pruneNoOpEdits()
    }

    public func stage(_ edit: VLANEdit) {
        vlanEdits.append(edit)
        preview = nil
    }

    public func unstage(port: String) {
        portEdits[port] = nil
        preview = nil
    }

    /// Stages a rear QSFP+ role; staging the current role again removes the staged change.
    public func stage(_ edit: RearPortEdit) {
        rearEdits.removeAll { $0.pic == edit.pic && $0.port == edit.port }
        if snapshot?.rearPorts.first(where: { $0.pic == edit.pic && $0.port == edit.port })?.role != edit.role {
            rearEdits.append(edit)
        }
        preview = nil
    }

    public func unstageRear(pic: Int, port: Int) {
        rearEdits.removeAll { $0.pic == pic && $0.port == port }
        preview = nil
    }

    public func unstageVLAN(at index: Int) {
        guard vlanEdits.indices.contains(index) else { return }
        vlanEdits.remove(at: index)
        preview = nil
    }

    public func discardStaged() {
        portEdits = [:]
        vlanEdits = []
        rearEdits = []
        preview = nil
    }

    private func pruneNoOpEdits() {
        guard let snapshot else { return }
        for (port, e) in portEdits where Planner.plan(snapshot: snapshot, ports: [e], vlans: []).isEmpty {
            portEdits[port] = nil
        }
        let rear = rearEdits.filter { e in snapshot.rearPorts.first { $0.pic == e.pic && $0.port == e.port }?.role != e.role }
        if rear != rearEdits { rearEdits = rear }
    }

    /// Writes the staged edits to disk (or removes the file when nothing is staged).
    private func persistStaged() {
        guard let stagedStore else { return }
        let ports = portEdits.values.sorted { $0.port < $1.port }
        try? stagedStore.save(StagedEdits(ports: ports, vlans: vlanEdits, rear: rearEdits), deviceID: profile.id)
    }

    private func restoreStaged() {
        guard let saved = stagedStore?.load(deviceID: profile.id), !saved.isEmpty else { return }
        portEdits = Dictionary(saved.ports.map { ($0.port, $0) }, uniquingKeysWith: { _, last in last })
        vlanEdits = saved.vlans
        rearEdits = saved.rear
    }

    // MARK: Apply flow

    /// Asks the switch for its own diff and a `commit check` without committing anything.
    private func runPreviewNow() async {
        guard let d = driver else { return }
        let p = plan
        guard !p.commands.isEmpty else {
            // Only untimed commands (rear port roles): nothing for the device to check in advance.
            if !p.operationalCommands.isEmpty { preview = PreviewResult(diff: "", checkPassed: true, checkOutput: "") }
            return
        }
        phase = .working(t("The device is checking the changes"))
        do {
            preview = try await d.preview(p)
            foreignCandidateDiff = nil
            phase = .ready
        } catch let DriverError.candidateDirty(diff) {
            foreignCandidateDiff = diff
            phase = .ready
        } catch { fail(error) }
    }

    /// Applies staged changes with a confirm timer. Nothing is final until `confirm()`.
    private func applyNow(confirmMinutes: Int = 5, note: String? = nil, acknowledgedUntimed: Bool = false) async {
        guard let d = driver, let s = snapshot else { return }
        let p = plan
        guard !p.isEmpty, !p.hasUntimedPart || acknowledgedUntimed else { return }
        phase = .working(t("Applying changes"))
        trialEnd = nil
        let comment = Self.commitComment(for: p, note: note)
        do {
            _ = try? backupStore.save(configText: s.configText, reason: "before change")
            if !p.commands.isEmpty {
                let r = try await d.apply(p, confirmMinutes: confirmMinutes, comment: String(comment))
                pending = PendingCommit(comment: String(comment), appliedAt: r.appliedAt, deadline: r.deadline,
                                        summary: p.changes.filter { !$0.outsideTimer }.map { "\($0.subject): \($0.summary)" })
                beforeTrial = (s, portEdits, vlanEdits)
            }
            if !p.operationalCommands.isEmpty {
                phase = .working(t("Changing port roles"))
                try await d.runOperational(p)
            }
            discardStaged()
            try await load(reason: p.commands.isEmpty ? "port roles changed" : "applied, awaiting confirmation")
            phase = .ready
        } catch let DriverError.candidateDirty(diff) {
            foreignCandidateDiff = diff
            phase = .ready
        } catch { fail(error) }
    }

    private func confirmNow() async {
        guard let d = driver, let p = pending else { return }
        phase = .working(t("Confirming the change"))
        do {
            try await d.confirm(comment: p.comment + " (confirmed)")
            pending = nil
            beforeTrial = nil
            trialEnd = .confirmed(at: .now)
            try await load(reason: "confirmed")
            phase = .ready
        } catch { fail(error) }
    }

    private func revertNowNow() async {
        guard let d = driver, let p = pending else { return }
        phase = .working(t("Reverting the change"))
        do {
            try await d.revertPending(expectedComment: p.comment)
            pending = nil
            beforeTrial = nil
            try await load(reason: "reverted")
            phase = .ready
        } catch DriverError.nothingPending {
            pending = nil
            await refresh()
        } catch { fail(error) }
    }

    /// Returns the switch to an older commit; also guarded by the confirm timer.
    private func rollbackNow(to index: Int, confirmMinutes: Int = 5) async {
        guard let d = driver, let s = snapshot else { return }
        phase = .working(t("Rolling back to an earlier version"))
        trialEnd = nil
        let comment = "Netdeck: rollback to \(index)"
        do {
            _ = try? backupStore.save(configText: s.configText, reason: "before rollback")
            let r = try await d.rollback(to: index, confirmMinutes: confirmMinutes, comment: comment)
            pending = PendingCommit(comment: comment, appliedAt: r.appliedAt, deadline: r.deadline,
                                    summary: [t("Rolled back to version %@", String(index))])
            beforeTrial = (s, [:], [])
            try await load(reason: "rolled back, awaiting confirmation")
            phase = .ready
        } catch let DriverError.candidateDirty(diff) {
            foreignCandidateDiff = diff
            phase = .ready
        } catch { fail(error) }
    }

    /// Diff between an older commit and the active config, as printed by the switch.
    private func compareNow(rollback index: Int) async -> String {
        guard let d = driver else { return "" }
        return (try? await d.compare(rollback: index, to: 0)) ?? ""
    }

    /// Diff between two commits (`show system rollback compare older newer`); read-only.
    private func compareNow(rollback older: Int, to newer: Int) async -> String {
        guard let d = driver else { return "" }
        return (try? await d.compare(rollback: older, to: newer)) ?? ""
    }

    private func discardForeignCandidateNow() async {
        guard let d = driver else { return }
        phase = .working(t("Discarding uncommitted changes"))
        do {
            try await d.discardCandidate()
            foreignCandidateDiff = nil
            phase = .ready
        } catch { fail(error) }
    }

    private func powerNow(_ action: ApplianceSnapshot.PowerAction) async {
        guard let d = driver else { return }
        lastError = nil
        phase = .working(t("Sending the power command"))
        do {
            try await d.power(action)
        } catch {
            report(error)
            return
        }
        do {
            try await load(reason: "after power command")
            phase = .ready
        } catch { report(error) }
    }

    public func backupText(_ b: BackupStore.Backup) -> String { (try? backupStore.read(b)) ?? "" }

    // MARK: Trial end (UI state only; nothing here talks to the device)

    /// The confirm timer has run out, so `commit confirmed` has rolled the switch back on its own:
    /// shows the configuration from before the trial again and stages its edits again. Does nothing
    /// before the deadline (plus a 5 s margin) or while an operation runs (a confirm may be on its way).
    @discardableResult
    public func expireTrial(now: Date = .now) -> Bool {
        guard let p = pending, now > p.deadline.addingTimeInterval(5), !isBusy else { return false }
        pending = nil
        restoreAfterTimeout(deadline: p.deadline, snapshotIsFresh: false)
        return true
    }

    /// The banners are done with the last trial's outcome.
    public func clearTrialEnd() { trialEnd = nil }

    /// Edits made during the trial stay staged on top of the restored ones.
    private func restoreAfterTimeout(deadline: Date, snapshotIsFresh: Bool) {
        let before = beforeTrial
        beforeTrial = nil
        var ports = before?.ports ?? [:]
        for (port, e) in portEdits {
            var merged = ports[port] ?? PortEdit(port: port)
            if let v = e.description { merged.description = v }
            if let v = e.enabled { merged.enabled = v }
            if let v = e.mode { merged.mode = v }
            if let v = e.vlans { merged.vlans = v }
            if let v = e.nativeVlanID { merged.nativeVlanID = v }
            ports[port] = merged
        }
        if !snapshotIsFresh, let s = before?.snapshot { snapshot = s }
        portEdits = ports
        vlanEdits = (before?.vlans ?? []) + vlanEdits
        preview = nil
        pruneNoOpEdits()
        let restaged = (before?.ports.keys.filter { portEdits[$0] != nil }.count ?? 0) + (before?.vlans.count ?? 0)
        trialEnd = .timedOut(deadline: deadline, restaged: restaged)
    }

    // MARK: Profile

    public func setAlias(_ name: String?, for mac: String) {
        let key = mac.lowercased()
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            profile.aliases[key] = name
        } else {
            profile.aliases[key] = nil
        }
        onProfileChange(profile)
    }

    /// Name and icon (an SF Symbol name) for a MAC; both stay on this Mac. A nil icon removes it.
    public func setAlias(_ name: String?, icon: String?, for mac: String) {
        let key = mac.lowercased()
        profile.aliasIcons[key] = icon
        setAlias(name, for: key)
    }

    public func aliasIcon(for mac: String) -> String? { profile.aliasIcons[mac.lowercased()] }

    public func clearError() { lastError = nil }

    /// Name and location were changed in the app (rename, drag to another location); keeps this
    /// session's copy in step so a later profile save doesn't bring the old values back.
    public func syncProfile(name: String, location: String?) {
        if profile.name != name { profile.name = name }
        if profile.location != location { profile.location = location }
    }

    /// Changes how Netdeck reaches the device (serial port or speed, user) while no session is open.
    public func updateConnection(_ connection: DeviceProfile.Connection? = nil, username: String? = nil) {
        guard driver == nil, !isBusy else { return }
        parked = false
        rememberedPassword = nil
        if let connection { profile.connection = connection }
        if let username, !username.trimmingCharacters(in: .whitespaces).isEmpty {
            profile.username = username.trimmingCharacters(in: .whitespaces)
        }
        onProfileChange(profile)
    }

    /// Commit comment: the user's note from the review sheet, or the changed subjects.
    public static func commitComment(for plan: ChangePlan, note: String?) -> String {
        let n = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body = n.isEmpty ? plan.changes.map(\.subject).joined(separator: ", ") : n
        return String(("Netdeck: " + body).prefix(70))
    }

    /// True for sessions without a device behind them (the sample switch, previews).
    public var isOffline: Bool { driver == nil && !parked }

    /// Offline sessions only: shows or clears a confirmation countdown without touching a device.
    /// Ignored when a driver is attached, so it can never stand in for a real commit.
    public func setOfflinePending(_ p: PendingCommit?) {
        guard driver == nil else { return }
        pending = p
    }

    /// Offline sessions only (renders, previews): shows a connection state without a device.
    public func setOfflinePhase(_ p: Phase, failure: ConnectionFailure? = nil, marks: [ProgressMark]? = nil) {
        guard driver == nil else { return }
        phase = p
        if let marks { progressMarks = marks }
        self.failure = failure
        if case let .unsupported(found) = p {
            detection = found
            detectedAt = .now
        }
    }

    /// Offline sessions only: replaces (or clears) the shown snapshot.
    public func setOfflineSnapshot(_ s: SwitchSnapshot?) {
        guard driver == nil else { return }
        snapshot = s
    }

    /// Offline sessions only (renders, previews): shows an appliance reading without a device.
    public func setOfflineAppliance(_ a: ApplianceSnapshot?) {
        guard driver == nil else { return }
        appliance = a
        if let a { detection = a.detection; detectedAt = .now; phase = .ready }
    }

    /// Offline sessions only (the sample switch, renders): ends a simulated trial. Confirming shows the
    /// "Changes are permanent" banner; rolling back just clears the timer.
    public func endOfflineTrial(confirmed: Bool) {
        guard driver == nil, pending != nil else { return }
        pending = nil
        trialEnd = confirmed ? .confirmed(at: .now) : nil
    }

    /// Offline sessions only (renders): shows how a trial ended.
    public func setOfflineTrialEnd(_ end: TrialEnd?) {
        guard driver == nil else { return }
        trialEnd = end
    }

    /// Offline sessions only: shows uncommitted changes left by someone else.
    public func setOfflineForeignCandidate(_ diff: String?) {
        guard driver == nil else { return }
        foreignCandidateDiff = diff
    }

    private func remember(_ found: Detection) {
        detection = found
        detectedAt = .now
        guard profile.detected != found else { return }
        profile.detected = found
        if let kind = found.kind, profile.platform == nil { profile.kind = kind }
        onProfileChange(profile)
    }

    /// An operation on an open session failed: shows the message and keeps the session, without
    /// the connection error cards (the device answered).
    private func report(_ error: Error) {
        if error is CancellationError || Task.isCancelled {
            phase = driver == nil ? .disconnected : .ready
            return
        }
        lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        failure = nil
        phase = driver == nil ? .failed(lastError ?? "") : .ready
    }

    private func fail(_ error: Error) {
        if error is CancellationError || Task.isCancelled {
            // Cancelled from the connecting screen: nothing failed.
            phase = driver == nil ? .disconnected : .ready
            return
        }
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        lastError = message
        // Only connect/read failures are classified for the error cards; apply/confirm errors keep `lastError`.
        if case let .connecting(_, f) = phase {
            let elapsed = progressMarks.first.map { Date().timeIntervalSince($0.at) } ?? 0
            failure = ConnectionFailure.classify(error, connection: profile.connection, reading: f >= 0.1, elapsed: elapsed)
        } else {
            failure = nil
        }
        phase = driver == nil ? .failed(message) : .ready
    }
}
