import Foundation

/// HPE Aruba AOS-CX switches (6000–10000 series) over a text CLI session.
///
/// AOS-CX has no candidate configuration: every command changes the running configuration at once. The
/// safety net is `checkpoint auto N`: the switch keeps a copy of the running configuration and puts it
/// back after N minutes unless `checkpoint auto confirm` comes first, also when the session is gone.
/// Netdeck also saves its own checkpoint first, so it can put the old configuration back at once
/// (`checkpoint rollback`). The startup configuration is only written (`write memory`) after confirming.
public actor AOSCXDriver: DeviceDriver {
    private let cli: CLISession
    private let dialect = AOSCXDialect()

    /// Netdeck's own copy of the configuration before a change.
    static let beforeCheckpoint = "netdeck-before-change"
    /// Before 10.06 the auto checkpoint could fail to restore when the session dropped first.
    static func isSafeRelease(_ r: (major: Int, minor: Int)) -> Bool {
        r.major > 10 || (r.major == 10 && r.minor >= 6)
    }

    private var version: String?

    public init(transport: Transport) {
        cli = CLISession(transport: transport, dialect: AOSCXDialect())
    }

    // MARK: Session

    public func connect(username: String, password: String?) async throws {
        try await cli.login(username: username, password: password)
        let shown = try await cli.run("show version")
        guard AOSCXParsers.isAOSCX(shown) else { throw DriverError.notSupported }
        version = AOSCXParsers.osVersion(shown)
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

        var o = AOSCXSnapshotBuilder.Outputs()
        step(0)
        o.version = try await cli.run("show version")
        o.system = try await cli.run("show system")
        step(1)
        o.runningConfig = try await cli.run("show running-config", idle: .seconds(60), timeout: .seconds(900))
        o.vlans = try await cli.run("show vlan", idle: .seconds(30))
        step(2); o.interfaceBrief = try await cli.run("show interface brief", idle: .seconds(30))
        step(3); o.macTable = try await cli.run("show mac-address-table", idle: .seconds(30))
        step(4); o.lldp = try await cli.run("show lldp neighbor-info", idle: .seconds(30))
        version = AOSCXParsers.osVersion(o.version) ?? version
        return .network(AOSCXSnapshotBuilder.build(o))
    }

    // MARK: Change

    /// No candidate configuration to diff or check in advance: the diff is the command list.
    public func preview(_ plan: ChangePlan) async throws -> PreviewResult {
        PreviewResult(diff: Self.diff(plan.commands), checkPassed: true,
                      checkOutput: t("The switch has no candidate configuration to check in advance. It applies each command at once; if one is rejected, or if you don't confirm in time, it restores the configuration it had before the change."))
    }

    /// Configuration lines of the plan, "+ " in front; `exit` left out.
    static func diff(_ commands: [String]) -> String {
        commands.filter { $0.trimmingCharacters(in: .whitespaces) != "exit" }.map { "+ " + $0 }.joined(separator: "\n")
    }

    public func apply(_ plan: ChangePlan, confirmMinutes: Int, comment: String) async throws -> ApplyResult {
        if let version, let r = AOSCXParsers.release(version), !Self.isSafeRelease(r) {
            throw DriverError.safetyNetUnavailable(t("AOS-CX %@ may not restore the configuration if the session drops before you confirm (fixed in 10.06). Update the switch to make changes with Netdeck.", version))
        }
        let minutes = min(max(confirmMinutes, 1), 60)
        var transcript: [String] = []
        try await saveBeforeCheckpoint(&transcript)
        // The switch's timer starts with this command; counting from here keeps Netdeck's deadline on the early side.
        let armedAt = Date()
        try await armAutoCheckpoint(minutes: minutes, &transcript)
        do {
            try await runChecked("configure terminal", &transcript)
            for c in plan.commands { try await runChecked(c, &transcript) }
            try await runChecked("end", &transcript)
        } catch {
            // Something was refused or the session got stuck: put everything back now.
            await revertAfterFailure()
            throw error
        }
        return ApplyResult(output: transcript.joined(separator: "\n"), confirmMinutes: minutes, appliedAt: armedAt)
    }

    /// `checkpoint auto confirm` stops the timer; only then is the running configuration saved.
    public func confirm(comment: String) async throws {
        let out = try await cli.run("checkpoint auto confirm", idle: .seconds(60))
        if Self.saysNotInAutoMode(out) { throw DriverError.nothingPending }
        guard dialect.errors(in: out).isEmpty else { throw DriverError.commitFailed(out) }
        let saved = try await cli.run("write memory", idle: .seconds(120), timeout: .seconds(600))
        guard dialect.errors(in: saved).isEmpty else { throw DriverError.commitFailed(saved) }
        _ = try? await cli.run("erase checkpoint \(Self.beforeCheckpoint)")
        _ = try? await answerQuestion()
    }

    /// Puts Netdeck's checkpoint back at once, then ends the auto checkpoint mode (the configuration it
    /// keeps is the old one again).
    public func revertPending(expectedComment: String) async throws {
        let rollback = try await cli.run("checkpoint rollback \(Self.beforeCheckpoint)", idle: .seconds(120), timeout: .seconds(600))
        guard dialect.errors(in: rollback).isEmpty else { throw DriverError.commitFailed(rollback) }
        let out = try await cli.run("checkpoint auto confirm", idle: .seconds(60))
        // The timer had already run out and restored the same configuration.
        if Self.saysNotInAutoMode(out) { throw DriverError.nothingPending }
        guard dialect.errors(in: out).isEmpty else { throw DriverError.commitFailed(out) }
        _ = try? await cli.run("erase checkpoint \(Self.beforeCheckpoint)")
        _ = try? await answerQuestion()
    }

    // MARK: Internals

    private func runChecked(_ command: String, _ transcript: inout [String]) async throws {
        let out = try await cli.run(command, idle: .seconds(30))
        transcript.append(command)
        if !out.isEmpty { transcript.append(out) }
        let errs = dialect.errors(in: out)
        if !errs.isEmpty { throw DriverError.rejected(["\(command)\n  → \(errs.joined(separator: " "))"]) }
    }

    /// Netdeck's own checkpoint of the configuration before the change, replacing an older one.
    private func saveBeforeCheckpoint(_ transcript: inout [String]) async throws {
        _ = try await cli.run("erase checkpoint \(Self.beforeCheckpoint)")
        _ = try await answerQuestion()
        let c = "copy running-config checkpoint \(Self.beforeCheckpoint)"
        let out = try await cli.run(c, idle: .seconds(60))
        transcript.append(c)
        if !out.isEmpty { transcript.append(out) }
        guard dialect.errors(in: out).isEmpty else {
            throw DriverError.safetyNetUnavailable(t("Netdeck couldn't save the configuration before the change:") + "\n" + out)
        }
    }

    /// Starts the auto checkpoint. Nothing has changed if this throws.
    private func armAutoCheckpoint(minutes: Int, _ transcript: inout [String]) async throws {
        let c = "checkpoint auto \(minutes)"
        let out = try await cli.run(c, idle: .seconds(60))
        transcript.append(c)
        if !out.isEmpty { transcript.append(out) }
        if out.lowercased().contains("expires in") && dialect.errors(in: out).isEmpty { return }
        if out.lowercased().contains("already on") {
            throw DriverError.safetyNetUnavailable(t("Another change is already waiting for confirmation on this switch (an auto checkpoint is running). Netdeck doesn't apply changes until it ends."))
        }
        if AOSCXDialect.isInvalidInput(out) {
            throw DriverError.safetyNetUnavailable(t("This switch can't undo changes on its own (no auto checkpoint). Netdeck doesn't apply changes without it."))
        }
        throw DriverError.commitFailed(out)
    }

    /// After a refused command or a stuck session during apply: back to the manager prompt, put the old
    /// configuration back and end the auto checkpoint.
    private func revertAfterFailure() async {
        var prompt = await cli.currentPrompt
        if prompt == nil {
            _ = try? await cli.run("", idle: .seconds(10))
            prompt = await cli.currentPrompt
        }
        if prompt == .configuration { _ = try? await cli.run("end") }
        _ = try? await cli.run("checkpoint rollback \(Self.beforeCheckpoint)", idle: .seconds(120), timeout: .seconds(600))
        _ = try? await cli.run("checkpoint auto confirm", idle: .seconds(60))
        _ = try? await cli.run("erase checkpoint \(Self.beforeCheckpoint)")
        _ = try? await answerQuestion()
    }

    /// Answers "y" when one of our own commands asks to confirm (erasing our checkpoint).
    private func answerQuestion() async throws -> String {
        guard await cli.currentPrompt == .question else { return "" }
        return try await cli.run("y", idle: .seconds(60))
    }

    /// The switch is not in auto checkpoint mode (wording varies between releases).
    static func saysNotInAutoMode(_ output: String) -> Bool {
        let l = output.lowercased()
        return (l.contains("not") && (l.contains("auto checkpoint") || l.contains("checkpoint auto") || l.contains("auto mode")))
            || l.contains("no auto checkpoint")
    }
}
