import Foundation

public struct MoleVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let suffix: String
    public var isStable: Bool { suffix.isEmpty }
    public var description: String { "\(major).\(minor).\(patch)\(suffix)" }
    public init(major: Int, minor: Int, patch: Int, suffix: String = "") {
        self.major = major; self.minor = minor; self.patch = patch; self.suffix = suffix
    }
    public init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(?:[vV])?(\d+)\.(\d+)\.(\d+)([-+][A-Za-z0-9._-]+)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let r1 = Range(match.range(at: 1), in: trimmed),
              let r2 = Range(match.range(at: 2), in: trimmed),
              let r3 = Range(match.range(at: 3), in: trimmed),
              let major = Int(trimmed[r1]), let minor = Int(trimmed[r2]), let patch = Int(trimmed[r3]) else { return nil }
        let suffix = Range(match.range(at: 4), in: trimmed).map { String(trimmed[$0]) } ?? ""
        self.init(major: major, minor: minor, patch: patch, suffix: suffix)
    }
    public static func parseVersionOutput(_ output: String) -> MoleVersion? {
        let clean = TerminalText.plain(output)
        for line in clean.components(separatedBy: .newlines) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("Mole version ") else { continue }
            return MoleVersion(string: String(text.dropFirst("Mole version ".count)))
        }
        return nil
    }
    public static func < (lhs: MoleVersion, rhs: MoleVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.suffix.isEmpty != rhs.suffix.isEmpty { return !lhs.suffix.isEmpty }
        return lhs.suffix < rhs.suffix
    }
}

public enum CompatibilityLevel: String, Sendable { case baselineInterface, compatibleInterface, blocked }
public enum MoleReleaseChannel: String, Sendable { case stable, nightly, development, homebrewHEAD, unrecognized }
public enum StableUpdateSource: Equatable, Sendable { case unverified, officialScript, homebrew }

public struct CommandCompatibility: Sendable {
    public let command: MoleCommand
    public let available: Bool
    public let missingFlags: [String]
    public let jsonValidated: Bool
    public let reason: String?
}

public struct CompatibilityReport: Sendable {
    public let version: MoleVersion?
    public let level: CompatibilityLevel
    public let channel: MoleReleaseChannel
    public let commands: [MoleCommand: CommandCompatibility]
    public let reason: String
    public var isBaseline: Bool { level == .baselineInterface }
    public var allowsDestructive: Bool { level != .blocked }
    public var stableScriptRecoveryAvailable: Bool {
        guard channel == .nightly || channel == .development,
              let version, version.isStable, version.major == MoleCompatibility.auditedVersion.major,
              version >= MoleCompatibility.auditedVersion else { return false }
        return commands[.update]?.available == true
    }

    public func validate(_ invocation: MoleInvocation, updateSource: StableUpdateSource = .unverified) throws {
        // Help/version are the probes used to establish compatibility itself.
        if invocation.command == .help || invocation.command == .version || invocation.arguments.contains("--help") { return }
        guard let state = commands[invocation.command], state.available else {
            throw MoleError.incompatible(commands[invocation.command]?.reason ?? "The command interface has not been verified.")
        }
        if invocation.isDestructive, !allowsDestructive {
            // The audited script updater explicitly switches nightly/dev receipts
            // to a published stable tag. This exception does not enable cleanup,
            // another nightly update, an unknown source, or a new-major engine.
            if updateSource == .officialScript, stableScriptRecoveryAvailable,
               invocation.command == .update,
               invocation.arguments.first == "update",
               invocation.arguments.dropFirst().allSatisfy({ ["--force", "--debug"].contains($0) }) { return }
            if invocation.command == .update, channel == .homebrewHEAD {
                throw MoleError.incompatible("Homebrew HEAD requires a Homebrew channel change. Mole's updater only runs brew upgrade mole, which retains the installed build options; it is not a stable-channel recovery command.")
            }
            throw MoleError.incompatible(reason)
        }
        // Fresh output is always decoded before presentation. These cached flags
        // describe previous successful probes; absence does not authorize parsing
        // an unstructured fallback as JSON or authorizing a deletion from it.
    }
}

public enum MoleCompatibility {
    public static let auditedVersion = MoleVersion(major: 1, minor: 62, patch: 0)
    public static let auditedCommit = "91a7bf44f96995361b10b5a0e9efae36a1490bf9"

    /// Negotiate capabilities instead of requiring one fixed executable version.
    /// A future stable 1.x engine can run its own retained PTY confirmations when
    /// the relevant documented command interface still matches. This is not a
    /// claim that future engine implementations have been audited or tested.
    public static func assess(versionOutput: String, mainHelp: String,
                              helps: [MoleCommand: String],
                              validatedJSON: Set<MoleCommand> = [],
                              installationChannel: String? = nil) -> CompatibilityReport {
        let version = MoleVersion.parseVersionOutput(versionOutput)
        let root = TerminalText.plain(mainHelp)
        let identityOK = root.contains("Mole") && root.contains("clean") && root.contains("uninstall")
        let versionText = TerminalText.plain(versionOutput)
        let channel: MoleReleaseChannel
        if versionText.contains("Homebrew (HEAD ") { channel = .homebrewHEAD }
        else if installationChannel == "nightly" || versionText.localizedCaseInsensitiveContains("Channel: Nightly") { channel = .nightly }
        else if installationChannel == "dev" { channel = .development }
        else if version?.isStable == true { channel = .stable }
        else { channel = .unrecognized }
        let versionOK = channel == .stable && (version.map { $0.isStable && $0.major == auditedVersion.major && $0 >= auditedVersion } ?? false)
        let level: CompatibilityLevel
        if !identityOK || !versionOK { level = .blocked }
        else if version == auditedVersion { level = .baselineInterface }
        else { level = .compatibleInterface }
        let reason: String
        if !identityOK { reason = "Executable did not expose the expected Mole help identity." }
        else if version == nil { reason = "Mole version could not be parsed; destructive operations are disabled." }
        else if channel == .nightly || channel == .development {
            reason = "Nightly/development engine mutations are disabled. A verified official script installation with a compatible same-major update interface may return to stable through mo update without --nightly."
        }
        else if channel == .homebrewHEAD { reason = "Homebrew HEAD engine mutations are disabled. Mole's updater preserves Homebrew's installed build options and cannot be treated as a stable-channel switch." }
        else if !versionOK { reason = "Older, unrecognized, or new-major Mole versions need a compatibility-profile update; destructive operations are disabled." }
        else if level == .baselineInterface { reason = "V1.62.0 public interfaces match the source-audited baseline. Runtime and hardware verification are reported separately." }
        else { reason = "Newer stable Mole 1.x detected. Available commands match the verified public flags; engine behavior has not been re-audited. Official confirmation remains required." }
        var states: [MoleCommand: CommandCompatibility] = [:]
        for command in MoleCommand.allCases {
            let text = TerminalText.plain(helps[command] ?? "")
            let flags = TerminalText.optionNames(text)
            let missing = command.requiredHelpFlags.subtracting(flags).sorted()
            let available: Bool
            if command == .help || command == .version { available = true }
            else if command == .menu { available = level != .blocked && MoleCommand.allCases.filter { $0 != .menu && $0 != .help && $0 != .version }.allSatisfy { helps[$0] != nil } }
            else { available = identityOK && !text.isEmpty && missing.isEmpty && root.contains(command.rawValue) }
            states[command] = CommandCompatibility(command: command, available: available,
                missingFlags: missing, jsonValidated: validatedJSON.contains(command),
                reason: available ? nil : "\(command.rawValue) help is missing or its flags changed: \(missing.joined(separator: ", ")).")
        }
        let menuAvailable = level != .blocked && MoleCommand.allCases
            .filter { $0 != .menu && $0 != .help && $0 != .version }
            .allSatisfy { states[$0]?.available == true }
        states[.menu] = CommandCompatibility(command: .menu, available: menuAvailable, missingFlags: [], jsonValidated: false,
            reason: menuAvailable ? nil : "The unrestricted menu is unavailable while any command contract is incompatible.")
        return CompatibilityReport(version: version, level: level, channel: channel, commands: states, reason: reason)
    }
}

/// Text filtering is for display/probing only, never for a deletion plan.
public enum TerminalText {
    public static func plain(_ text: String) -> String {
        var value = text
        for pattern in [#"\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)"#, #"\x1B\[[0-?]*[ -/]*[@-~]"#] {
            if let expression = try? NSRegularExpression(pattern: pattern) {
                value = expression.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "")
            }
        }
        return String(value.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\r" || scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar)
        })
    }
    public static func optionNames(_ help: String) -> Set<String> {
        guard let expression = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9_-])--[a-z][a-z0-9-]*"#) else { return [] }
        return Set(expression.matches(in: help, range: NSRange(help.startIndex..., in: help)).compactMap { result in
            Range(result.range, in: help).map { String(help[$0]) }
        })
    }
}

public enum InstalledAppSelection {
    /// Mole resolves names, not paths. This conservative guard only enables a
    /// native selection when each supplied exact name identifies exactly the
    /// selected app. Cask aliases, duplicate names, and fuzzy-only matches return
    /// to the official selector instead of predicting an index or deleting a path.
    public static func validatedNames(selected: [InstalledApp], inventory: [InstalledApp]) throws -> [String] {
        guard !selected.isEmpty else { throw MoleError.invalidArgument("No app selected.") }
        var results: [String] = []
        for app in selected {
            guard inventory.contains(where: { $0.path == app.path && $0.uninstallName == app.uninstallName && $0.bundleId == app.bundleId }) else {
                throw MoleError.invalidArgument("App inventory changed; refresh before reviewing an uninstall.")
            }
            try SafePath.validateAppArgument(app.uninstallName)
            guard app.uninstallName.rangeOfCharacter(from: CharacterSet(charactersIn: "*?[\\")) == nil else {
                throw MoleError.invalidArgument("This app name requires Mole's interactive selector.")
            }
            let query = app.uninstallName.lowercased()
            let exact = inventory.filter { candidate in
                let directoryName = URL(fileURLWithPath: candidate.path).deletingPathExtension().lastPathComponent
                return candidate.name.lowercased() == query || directoryName.lowercased() == query
            }
            guard exact.count == 1, exact[0].path == app.path else {
                throw MoleError.invalidArgument("The CLI resolves '\(app.uninstallName)' by name, not by path. Use the official interactive selector to confirm this app.")
            }
            guard !results.contains(where: { $0.lowercased() == query }) else {
                throw MoleError.invalidArgument("Ambiguous duplicate uninstall names; use Mole's interactive selector.")
            }
            results.append(app.uninstallName)
        }
        return results
    }
}
