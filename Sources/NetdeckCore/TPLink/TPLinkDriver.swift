import Foundation

/// TP-Link Omada / JetStream managed switches over a text CLI session (SSH or console).
///
/// The switch has no candidate configuration, no confirmed commit and no rollback timer: every command
/// changes the running configuration at once. The device-side safety net is a restart: before the first
/// command Netdeck schedules `reboot-schedule in N` without saving, so an unconfirmed change (or one that cut
/// Netdeck off) ends with the switch restarting on its saved configuration, offline for a few minutes.
/// Confirming cancels the restart and only then saves (`copy running-config startup-config`).
///
/// A restart would also drop anyone else's unsaved changes, so Netdeck only applies when the running and
/// startup configurations match. That also makes the startup configuration the "before" state: a rejected
/// command or "undo now" puts the old settings back with commands and cancels the restart once the two match
/// again; only when that fails does the switch restart within a minute.
public actor TPLinkDriver: DeviceDriver {
    private let cli: CLISession
    private let dialect = TPLinkDialect()
    private var controllerManaged = false

    public init(transport: Transport) {
        cli = CLISession(transport: transport, dialect: TPLinkDialect())
    }

    // MARK: Session

    public func connect(username: String, password: String?) async throws {
        try await cli.login(username: username, password: password)
        let info = try await cli.run("show system-info")
        guard TPLinkParsers.isTPLink(info) else { throw DriverError.notSupported }
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

        var o = TPLinkSnapshotBuilder.Outputs()
        step(0); o.systemInfo = try await cli.run("show system-info")
        step(1)
        o.runningConfig = try await runningConfig()
        o.vlans = try await cli.run("show vlan brief", idle: .seconds(30))
        if TPLinkDialect.isBadCommand(o.vlans) { o.vlans = try await cli.run("show vlan", idle: .seconds(30)) }
        step(2); o.interfaceStatus = try await cli.run("show interface status", idle: .seconds(30))
        step(3)
        o.macTable = try await cli.run("show mac address-table", idle: .seconds(30))
        if TPLinkDialect.isBadCommand(o.macTable) { o.macTable = try await cli.run("show mac address-table all", idle: .seconds(30)) }
        step(4)
        o.lldp = try await cli.run("show lldp neighbor-information", idle: .seconds(30))
        if TPLinkDialect.isBadCommand(o.lldp) { o.lldp = "" }
        let snapshot = TPLinkSnapshotBuilder.build(o)
        if case let .tplink(state) = snapshot.vendor { controllerManaged = state.controllerManaged }
        return .network(snapshot)
    }

    // MARK: Change

    public func preview(_ plan: ChangePlan) async throws -> PreviewResult {
        PreviewResult(diff: Self.diff(plan.commands), checkPassed: true,
                      checkOutput: t("The switch has no candidate configuration to check in advance. It applies each command at once and saves nothing until you confirm. If a command is rejected, Netdeck puts the previous settings back; if you don't confirm in time, the switch restarts with its saved configuration."))
    }

    static func diff(_ commands: [String]) -> String {
        commands.filter { $0.trimmingCharacters(in: .whitespaces) != "exit" }.map { "+ " + $0 }.joined(separator: "\n")
    }

    public func apply(_ plan: ChangePlan, confirmMinutes: Int, comment: String) async throws -> ApplyResult {
        let minutes = min(max(confirmMinutes, 1), 60)
        var transcript: [String] = []
        try await requireSaved()
        try await enterConfig(&transcript)
        try await armRestart(minutes: minutes, &transcript)
        let armedAt = Date()
        var applied = 0
        do {
            for c in plan.commands {
                try await runChecked(c, &transcript)
                applied += 1
            }
        } catch let DriverError.rejected(lines) {
            // A refused first command changed nothing; otherwise the earlier ones are undone.
            let restarting = await undo(changed: applied > 0, &transcript)
            throw DriverError.rejected(restarting ? lines + [Self.restartingNote] : lines)
        } catch {
            // The session is stuck or gone: the scheduled restart undoes the change.
            throw error
        }
        await leaveConfig()
        return ApplyResult(output: transcript.joined(separator: "\n"), confirmMinutes: minutes, appliedAt: armedAt)
    }

    /// Cancels the scheduled restart, then saves the running configuration.
    public func confirm(comment: String) async throws {
        await leaveConfig()
        guard try await hasUnsavedChange() else { throw DriverError.nothingPending }
        var ignored: [String] = []
        try await enterConfig(&ignored)
        let out = try await cli.run("reboot-schedule cancel")
        await leaveConfig()
        guard dialect.errors(in: out).isEmpty else { throw DriverError.commitFailed(out) }
        var saved = try await cli.run("copy running-config startup-config", idle: .seconds(120), timeout: .seconds(600))
        if await cli.currentPrompt == .question { saved += "\n" + (try await cli.run("Y", idle: .seconds(120), timeout: .seconds(600))) }
        guard dialect.errors(in: saved).isEmpty else { throw DriverError.commitFailed(saved) }
    }

    /// Puts the saved configuration's settings back now, without a restart when the commands get it there.
    public func revertPending(expectedComment: String) async throws {
        await leaveConfig()
        guard try await hasUnsavedChange() else { throw DriverError.nothingPending }
        var transcript: [String] = []
        if await undo(changed: true, &transcript) {
            throw DriverError.safetyNetUnavailable(Self.restartingNote)
        }
    }

    static var restartingNote: String {
        t("Netdeck couldn't put every setting back by itself. The switch restarts with its saved configuration within a minute and is offline for a few minutes.")
    }

    // MARK: Internals

    private func runningConfig() async throws -> String {
        try await cli.run("show running-config", idle: .seconds(60), timeout: .seconds(900))
    }

    private func startupConfig() async throws -> String {
        try await cli.run("show startup-config", idle: .seconds(60), timeout: .seconds(900))
    }

    /// Nothing unsaved, and not managed by a controller.
    private func requireSaved() async throws {
        await leaveConfig()
        let running = try await runningConfig()
        if controllerManaged || TPLinkParsers.runningConfig(running).controllerManaged {
            throw DriverError.safetyNetUnavailable(t("An Omada controller manages this switch, and it only takes show commands. Netdeck reads it but doesn't change it; make changes in the controller."))
        }
        let startup = try await startupConfig()
        guard TPLinkParsers.sameConfiguration(running, startup) else {
            throw DriverError.safetyNetUnavailable(t("This switch has changes that aren't saved yet. Netdeck's safety net restarts the switch with its saved configuration, which would lose them too. Save or undo them on the switch first."))
        }
    }

    private func hasUnsavedChange() async throws -> Bool {
        !TPLinkParsers.sameConfiguration(try await runningConfig(), try await startupConfig())
    }

    private func enterConfig(_ transcript: inout [String]) async throws {
        guard await cli.currentPrompt != .configuration else { return }
        let out = try await cli.run("configure")
        transcript.append("configure")
        guard await cli.currentPrompt == .configuration else {
            if out.contains("controller mode") {
                throw DriverError.safetyNetUnavailable(t("An Omada controller manages this switch, and it only takes show commands. Netdeck reads it but doesn't change it; make changes in the controller."))
            }
            throw DriverError.commitFailed(out)
        }
    }

    /// Back to the privileged prompt (`end` works from any configuration context).
    private func leaveConfig() async {
        if await cli.currentPrompt == .question { _ = try? await cli.run("N") }
        guard await cli.currentPrompt == .configuration else { return }
        _ = try? await cli.run("end")
    }

    /// `reboot-schedule in N` (no `save_before_reboot`), answering its "Continue? (Y/N)".
    private func armRestart(minutes: Int, _ transcript: inout [String]) async throws {
        let c = "reboot-schedule in \(minutes)"
        var out = try await cli.run(c)
        if await cli.currentPrompt == .question { out += "\n" + (try await cli.run("Y")) }
        transcript.append(c)
        if !out.isEmpty { transcript.append(out) }
        guard dialect.errors(in: out).isEmpty, await cli.currentPrompt == .configuration else {
            _ = try? await cli.run("reboot-schedule cancel")
            await leaveConfig()
            throw DriverError.safetyNetUnavailable(t("Netdeck couldn't schedule the restart that undoes the change:") + "\n" + c + "\n" + out)
        }
    }

    /// Runs one configuration command (sent without the indentation the plan shows). A question is answered
    /// "Y" only for deleting a VLAN, which the user chose; any other question is refused and counts as a
    /// rejection.
    private func runChecked(_ command: String, _ transcript: inout [String]) async throws {
        let c = command.trimmingCharacters(in: .whitespaces)
        var out = try await cli.run(c, idle: .seconds(30))
        transcript.append(c)
        if await cli.currentPrompt == .question {
            let deleting = c.hasPrefix("no vlan ")
            out += "\n" + (try await cli.run(deleting ? "Y" : "N", idle: .seconds(60)))
            if !deleting {
                if !out.isEmpty { transcript.append(out) }
                throw DriverError.rejected(["\(c)\n  → \(out.trimmingCharacters(in: .whitespacesAndNewlines))"])
            }
        }
        if !out.isEmpty { transcript.append(out) }
        let errs = dialect.errors(in: out)
        if !errs.isEmpty { throw DriverError.rejected(["\(c)\n  → \(errs.joined(separator: " "))"]) }
    }

    /// Takes the running configuration back to the startup one with commands, then cancels the scheduled
    /// restart once they match. When they don't, the restart is brought forward to one minute. Returns
    /// whether the switch is going to restart.
    private func undo(changed: Bool, _ transcript: inout [String]) async -> Bool {
        if await cli.currentPrompt == nil { _ = try? await cli.run("", idle: .seconds(10)) }
        await leaveConfig()
        var restored = !changed
        if changed, let running = try? await runningConfig(), let startup = try? await startupConfig() {
            let commands = TPLinkPlanner.restore(from: TPLinkParsers.runningConfig(running), to: TPLinkParsers.runningConfig(startup))
            if (try? await enterConfig(&transcript)) != nil {
                for c in commands {
                    let line = c.trimmingCharacters(in: .whitespaces)
                    if let out = try? await cli.run(line, idle: .seconds(30)) {
                        transcript.append(line)
                        if !out.isEmpty { transcript.append(out) }
                    }
                    if await cli.currentPrompt == .question { _ = try? await cli.run(line.hasPrefix("no vlan ") ? "Y" : "N") }
                }
            }
            await leaveConfig()
            if let now = try? await runningConfig(), let saved = try? await startupConfig() {
                restored = TPLinkParsers.sameConfiguration(now, saved)
            }
        }
        guard (try? await enterConfig(&transcript)) != nil else { return true }
        if restored {
            let out = (try? await cli.run("reboot-schedule cancel")) ?? ""
            await leaveConfig()
            return !dialect.errors(in: out).isEmpty
        }
        _ = try? await cli.run("reboot-schedule in 1")
        if await cli.currentPrompt == .question { _ = try? await cli.run("Y") }
        await leaveConfig()
        return true
    }
}
