// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A cask's authoritative identity, never an application display name or URL.
public struct BrewCaskIdentity: Hashable, Sendable {
    public let token: String
    public let tap: String
    public var qualifiedToken: String { tap + "/" + token }

    public init(token: String, tap: String) throws {
        let pieces = tap.split(separator: "/", omittingEmptySubsequences: false)
        guard Self.validComponent(token), pieces.count == 2,
              pieces.allSatisfy({ Self.validComponent(String($0)) }) else {
            throw MoleError.invalidArgument("Homebrew cask identity is not a supported token and tap.")
        }
        self.token = token; self.tap = tap
    }

    private static func validComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 200,
              value.first?.isASCII == true, value.first?.isLetter == true || value.first?.isNumber == true else { return false }
        return value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || [43, 45, 46, 64, 95].contains($0) }
            && !value.contains("..")
    }
}

public enum BrewHelpCommand: String, Sendable { case info, outdated, upgrade, update }

/// No arbitrary argument constructor. Every mutation contains exactly one fully
/// qualified, validated identity; there is deliberately no "upgrade all" case.
public enum BrewUpdateCommand: Sendable {
    case version, installedInfo, outdated, refreshMetadata
    case help(BrewHelpCommand)
    case preview(BrewCaskIdentity)
    case upgrade(BrewCaskIdentity)

    public var arguments: [String] {
        switch self {
        case .version: return ["--version"]
        case .installedInfo: return ["info", "--json=v2", "--cask", "--installed"]
        case .outdated: return ["outdated", "--cask", "--json=v2"]
        case .refreshMetadata: return ["update"]
        case .help(let command): return [command.rawValue, "--help"]
        case .preview(let identity): return ["upgrade", "--cask", "--no-quit", "--require-sha", "--dry-run", identity.qualifiedToken]
        case .upgrade(let identity): return ["upgrade", "--cask", "--no-quit", "--require-sha", identity.qualifiedToken]
        }
    }
    public var requiresConfirmation: Bool {
        switch self { case .upgrade, .refreshMetadata: return true; default: return false }
    }
}

public struct BrewUpdateCapabilities: Equatable, Sendable {
    public let canRead: Bool
    public let canUpgrade: Bool
    public let canRefresh: Bool

    public init(infoHelp: String, outdatedHelp: String, upgradeHelp: String, updateHelp: String) {
        let info = TerminalText.optionNames(infoHelp), outdated = TerminalText.optionNames(outdatedHelp)
        let upgrade = TerminalText.optionNames(upgradeHelp)
        canRead = Set(["--json", "--cask", "--installed"]).isSubset(of: info)
            && Set(["--json", "--cask"]).isSubset(of: outdated)
            && infoHelp.contains("v2") && outdatedHelp.contains("v2")
        // --no-quit is mandatory. Older Homebrew can still show inventory, but
        // MoPanel never quietly closes a running app to force an update.
        canUpgrade = canRead && Set(["--cask", "--dry-run", "--no-quit", "--require-sha"]).isSubset(of: upgrade)
        canRefresh = updateHelp.contains("brew update") && updateHelp.localizedCaseInsensitiveContains("Homebrew")
    }
}

public struct BrewAppArtifact: Decodable, Equatable, Sendable {
    public let isApplication: Bool
    public let target: String?
    public let kinds: Set<String>
    private struct Key: CodingKey { let stringValue: String; let intValue: Int? = nil; init?(stringValue: String) { self.stringValue = stringValue }; init?(intValue: Int) { return nil } }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Key.self)
        kinds = Set(values.allKeys.map(\.stringValue)).subtracting(["target"])
        isApplication = kinds.contains("app")
        target = try values.decodeIfPresent(String.self, forKey: Key(stringValue: "target")!)
    }
    public var supportsDirectUpgrade: Bool { !kinds.isEmpty && kinds.isSubset(of: ["app", "binary", "manpage", "zap"]) }
}

public struct BrewCaskDependencies: Decodable, Equatable, Sendable {
    public let hasPackageDependencies: Bool
    private struct Key: CodingKey { let stringValue: String; let intValue: Int? = nil; init?(stringValue: String) { self.stringValue = stringValue }; init?(intValue: Int) { return nil } }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Key.self)
        // macOS/architecture requirements are constraints, not package installs.
        hasPackageDependencies = values.allKeys.contains { !["macos", "maximum_macos", "arch"].contains($0.stringValue) }
    }
}

public struct BrewInstalledCask: Decodable, Equatable, Sendable {
    public let token: String
    public let fullToken: String
    public let tap: String?
    public let name: [String]
    public let version: String
    public let installed: String?
    public let autoUpdates: Bool?
    public let pinned: Bool?
    public let disabled: Bool?
    public let artifacts: [BrewAppArtifact]?
    public let sha256: String?
    public let dependencies: BrewCaskDependencies?

    private enum CodingKeys: String, CodingKey {
        case token, tap, name, version, installed, pinned, disabled, artifacts, sha256
        case fullToken = "full_token", autoUpdates = "auto_updates", dependencies = "depends_on"
    }
    public var title: String { name.first ?? token }
    public var identity: BrewCaskIdentity? {
        guard let tap, let identity = try? BrewCaskIdentity(token: token, tap: tap),
              fullToken == token || fullToken == identity.qualifiedToken else { return nil }
        return identity
    }
    /// A target comes only from Homebrew's structured artifact metadata. Never
    /// guess /Applications/<display-name>.app, including custom --appdir installs.
    public var applicationPaths: [String] {
        Array(Set((artifacts ?? []).compactMap { artifact -> String? in
            guard artifact.isApplication, let target = artifact.target,
                  target.hasPrefix("/"), target.utf8.count <= 32768,
                  !target.utf8.contains(0), URL(fileURLWithPath: target).pathExtension.lowercased() == "app" else { return nil }
            return URL(fileURLWithPath: target).standardizedFileURL.path
        })).sorted()
    }
    public var supportsDirectUpgrade: Bool {
        guard tap == "homebrew/cask", let artifacts, artifacts.contains(where: \.isApplication),
              artifacts.allSatisfy(\.supportsDirectUpgrade), dependencies?.hasPackageDependencies != true,
              applicationPaths.count == artifacts.filter(\.isApplication).count,
              let sha256, sha256.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
        return true
    }
}

public struct BrewOutdatedCask: Decodable, Equatable, Sendable {
    public let name: String
    public let installedVersions: [String]
    public let currentVersion: String
    public let pinned: Bool?
    private enum CodingKeys: String, CodingKey {
        case name, pinned
        case installedVersions = "installed_versions", currentVersion = "current_version"
    }
}

public enum BrewUpdateState: String, Sendable {
    case available, current, selfManaged, unversioned, pinned, disabled, unsupported
}

public struct BrewUpdateItem: Identifiable, Equatable, Sendable {
    public let installed: BrewInstalledCask
    public let outdated: BrewOutdatedCask?
    public var id: String { installed.fullToken }
    public var state: BrewUpdateState {
        guard installed.identity != nil, installed.installed != nil else { return .unsupported }
        if installed.disabled == true { return .disabled }
        if installed.pinned == true || outdated?.pinned == true { return .pinned }
        if installed.version == "latest" { return .unversioned }
        if outdated != nil { return installed.supportsDirectUpgrade ? .available : .unsupported }
        if installed.autoUpdates == true { return .selfManaged }
        guard installed.installed == installed.version else { return .unsupported }
        return .current
    }
}

public struct BrewUpdateSnapshot: Sendable {
    public let items: [BrewUpdateItem]

    public static func decode(info: Data, outdated: Data) throws -> Self {
        guard info.count <= 16 * 1024 * 1024, outdated.count <= 16 * 1024 * 1024 else {
            throw MoleError.invalidOutput("Homebrew JSON exceeds the supported bound.")
        }
        struct Info: Decodable { let casks: [BrewInstalledCask] }
        struct Outdated: Decodable { let casks: [BrewOutdatedCask] }
        let installed = try JSONDecoder().decode(Info.self, from: info).casks
        let updates = try JSONDecoder().decode(Outdated.self, from: outdated).casks
        guard installed.count <= 50_000, updates.count <= 50_000 else { throw invalid("Too many casks.") }
        var byToken: [String: BrewInstalledCask] = [:]
        var byUpdate: [String: BrewOutdatedCask] = [:]
        for cask in installed {
            guard validText(cask.token), validText(cask.fullToken), validText(cask.version),
                  cask.installed.map(validText) ?? true,
                  cask.name.count <= 50, cask.name.allSatisfy(validText),
                  cask.artifacts?.count ?? 0 <= 1000,
                  byToken[cask.token] == nil else { throw invalid("Invalid or ambiguous installed cask identity.") }
            byToken[cask.token] = cask
        }
        for update in updates {
            guard validText(update.name), validText(update.currentVersion),
                  !update.installedVersions.isEmpty, update.installedVersions.count <= 100,
                  update.installedVersions.allSatisfy(validText), byUpdate[update.name] == nil,
                  let original = byToken[update.name], let originalInstalled = original.installed,
                  update.installedVersions == [originalInstalled], update.currentVersion == original.version else {
                throw invalid("Homebrew info/outdated snapshots disagree. Check again before updating.")
            }
            byUpdate[update.name] = update
        }
        return Self(items: installed.map { BrewUpdateItem(installed: $0, outdated: byUpdate[$0.token]) }
            .sorted { $0.installed.title.localizedStandardCompare($1.installed.title) == .orderedAscending })
    }

    private static func validText(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 32768 && !text.unicodeScalars.contains { $0.value < 32 || (127...159).contains($0.value) }
    }
    private static func invalid(_ message: String) -> MoleError { .invalidOutput(message) }
}

/// This is a confirmation identity, not a replacement Homebrew install plan.
/// Homebrew retains download/signature/dependency/vendor-installer decisions.
public struct BrewUpdatePlan: Equatable, Sendable, Identifiable {
    public let identity: BrewCaskIdentity
    public let title: String
    public let installedVersion: String
    public let availableVersion: String
    public let applicationPaths: [String]
    public let payloadSHA256: String
    public var id: String { identity.qualifiedToken }

    public init(item: BrewUpdateItem) throws {
        guard item.state == .available, let identity = item.installed.identity,
              let installed = item.installed.installed, let update = item.outdated, let sha256 = item.installed.sha256 else {
            throw MoleError.incompatible("This cask has no supported, unpinned update plan.")
        }
        self.identity = identity; title = item.installed.title
        installedVersion = installed; availableVersion = update.currentVersion
        applicationPaths = item.installed.applicationPaths
        payloadSHA256 = sha256
    }

    public func revalidate(in fresh: BrewUpdateSnapshot) throws {
        guard let item = fresh.items.first(where: { $0.installed.identity == identity }),
              let replacement = try? BrewUpdatePlan(item: item), replacement == self else {
            throw MoleError.incompatible("The cask, versions, source or target changed after preview. Check again and review a new plan.")
        }
    }
}

/// Only expose non-secret HTTPS publisher metadata. This does not fetch feeds,
/// prove publisher ownership, or authorize installing their contents.
public enum PublisherFeedPolicy {
    public static func displayableURL(_ raw: String, signatureValid: Bool) -> URL? {
        guard signatureValid, raw.utf8.count <= 4096,
              !raw.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }),
              let components = URLComponents(string: raw), components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil, components.query == nil,
              components.fragment == nil, components.port == nil || components.port == 443,
              let host = components.host?.lowercased(), host.contains("."), !host.hasSuffix("."),
              !host.hasSuffix(".local"), !host.hasSuffix(".localhost"), !host.hasSuffix(".internal"),
              !host.contains(":"), !host.allSatisfy({ $0.isNumber || $0 == "." }),
              host.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || [45, 46].contains($0) }),
              let url = components.url else { return nil }
        return url
    }
}

/// Read only layout recognition before the first execution. It is not a code
/// signature or an assertion that a user-editable Homebrew checkout is pristine.
public struct BrewExecutableLayout: Equatable, Sendable {
    public let executable: URL
    public let repository: URL

    public static func candidates(pathEnvironment: String) -> [URL] {
        let paths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            + pathEnvironment.split(separator: ":").compactMap { component -> String? in
                let value = String(component)
                guard value.hasPrefix("/"), !value.utf8.contains(0) else { return nil }
                return URL(fileURLWithPath: value).appendingPathComponent("brew").path
            }
        var seen = Set<String>()
        return paths.compactMap { seen.insert($0).inserted ? URL(fileURLWithPath: $0) : nil }
    }

    public static func inspect(_ candidate: URL) throws -> Self {
        guard candidate.isFileURL, candidate.path.hasPrefix("/"), !candidate.path.utf8.contains(0) else {
            throw MoleError.invalidArgument("Choose an absolute Homebrew executable.")
        }
        let executable = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let root = executable.deletingLastPathComponent().deletingLastPathComponent()
        let fm = FileManager.default, attributes = try fm.attributesOfItem(atPath: executable.path)
        guard executable.lastPathComponent == "brew", executable.deletingLastPathComponent().lastPathComponent == "bin",
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, (1...2_097_152).contains(size.intValue),
              let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o002 == 0,
              fm.isExecutableFile(atPath: executable.path),
              fm.fileExists(atPath: root.appendingPathComponent("Library/Homebrew/brew.sh").path),
              fm.fileExists(atPath: root.appendingPathComponent("Library/Homebrew/brew.rb").path),
              fm.fileExists(atPath: root.appendingPathComponent("Library/Homebrew/cmd/outdated.rb").path) else {
            throw MoleError.incompatible("This executable is not a recognized local Homebrew layout.")
        }
        let data = try Data(contentsOf: executable, options: .mappedIfSafe)
        guard data.count <= 2_097_152, let text = String(data: data, encoding: .utf8),
              text.hasPrefix("#!"), text.contains("HOMEBREW_BREW_FILE"), text.contains("brew.sh") else {
            throw MoleError.incompatible("The Homebrew launcher structure is unrecognized.")
        }
        return Self(executable: executable, repository: root)
    }
}
