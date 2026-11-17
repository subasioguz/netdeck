import Foundation

/// Cisco IOS / IOS-XE switches (Catalyst) over a text CLI session.
///
/// IOS has no candidate configuration: every command changes the running configuration at once.
/// The safety net is `configure terminal revert timer N` (Configuration Rollback Confirmed Change): the
/// switch archives the running configuration first and puts it back unless `configure confirm` comes in
/// time. The startup configuration is only written (`write memory`) after confirming.
public actor CiscoDriver: DeviceDriver {
    private let cli: CLISession
    private let dialect = CiscoDialect()

    /// Archive the revert timer restores from, set up by Netdeck when the switch has none.
    static let archiveCommands = ["archive", " path flash:netdeck", " maximum 5"]

    public init(transport: Transport) {
        cli = CLISession(transport: transport, dialect: CiscoDialect())
    }

    // MARK: Session

    public func connect(username: String, password: String?) async throws {
        try await cli.login(username: username, password: password)
        let version = try await cli.run("show version")
        guard CiscoParsers.version(version).isIOS else { throw DriverError.notSupported }
        if await cli.isLimited {
            throw DriverError.safetyNetUnavailable(t("Netdeck needs privileged mode on this switch. Log in with a privilege 15 user or give the enable password."))
        }
    }

    public func disconnect() async {
        await cli.logout()
    }

    // MARK: Read

    public func read(progress: @Sendable (LoadStep) -> Void) async throws -> DeviceReading {
        let steps = [
            t("Reading device info"),
            t("Reading hardware and modules"),
            t("Reading configuration"),
            t("Reading port status"),
            t("Reading MAC table"),
            t("Reading LLDP neighbors"),
        ]
        func step(_ i: Int) { progress(LoadStep(index: i, total: steps.count, title: steps[i])) }

        var o = CiscoSnapshotBuilder.Outputs()
        step(0); o.version = try await cli.run("show version")
        step(1); o.inventory = try await cli.run("show inventory", idle: .seconds(30))
        step(2)
        // A large configuration over a 9600 baud console takes minutes.
        o.runningConfig = try await cli.run("show running-config", idle: .seconds(60), timeout: .seconds(900))
        o.vlanBrief = try await cli.run("show vlan brief", idle: .seconds(30))
        o.archive = try await cli.run("show archive")
        step(3); o.interfacesStatus = try await cli.run("show interfaces status", idle: .seconds(30))
        step(4)
        o.macTable = try await cli.run("show mac address-table", idle: .seconds(30))
        if CiscoDialect.isInvalidInput(o.macTable) {
            // IOS 12.1 and earlier spell it with a hyphen.
            o.macTable = try await cli.run("show mac-address-table", idle: .seconds(30))
        }
        step(5); o.lldp = try await cli.run("show lldp neighbors", idle: .seconds(30))
        return .network(CiscoSnapshotBuilder.build(o))
    }

    // MARK: Change

    /// IOS has no candidate configuration to diff or check in advance: the diff is the command list,
    /// and the switch checks each command as it is applied.
    public func preview(_ plan: ChangePlan) async throws -> PreviewResult {
        let archive = try await cli.run("show archive")
        var notes = [t("IOS has no candidate configuration to check in advance. The switch checks each command as it is applied; if one is rejected, or if you don't confirm in time, the revert timer puts the previous configuration back.")]
        if !CiscoParsers.archiveConfigured(archive) {
            notes.append(t("The configuration archive the revert timer needs is not set up yet. Netdeck turns it on first (archive path flash:netdeck), outside the timer; this doesn't affect traffic."))
        }
        return PreviewResult(diff: Self.diff(plan.commands), checkPassed: true, checkOutput: notes.joined(separator: "\n\n"))
    }

    /// Configuration lines of the plan, "+ " in front; mode changes (`exit`) left out.
    static func diff(_ commands: [String]) -> String {
        commands.filter { $0.trimmingCharacters(in: .whitespaces) != "exit" }.map { "+ " + $0 }.joined(separator: "\n")
    }

    public func apply(_ plan: ChangePlan, confirmMinutes: Int, comment: String) async throws -> ApplyResult {
        var transcript: [String] = []
        try await ensureArchive(&transcript)
        // The switch's timer starts with this command; counting from here keeps Netdeck's deadline on the early side.
        let armedAt = Date()
        try await armRevertTimer(minutes: confirmMinutes, &transcript)
        do {
            for c in plan.commands {
                let out = try await cli.run(c, idle: .seconds(30))
                transcript.append(c)
                if !out.isEmpty { transcript.append(out) }
                let errs = dialect.errors(in: out)
                if !errs.isEmpty { throw DriverError.rejected(["\(c)\n  → \(errs.joined(separator: " "))"]) }
            }
            let end = try await cli.run("end")
            transcript.append("end")
            if !end.isEmpty { transcript.append(end) }
        } catch {
            // Something was refused or the session got stuck: put everything back now.
            await revertAfterFailure()
            throw error
        }
        return ApplyResult(output: transcript.joined(separator: "\n"), confirmMinutes: confirmMinutes, appliedAt: armedAt)
    }

    /// `configure confirm` stops the revert timer; only then is the running configuration saved.
    public func confirm(comment: String) async throws {
        var out = try await cli.run("configure confirm", idle: .seconds(60))
        out += try await answerQuestions()
        if Self.saysNothingPending(out) { throw DriverError.nothingPending }
        guard dialect.errors(in: out).isEmpty else { throw DriverError.commitFailed(out) }
        var saved = try await cli.run("write memory", idle: .seconds(120), timeout: .seconds(600))
        saved += try await answerQuestions()
        guard saved.contains("[OK]") || saved.contains("Building configuration"), dialect.errors(in: saved).isEmpty else {
            throw DriverError.commitFailed(saved)
        }
    }

    /// `configure revert now` puts the archived configuration back at once.
    public func revertPending(expectedComment: String) async throws {
        var out = try await cli.run("configure revert now", idle: .seconds(120), timeout: .seconds(600))
        out += try await answerQuestions()
        if Self.saysNothingPending(out) { throw DriverError.nothingPending }
        guard dialect.errors(in: out).isEmpty else { throw DriverError.commitFailed(out) }
    }

    // MARK: Internals

    /// The revert timer restores from the configuration archive, so it must have a path. When it has none,
    /// sets one up in its own configuration session, before and outside the timer (no effect on traffic).
    private func ensureArchive(_ transcript: inout [String]) async throws {
        let shown = try await cli.run("show archive")
        guard !CiscoParsers.archiveConfigured(shown) else { return }
        let failure = t("Netdeck couldn't set up the configuration archive the revert timer needs:")
        let enter = try await cli.run("configure terminal")
        guard await cli.currentPrompt == .configuration else { throw DriverError.safetyNetUnavailable(failure + "\n" + enter) }
        transcript.append("configure terminal")
        for c in Self.archiveCommands {
            let out = try await cli.run(c)
            transcript.append(c)
            if !out.isEmpty { transcript.append(out) }
            let errs = dialect.errors(in: out)
            if !errs.isEmpty {
                _ = try? await cli.run("end")
                throw DriverError.safetyNetUnavailable(failure + "\n" + c + "\n" + errs.joined(separator: "\n"))
            }
        }
        _ = try await cli.run("end")
        transcript.append("end")
        let check = try await cli.run("show archive")
        guard CiscoParsers.archiveConfigured(check) else { throw DriverError.safetyNetUnavailable(failure + "\n" + check) }
    }

    /// Enters configuration mode with the revert timer running. Nothing has changed if this throws.
    private func armRevertTimer(minutes: Int, _ transcript: inout [String]) async throws {
        let c = "configure terminal revert timer \(minutes)"
        let out = try await cli.run(c, idle: .seconds(90))
        transcript.append(c)
        if !out.isEmpty { transcript.append(out) }
        let errs = dialect.errors(in: out)
        let inConfig = await cli.currentPrompt == .configuration
        if errs.isEmpty && (inConfig || out.contains("Rollback Confirmed Change")) { return }

        if inConfig {
            // In configuration mode but with a complaint: leave, and drop the timer if it did start.
            _ = try? await cli.run("end")
            _ = try? await cli.run("configure revert now", idle: .seconds(120))
            _ = try? await answerQuestions()
        }
        if CiscoDialect.isInvalidInput(out) {
            throw DriverError.safetyNetUnavailable(t("This switch's IOS can't undo changes on its own (no revert timer). Netdeck doesn't apply changes without it."))
        }
        throw DriverError.commitFailed(out)
    }

    /// After a refused command or a stuck session during apply: back to privileged mode, then revert now.
    private func revertAfterFailure() async {
        var prompt = await cli.currentPrompt
        if prompt == nil {
            // A log message may sit after the prompt; Enter shows it again.
            _ = try? await cli.run("", idle: .seconds(10))
            prompt = await cli.currentPrompt
        }
        // Never send `end` at the privileged prompt: an unknown word there is taken as a host to telnet to.
        if prompt == .configuration { _ = try? await cli.run("end") }
        _ = try? await cli.run("configure revert now", idle: .seconds(120), timeout: .seconds(600))
        _ = try? await answerQuestions()
    }

    /// Answers a confirmation one of our own commands asked for: Enter for `[confirm]`, "yes" for `[yes/no]`.
    private func answerQuestions() async throws -> String {
        var out = ""
        for answer in ["", "yes"] {
            guard await cli.currentPrompt == .question else { break }
            let reply = try await cli.run(answer, idle: .seconds(120), timeout: .seconds(600))
            out += "\n" + reply
        }
        return out
    }

    /// "%No Rollback Confirmed Change pending" (wording differs a little between releases).
    static func saysNothingPending(_ output: String) -> Bool {
        let l = output.lowercased()
        return l.contains("no rollback confirmed change") || l.contains("no rollback pending") || l.contains("nothing to confirm")
    }
}
