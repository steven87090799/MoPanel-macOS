import Foundation

public enum MoleCommand: String, CaseIterable, Codable, Sendable, Identifiable {
    case menu, clean, uninstall, optimize, analyze, status, purge, installer, slim
    case history, touchid, completion, update, remove, help, version
    public var id: String { rawValue }
    public var defaultArguments: [String] {
        switch self {
        case .menu: return []
        case .help: return ["--help"]
        case .version: return ["--version"]
        default: return [rawValue]
        }
    }
    public var hasDryRun: Bool {
        [.clean, .uninstall, .optimize, .purge, .installer, .slim, .touchid, .completion, .remove].contains(self)
    }
    public var requiredHelpFlags: Set<String> {
        switch self {
        case .clean: return ["--dry-run", "--external", "--whitelist"]
        case .uninstall: return ["--list", "--dry-run", "--with-data", "--permanent"]
        case .optimize: return ["--dry-run", "--whitelist"]
        case .analyze: return ["--json"]
        case .status: return ["--json", "--watch", "--interval", "--proc-cpu-alerts", "--proc-cpu-threshold", "--proc-cpu-window"]
        case .history: return ["--json", "--limit"]
        case .purge: return ["--paths", "--dry-run", "--include-empty", "--yes"]
        case .installer, .slim: return ["--dry-run", "--debug"]
        case .touchid, .completion, .remove: return ["--dry-run"]
        case .update: return ["--force", "--nightly"]
        default: return []
        }
    }
}

public enum TouchIDAction: String, CaseIterable, Codable, Sendable { case enable, disable, status }
public enum CompletionShell: String, CaseIterable, Codable, Sendable { case bash, zsh, fish }

public enum MoleOption: Equatable, Sendable {
    case dryRun, debug, help, whitelist, uninstallList, permanent, withData
    case externalVolume(String), apps([String])
    case json, watch, intervalSeconds(Int), procCPUThreshold(Double)
    case procCPUWindowSeconds(Int), procCPUAlerts(Bool)
    case analyzePath(String), historyLimit(Int), purgePaths, includeEmpty, yes
    case nightly, force, touchID(TouchIDAction), completionShell(CompletionShell)

    fileprivate var key: String {
        switch self {
        case .dryRun: return "dry-run"
        case .debug: return "debug"
        case .help: return "help"
        case .whitelist: return "whitelist"
        case .uninstallList: return "list"
        case .permanent: return "permanent"
        case .withData: return "with-data"
        case .externalVolume: return "external"
        case .apps: return "apps"
        case .json: return "json"
        case .watch: return "watch"
        case .intervalSeconds: return "interval"
        case .procCPUThreshold: return "proc-cpu-threshold"
        case .procCPUWindowSeconds: return "proc-cpu-window"
        case .procCPUAlerts: return "proc-cpu-alerts"
        case .analyzePath: return "path"
        case .historyLimit: return "limit"
        case .purgePaths: return "paths"
        case .includeEmpty: return "include-empty"
        case .yes: return "yes"
        case .nightly: return "nightly"
        case .force: return "force"
        case .touchID: return "touchid-action"
        case .completionShell: return "completion-shell"
        }
    }
}

public enum MoleRisk: String, Codable, Sendable {
    case readOnly, changesSettings, deletesFiles, replacesApplications, removesEngine
}

/// A single audited invocation. Execute `arguments` directly through execve or
/// Process.arguments. `displayCommand` is presentation only, NEVER shell code.
public struct MoleInvocation: Equatable, Sendable {
    public let command: MoleCommand
    public let arguments: [String]
    public let requiresPTY: Bool
    public let risk: MoleRisk
    public let isPreview: Bool
    public var isDestructive: Bool { risk != .readOnly }
    public var displayCommand: String {
        (["mo"] + arguments).map { arg in
            if arg.rangeOfCharacter(from: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._=-").inverted) == nil { return arg }
            return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }

    public static func make(command: MoleCommand, options: [MoleOption] = []) throws -> MoleInvocation {
        var allowed: Set<String> = ["help", "debug"]
        switch command {
        case .clean: allowed.formUnion(["dry-run", "external", "whitelist"])
        case .uninstall: allowed.formUnion(["list", "dry-run", "permanent", "with-data", "apps"])
        case .optimize: allowed.formUnion(["dry-run", "whitelist"])
        case .analyze: allowed.formUnion(["json", "path"])
        case .status: allowed.formUnion(["json", "watch", "interval", "proc-cpu-threshold", "proc-cpu-window", "proc-cpu-alerts"])
        case .history: allowed.formUnion(["json", "limit"])
        case .purge: allowed.formUnion(["paths", "dry-run", "include-empty", "yes"])
        case .installer, .slim: allowed.insert("dry-run")
        case .touchid: allowed.formUnion(["touchid-action", "dry-run"])
        case .completion: allowed.formUnion(["completion-shell", "dry-run"])
        case .update: allowed.formUnion(["force", "nightly"])
        case .remove: allowed.insert("dry-run")
        case .menu, .help, .version: allowed = []
        }
        var keys = Set<String>()
        for option in options {
            guard allowed.contains(option.key) else {
                throw MoleError.invalidArgument("\(option.key) is not supported by \(command.rawValue).")
            }
            guard keys.insert(option.key).inserted else {
                throw MoleError.invalidArgument("Duplicate option: \(option.key).")
            }
        }
        if keys.contains("help") {
            guard keys.count == 1 else { throw MoleError.invalidArgument("Help cannot be combined with an operation.") }
            return MoleInvocation(command: command, arguments: command.defaultArguments + ["--help"], requiresPTY: false, risk: .readOnly, isPreview: false)
        }
        if keys.contains("whitelist") || keys.contains("paths") {
            guard keys.subtracting(["whitelist", "paths", "debug"]).isEmpty else {
                throw MoleError.invalidArgument("Configuration menus cannot be combined with cleanup flags.")
            }
        }
        if keys.contains("list"), !keys.subtracting(["list", "debug"]).isEmpty {
            throw MoleError.invalidArgument("App inventory cannot be combined with uninstall flags.")
        }
        if keys.contains("interval"), !keys.contains("watch") {
            throw MoleError.invalidArgument("--interval requires --watch.")
        }
        if keys.contains("yes"), keys.contains("dry-run") {
            throw MoleError.invalidArgument("Unattended approval is not applicable to a preview.")
        }
        var flags: [String] = []
        var positionals: [String] = []
        var touchAction: TouchIDAction?
        var shell: CompletionShell?
        for option in options {
            switch option {
            case .dryRun: flags.append("--dry-run")
            case .debug: flags.append("--debug")
            case .help: break
            case .whitelist: flags.append("--whitelist")
            case .uninstallList: flags.append("--list")
            case .permanent: flags.append("--permanent")
            case .withData: flags.append("--with-data")
            case .externalVolume(let path):
                try SafePath.validateAbsolute(path)
                guard path.hasPrefix("/Volumes/"), path != "/Volumes/" else {
                    throw MoleError.invalidArgument("Choose a mounted external volume below /Volumes.")
                }
                flags += ["--external", path]
            case .apps(let names):
                guard !names.isEmpty, names.count <= 500 else { throw MoleError.invalidArgument("Choose 1–500 apps.") }
                guard Set(names).count == names.count else { throw MoleError.invalidArgument("Duplicate uninstall names require review in Mole's app selector.") }
                for name in names { try SafePath.validateAppArgument(name) }
                positionals += names
            case .json: flags.append("--json")
            case .watch: flags.append("--watch")
            case .intervalSeconds(let value):
                guard (1...3600).contains(value) else { throw MoleError.invalidArgument("Monitoring interval must be 1–3600 seconds.") }
                flags += ["--interval", "\(value)s"]
            case .procCPUThreshold(let value):
                guard value.isFinite, value >= 0 else { throw MoleError.invalidArgument("CPU alert threshold must be a finite nonnegative number.") }
                flags += ["--proc-cpu-threshold", String(value)]
            case .procCPUWindowSeconds(let value):
                guard value > 0 else { throw MoleError.invalidArgument("CPU alert window must be positive.") }
                flags += ["--proc-cpu-window", "\(value)s"]
            case .procCPUAlerts(let enabled): flags.append("--proc-cpu-alerts=\(enabled ? "true" : "false")")
            case .analyzePath(let path):
                try SafePath.validateAbsolute(path)
                positionals.append(path)
            case .historyLimit(let value):
                guard (1...200).contains(value) else { throw MoleError.invalidArgument("History limit must be 1–200.") }
                flags += ["--limit", String(value)]
            case .purgePaths: flags.append("--paths")
            case .includeEmpty: flags.append("--include-empty")
            case .yes: flags.append("--yes")
            case .nightly: flags.append("--nightly")
            case .force: flags.append("--force")
            case .touchID(let action): touchAction = action; positionals.append(action.rawValue)
            case .completionShell(let value): shell = value; positionals.append(value.rawValue)
            }
        }
        let dryRun = keys.contains("dry-run")
        let configuration = keys.contains("whitelist") || keys.contains("paths")
        let risk: MoleRisk
        if dryRun || keys.contains("list") || command == .help || command == .version || command == .history || command == .status || (command == .analyze && keys.contains("json")) || (command == .touchid && touchAction == .status) || (command == .completion && shell != nil) {
            risk = .readOnly
        } else if configuration || [.touchid, .completion, .update, .menu].contains(command) {
            risk = .changesSettings
        } else if command == .remove {
            risk = .removesEngine
        } else if command == .slim {
            risk = .replacesApplications
        } else if command == .optimize {
            risk = .changesSettings
        } else {
            risk = .deletesFiles
        }
        let requiresPTY: Bool
        if configuration || risk != .readOnly {
            requiresPTY = true
        } else if command == .status {
            requiresPTY = !keys.contains("json") && !keys.contains("watch")
        } else if command == .analyze {
            requiresPTY = !keys.contains("json")
        } else if command == .uninstall {
            requiresPTY = !keys.contains("list") && positionals.isEmpty
        } else if [.purge, .installer, .slim].contains(command) {
            requiresPTY = true
        } else {
            requiresPTY = false
        }
        return MoleInvocation(command: command, arguments: command.defaultArguments + flags + positionals,
                              requiresPTY: requiresPTY, risk: risk, isPreview: dryRun)
    }
}

public enum SafePath {
    public static func validateAbsolute(_ path: String) throws {
        guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 32_768 else {
            throw MoleError.invalidArgument("Expected an absolute path without a NUL byte.")
        }
    }
    public static func validateAppArgument(_ name: String) throws {
        guard !name.isEmpty, !name.hasPrefix("-"), name.utf8.count <= 4096,
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw MoleError.invalidArgument("App name cannot be empty, start with '-', or contain control characters. Use Mole's interactive app selector for this item.")
        }
    }
}
