import Foundation

/// HPE Aruba AOS-S / ProCurve switches (2530–5400R) over a text CLI session.
///
/// AOS-S has no candidate configuration and no confirmed commit: every command changes the running
/// configuration at once. The safety net is HPE's own recipe for automatic rollback (16.05 and later):
/// `cfg-backup` saves the running configuration to flash, then a one-shot job runs `cfg-restore` from that
/// copy after N minutes, without a reboot, also when the session is gone. Confirming deletes the job and
/// only then writes the startup configuration. Older firmware is read only.
public actor AOSSDriver: DeviceDriver {
    private let cli: CLISession
    private let dialect = AOSSDialect()

    /// Flash configuration file with the configuration before the change.
    static let backupFile = "netdeck"
    static let restoreAlias = "netdeck-restore"
    static let rollbackJob = "netdeck-rollback"

    private var revision: String?

    public init(transport: Transport) {
        cli = CLISession(transport: transport, dialect: AOSSDialect())
    }

    // MARK: Session

    public func connect(username: String, password: String?) async throws {
        try await cli.login(username: username, password: password)
        let shown = try await cli.run("show version")
        guard AOSSParsers.isAOSS(shown) else { throw DriverError.notSupported }
        revision = AOSSParsers.softwareRevision(shown)
        if await cli.isLimited {
            throw DriverError.safetyNetUnavailable(t("Netdeck needs administrator rights on this switch. Log in as an administrator or manager user."))
        }
    }

    public func disconnect() async {
        await cli.logout()
    }

    // MARK: Read

    public func read(progress: @Sendable (LoadStep) -> Void) async throws -> DeviceReading {
        let steps = [
            t("Reading device info"),
            t("Reading configuration"),
            t("Reading port status"),
            t("Reading MAC table"),
            t("Reading LLDP neighbors"),
        ]
        func step(_ i: Int) { progress(LoadStep(index: i, total: steps.count, title: steps[i])) }

        var o = AOSSSnapshotBuilder.Outputs()
        step(0)
        o.version = try await cli.run("show version")
        o.system = try await cli.run("show system")
        o.modules = try await cli.run("show modules", idle: .seconds(30))
        step(1)
        o.runningConfig = try await cli.run("show running-config", idle: .seconds(60), timeout: .seconds(900))
        o.vlans = try await cli.run("show vlans", idle: .seconds(30))
        step(2); o.interfacesBrief = try await cli.run("show interfaces brief", idle: .seconds(30))
        step(3); o.macTable = try await cli.run("show mac-address", idle: .seconds(30))
        step(4); o.lldp = try await cli.run("show lldp info remote-device", idle: .seconds(30))
        revision = AOSSParsers.softwareRevision(o.system) ?? AOSSParsers.softwareRevision(o.version) ?? revision
        return .network(AOSSSnapshotBuilder.build(o))
    }

    // MARK: Change

    public func preview(_ plan: ChangePlan) async throws -> PreviewResult {
        PreviewResult(diff: Self.diff(plan.commands), checkPassed: true,
                      checkOutput: t("The switch has no candidate configuration to check in advance. It applies each command at once; if one is rejected, or if you don't confirm in time, it restores the configuration it had before the change."))
    }

    static func diff(_ commands: [String]) -> String {
        commands.filter { $0.trimmingCharacters(in: .whitespaces) != "exit" }.map { "+ " + $0 }.joined(separator: "\n")
    }

    /// "[[DD:]HH:]MM" with days and hours: 5 minutes → "00:00:05".
    static func delay(minutes: Int) -> String {
        String(format: "%02d:%02d:%02d", minutes / 1440, (minutes % 1440) / 60, minutes % 60)
    }

    public func apply(_ plan: ChangePlan, confirmMinutes: Int, comment: String) async throws -> ApplyResult {
        guard AOSSState(softwareRevision: revision).canRestoreWithoutReboot else {
            throw DriverError.safetyNetUnavailable(t("This switch's firmware (%@) can't restore a configuration without restarting; that needs 16.05 or later. Netdeck reads it but doesn't change it.",
                                                     revision ?? "?"))
        }
        let minutes = min(max(confirmMinutes, 1), 60)
        var transcript: [String] = []
        try await enterConfig(&transcript)
        if try await pendingJob() != nil {
            await leaveConfig()
            throw DriverError.safetyNetUnavailable(t("Another change is already waiting for confirmation on this switch (Netdeck's restore job is scheduled). Netdeck doesn't apply changes until it ends."))
        }
        try await saveBackup(&transcript)
        let armedAt = Date()
        try await armRollbackJob(minutes: minutes, &transcript)
        do {
            for c in plan.commands { try await runChecked(c, &transcript) }
        } catch {
            await revertAfterFailure()
            throw error
        }
        await leaveConfig()
        return ApplyResult(output: transcript.joined(separator: "\n"), confirmMinutes: minutes, appliedAt: armedAt)
    }

    /// Deletes the rollback job before it runs; only then is the running configuration saved.
    public func confirm(comment: String) async throws {
        var ignored: [String] = []
        try await enterConfig(&ignored)
        guard let job = try await pendingJob(), job.runCount == 0 else {
            // The job has run: the switch is back on the old configuration.
            await leaveConfig()
            throw DriverError.nothingPending
        }
        let out = try await cli.run("no job \"\(Self.rollbackJob)\"")
        guard dialect.errors(in: out).isEmpty else {
            await leaveConfig()
            throw DriverError.commitFailed(out)
        }
        _ = try? await cli.run("no alias \"\(Self.restoreAlias)\"")
        await leaveConfig()
        let saved = try await cli.run("write memory", idle: .seconds(120), timeout: .seconds(600))
        guard dialect.errors(in: saved).isEmpty else { throw DriverError.commitFailed(saved) }
    }

    /// Restores the backup at once (the job and its alias go with it, as the backup predates them).
    public func revertPending(expectedComment: String) async throws {
        var ignored: [String] = []
        try await enterConfig(&ignored)
        guard let job = try await pendingJob(), job.runCount == 0 else {
            await leaveConfig()
            throw DriverError.nothingPending
        }
        let out = try await restoreBackup()
        _ = try? await cli.run("no job \"\(Self.rollbackJob)\"")
        _ = try? await cli.run("no alias \"\(Self.restoreAlias)\"")
        await leaveConfig()
        guard dialect.errors(in: out).isEmpty else { throw DriverError.commitFailed(out) }
    }

    // MARK: Internals

    private func enterConfig(_ transcript: inout [String]) async throws {
        guard await cli.currentPrompt != .configuration else { return }
        let out = try await cli.run("configure terminal")
        transcript.append("configure terminal")
        guard await cli.currentPrompt == .configuration else { throw DriverError.commitFailed(out) }
    }

    /// Back to the manager prompt. `exit` there would log out, so only while in a configuration context.
    private func leaveConfig() async {
        for _ in 0..<3 {
            guard await cli.currentPrompt == .configuration else { return }
            _ = try? await cli.run("exit")
        }
    }

    /// Runs one configuration command. A question it asks is answered "y" only for deleting a VLAN, which
    /// the user chose; any other question is refused and counts as a rejection.
    private func runChecked(_ command: String, _ transcript: inout [String]) async throws {
        var out = try await cli.run(command, idle: .seconds(30))
        transcript.append(command)
        if await cli.currentPrompt == .question {
            let deleting = command.trimmingCharacters(in: .whitespaces).hasPrefix("no vlan ") && !command.contains("tagged")
            out += "\n" + (try await cli.run(deleting ? "y" : "n", idle: .seconds(60)))
            if !deleting {
                if !out.isEmpty { transcript.append(out) }
                throw DriverError.rejected(["\(command)\n  → \(out.trimmingCharacters(in: .whitespacesAndNewlines))"])
            }
        }
        if !out.isEmpty { transcript.append(out) }
        let errs = dialect.errors(in: out)
        if !errs.isEmpty { throw DriverError.rejected(["\(command)\n  → \(errs.joined(separator: " "))"]) }
    }

    /// `cfg-backup running-config config netdeck`, then checks the file is listed.
    private func saveBackup(_ transcript: inout [String]) async throws {
        let c = "cfg-backup running-config config \(Self.backupFile)"
        var out = try await cli.run(c, idle: .seconds(60))
        if await cli.currentPrompt == .question { out += "\n" + (try await cli.run("y", idle: .seconds(60))) }
        transcript.append(c)
        if !out.isEmpty { transcript.append(out) }
        let files = try await cli.run("show config files")
        guard dialect.errors(in: out).isEmpty, Self.listsConfigFile(files, named: Self.backupFile) else {
            await leaveConfig()
            throw DriverError.safetyNetUnavailable(t("Netdeck couldn't save the configuration before the change:") + "\n" + out + "\n" + files)
        }
    }

    /// The alias and the one-shot job that restores the backup, then checks the job is scheduled.
    private func armRollbackJob(minutes: Int, _ transcript: inout [String]) async throws {
        let failure = t("Netdeck couldn't set up the job that restores the configuration:")
        let commands = [
            "alias \"\(Self.restoreAlias)\" \"cfg-restore flash \(Self.backupFile)\"",
            "job \"\(Self.rollbackJob)\" delay \(Self.delay(minutes: minutes)) \"\(Self.restoreAlias)\" count 1",
        ]
        for c in commands {
            let out = try await cli.run(c)
            transcript.append(c)
            if !out.isEmpty { transcript.append(out) }
            if !dialect.errors(in: out).isEmpty {
                _ = try? await cli.run("no job \"\(Self.rollbackJob)\"")
                _ = try? await cli.run("no alias \"\(Self.restoreAlias)\"")
                await leaveConfig()
                throw DriverError.safetyNetUnavailable(failure + "\n" + c + "\n" + out)
            }
        }
        guard let job = try await pendingJob(), job.enabled, job.runCount == 0 else {
            _ = try? await cli.run("no job \"\(Self.rollbackJob)\"")
            _ = try? await cli.run("no alias \"\(Self.restoreAlias)\"")
            await leaveConfig()
            throw DriverError.safetyNetUnavailable(failure + "\n" + (try await cli.run("show job \(Self.rollbackJob)")))
        }
    }

    /// Netdeck's rollback job as `show job <name>` describes it, nil when there is none.
    private func pendingJob() async throws -> (enabled: Bool, runCount: Int)? {
        Self.jobInfo(try await cli.run("show job \(Self.rollbackJob)"))
    }

    /// "Job Status  : Enabled", "Run Count   : 0".
    static func jobInfo(_ text: String) -> (enabled: Bool, runCount: Int)? {
        guard text.contains("Job Name"), text.contains(rollbackJob) else { return nil }
        let status = CiscoParsers.capture(#"Job Status\s*:\s*(\S+)"#, in: text)?.first ?? ""
        let runs = Int(CiscoParsers.capture(#"Run Count\s*:\s*(\d+)"#, in: text)?.first ?? "") ?? 0
        return (enabled: status.lowercased() == "enabled", runCount: runs)
    }

    /// "Configuration files:" table: "  2 |             | netdeck".
    static func listsConfigFile(_ text: String, named name: String) -> Bool {
        text.components(separatedBy: "\n").contains { line in
            line.contains("|") && line.split(separator: "|").last?.trimmingCharacters(in: .whitespaces) == name
        }
    }

    /// `cfg-restore flash netdeck`, answering its "Continue (y/n)?".
    private func restoreBackup() async throws -> String {
        var out = try await cli.run("cfg-restore flash \(Self.backupFile)", idle: .seconds(120), timeout: .seconds(600))
        if await cli.currentPrompt == .question {
            out += "\n" + (try await cli.run("y", idle: .seconds(120), timeout: .seconds(600)))
        }
        return out
    }

    /// After a refused command or a stuck session during apply: restore the backup now and drop the job.
    private func revertAfterFailure() async {
        if await cli.currentPrompt == nil { _ = try? await cli.run("", idle: .seconds(10)) }
        if await cli.currentPrompt == .question { _ = try? await cli.run("n") }
        // Back to the global configuration context (from an interface or VLAN context).
        for _ in 0..<2 {
            guard await cli.currentPrompt == .configuration, !(await cli.promptLine).contains("(config)") else { break }
            _ = try? await cli.run("exit")
        }
        _ = try? await restoreBackup()
        _ = try? await cli.run("no job \"\(Self.rollbackJob)\"")
        _ = try? await cli.run("no alias \"\(Self.restoreAlias)\"")
        await leaveConfig()
    }
}
