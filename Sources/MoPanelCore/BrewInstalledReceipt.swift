// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Read-only proof of the installed recipe, not an install/uninstall engine.
/// Homebrew can execute the OLD recipe during upgrade. A safe current cask is
/// therefore insufficient: both recipes and the saved configuration must agree.
public struct BrewInstalledReceiptProof: Equatable, Sendable {
    public let caskDirectory: URL
    public let definitionURL: URL
    public let definition: Data
    public let receipt: Data
    public let configuration: Data
}

public enum BrewInstalledReceipt {
    private static let bound = 1_048_576

    /// `brew --caskroom <one fully-qualified cask>` officially returns one path.
    /// It is not parsed as a removal plan or used as a shell command.
    public static func caskDirectory(output: String, identity: BrewCaskIdentity) throws -> URL {
        let path = output.hasSuffix("\n") ? String(output.dropLast()) : output
        guard path.hasPrefix("/"), path.utf8.count <= 32768,
              !path.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) else {
            throw unsupported("Homebrew did not return one absolute Caskroom path.")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.lastPathComponent == identity.token else { throw unsupported("Caskroom identity does not match the selected cask.") }
        return url
    }

    /// Supports the current compact JSON installed format only. Legacy Ruby,
    /// internal JSON, multiple version/timestamp choices and missing receipts
    /// are intentionally handed back to the source updater/Homebrew.
    public static func inspect(caskDirectory: URL, item: BrewUpdateItem) throws -> BrewInstalledReceiptProof {
        let plan = try BrewUpdatePlan(item: item)
        guard caskDirectory.isFileURL, caskDirectory.lastPathComponent == plan.identity.token,
              safeComponent(plan.installedVersion) else { throw unsupported("Invalid installed receipt identity.") }
        let base = caskDirectory.standardizedFileURL
        try requireOwnedDirectory(base)
        let canonical = base.resolvingSymlinksInPath()
        let metadata = canonical.appendingPathComponent(".metadata", isDirectory: true)
        try requireOwnedDirectory(metadata)

        let metadataEntries = try children(metadata)
        var versions: [URL] = []
        for entry in metadataEntries {
            let type = try FileManager.default.attributesOfItem(atPath: entry.path)[.type] as? FileAttributeType
            if type == .typeDirectory { versions.append(entry) }
            else if type != .typeRegular || !["INSTALL_RECEIPT.json", "config.json", "LATEST_DOWNLOAD_SHA256"].contains(entry.lastPathComponent) {
                throw unsupported("Unknown or linked installed metadata entry.")
            }
        }
        guard versions.count == 1, versions[0].lastPathComponent == plan.installedVersion else {
            throw unsupported("Installed recipe versions are missing or ambiguous.")
        }
        try requireOwnedDirectory(versions[0])
        let timestamps = try children(versions[0])
        guard timestamps.count == 1,
              timestamps[0].lastPathComponent.range(of: #"^[0-9]{14}\.[0-9]{3}$"#, options: .regularExpression) != nil else {
            throw unsupported("Installed recipe timestamps are missing or ambiguous.")
        }
        try requireOwnedDirectory(timestamps[0])
        let casks = timestamps[0].appendingPathComponent("Casks", isDirectory: true)
        try requireOwnedDirectory(casks)
        let definitions = try children(casks)
        guard definitions.count == 1, definitions[0].lastPathComponent == plan.identity.token + ".json" else {
            throw unsupported("The installed recipe is Ruby, legacy, missing or ambiguous; direct upgrade is unavailable.")
        }
        let definition = try readOwnedFile(definitions[0], below: canonical)
        let receipt = try readOwnedFile(metadata.appendingPathComponent("INSTALL_RECEIPT.json"), below: canonical)
        let configuration = try readOwnedFile(metadata.appendingPathComponent("config.json"), below: canonical)
        try validate(definition: definition, receipt: receipt, configuration: configuration, item: item)
        // Detect an ancestor replacement while the bounded files were read.
        try requireOwnedDirectory(base)
        guard base.resolvingSymlinksInPath() == canonical else { throw unsupported("Installed metadata moved while it was read.") }
        return BrewInstalledReceiptProof(caskDirectory: canonical, definitionURL: definitions[0],
                                         definition: definition, receipt: receipt, configuration: configuration)
    }

    public static func validate(definition: Data, receipt: Data, configuration: Data, item: BrewUpdateItem) throws {
        let plan = try BrewUpdatePlan(item: item)
        guard definition.count <= bound, receipt.count <= bound, configuration.count <= bound else {
            throw unsupported("Installed receipt exceeds the supported bound.")
        }
        let object = try dictionary(definition)
        guard Set(object.keys).isSubset(of: ["artifacts", "version", "url_specs"]) else {
            throw unsupported("The installed definition is not the supported compact JSON format.")
        }
        if let version = object["version"] {
            guard let version = version as? String, version == plan.installedVersion else {
                throw unsupported("The installed definition version changed.")
            }
        }
        if let raw = object["url_specs"] {
            guard let specs = raw as? [String: String], Set(specs.keys).isSubset(of: ["only_path"]),
                  specs.values.allSatisfy({ safeRelativePath($0) }) else { throw unsupported("Unknown installed URL configuration.") }
        }
        struct Tab: Decodable {
            struct Source: Decodable { let tap: String; let version: String; let path: String }
            let source: Source
            let uninstallFlightBlocks: Bool
            let uninstallArtifacts: [BrewAppArtifact]
            enum CodingKeys: String, CodingKey {
                case source
                case uninstallFlightBlocks = "uninstall_flight_blocks", uninstallArtifacts = "uninstall_artifacts"
            }
        }
        let tab = try JSONDecoder().decode(Tab.self, from: receipt)
        guard tab.source.tap == plan.identity.tap, tab.source.version == plan.installedVersion,
              !tab.uninstallFlightBlocks, tab.source.path.hasPrefix("/"), !tab.source.path.utf8.contains(0),
              [plan.identity.token + ".rb", plan.identity.token + ".json", plan.identity.token + ".internal.json"].contains(URL(fileURLWithPath: tab.source.path).lastPathComponent) else {
            throw unsupported("The installed recipe source or flight blocks are not supported.")
        }
        let expectedApps = (item.installed.artifacts ?? []).filter(\.isApplication).compactMap(\.appDirective)
        try validateArtifacts(tab.uninstallArtifacts, expectedApps: expectedApps)
        // Current Homebrew prefers explicit installed JSON artifacts, otherwise
        // the receipt. Validate both instead of trusting fallback precedence.
        if object.keys.contains("artifacts") {
            struct Definition: Decodable { let artifacts: [BrewAppArtifact] }
            let old = try JSONDecoder().decode(Definition.self, from: definition)
            try validateArtifacts(old.artifacts, expectedApps: expectedApps)
        }
        let config = try dictionary(configuration)
        guard Set(config.keys).isSubset(of: ["default", "env", "explicit"]), !config.isEmpty else {
            throw unsupported("Unknown saved Homebrew configuration.")
        }
        for value in config.values {
            guard value is [String: Any] else { throw unsupported("Malformed saved Homebrew configuration.") }
        }
        // Confirm the explicit JSON targets against the saved appdir and the
        // identical old/new app directives. This only rejects inconsistencies;
        // it never creates a target that Homebrew omitted from its JSON.
        let appdirValues = ["explicit", "env", "default"].compactMap { key -> Any? in
            (config[key] as? [String: Any])?["appdir"]
        }
        guard let rawAppdir = appdirValues.first as? String, rawAppdir.hasPrefix("/"),
              !rawAppdir.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) else {
            throw unsupported("The saved App directory is unavailable or unsupported.")
        }
        let appdir = URL(fileURLWithPath: rawAppdir).standardizedFileURL
        for artifact in (item.installed.artifacts ?? []).filter(\.isApplication) {
            guard let directive = artifact.appDirective, let target = artifact.target else { throw unsupported("Missing App target.") }
            let expectedName = directive.renamedTarget ?? URL(fileURLWithPath: directive.source).lastPathComponent
            let url = URL(fileURLWithPath: target).standardizedFileURL
            guard !expectedName.contains("/"), url.lastPathComponent == expectedName,
                  url.deletingLastPathComponent().path == appdir.path else { throw unsupported("Saved App directory and current JSON targets disagree.") }
        }
    }

    private static func validateArtifacts(_ artifacts: [BrewAppArtifact], expectedApps: [BrewAppDirective]) throws {
        let apps = artifacts.filter(\.isApplication)
        guard !artifacts.isEmpty, artifacts.count <= 1000, artifacts.allSatisfy(\.supportsDirectUpgrade),
              apps.count == expectedApps.count, !apps.isEmpty, apps.allSatisfy({ $0.appDirective != nil }),
              apps.compactMap(\.appDirective) == expectedApps else {
            throw unsupported("The old recipe has hooks, unknown artifacts or different App targets; use the source updater/Homebrew.")
        }
    }

    private static func dictionary(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw unsupported("Invalid installed metadata JSON.") }
        return value
    }
    private static func safeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && safeRelativePath(value)
    }
    private static func safeRelativePath(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 32768 && !value.hasPrefix("/")
            && !value.split(separator: "/", omittingEmptySubsequences: false).contains("..")
            && !value.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) })
    }
    private static func children(_ url: URL) throws -> [URL] {
        let values = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        guard values.count <= 128 else { throw unsupported("Installed metadata directory exceeds the bound.") }
        return values
    }
    private static func requireOwnedDirectory(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let permissions = attributes[.posixPermissions] as? NSNumber, permissions.intValue & 0o002 == 0 else {
            throw unsupported("Installed metadata must be owned, non-linked directories.")
        }
    }
    private static func readOwnedFile(_ url: URL, below base: URL) throws -> Data {
        guard url.resolvingSymlinksInPath().path == url.path, url.path.hasPrefix(base.path + "/") else {
            throw unsupported("Linked or escaped installed receipt.")
        }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw unsupported("Installed receipt cannot be opened safely.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat(), after = stat()
        #if canImport(Darwin)
        let regular = mode_t(Darwin.S_IFREG), mask = mode_t(Darwin.S_IFMT)
        #else
        let regular = mode_t(Glibc.S_IFREG), mask = mode_t(Glibc.S_IFMT)
        #endif
        guard fstat(fd, &before) == 0, before.st_mode & mask == regular, before.st_uid == getuid(),
              before.st_nlink == 1, before.st_mode & 0o002 == 0, before.st_size > 0, before.st_size <= bound else {
            throw unsupported("Installed receipt must be a bounded, owned regular file.")
        }
        let data = try handle.read(upToCount: bound + 1) ?? Data()
        guard data.count <= bound, data.count == before.st_size, fstat(fd, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
              url.resolvingSymlinksInPath().path == url.path else { throw unsupported("Installed receipt changed while reading.") }
        return data
    }
    private static func unsupported(_ message: String) -> MoleError { .incompatible(message) }
}
