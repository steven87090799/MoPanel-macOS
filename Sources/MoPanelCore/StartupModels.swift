// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CoreFoundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum StartupScope: String, CaseIterable, Sendable {
    case userAgent, sharedAgent, systemDaemon
}

public struct StartupFolder: Sendable {
    public let url: URL
    public let scope: StartupScope
    public init(url: URL, scope: StartupScope) { self.url = url; self.scope = scope }
    public static func standard(home: URL) -> [StartupFolder] {
        [.init(url: home.appendingPathComponent("Library/LaunchAgents"), scope: .userAgent),
         .init(url: URL(fileURLWithPath: "/Library/LaunchAgents"), scope: .sharedAgent),
         .init(url: URL(fileURLWithPath: "/Library/LaunchDaemons"), scope: .systemDaemon)]
    }
}

public enum StartupGuardReason: String, Equatable, Sendable {
    case readOnlyScope, ownership, writableByOthers, protectedApple, protectedBuho,
         invalidLabel, invalidProgram, missingExecutable, symbolicExecutable,
         privilegedConfiguration, duplicateLabel, unknownState, staleSnapshot
}

public struct StartupFileIdentity: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let owner: UInt32
    public let mode: UInt32
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let changedSeconds: Int64
    public let changedNanoseconds: Int64
    fileprivate init(_ s: stat) {
        device = UInt64(truncatingIfNeeded: s.st_dev); inode = UInt64(s.st_ino)
        owner = s.st_uid; mode = UInt32(s.st_mode); size = Int64(s.st_size)
        #if canImport(Darwin)
        modifiedSeconds = Int64(s.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(s.st_mtimespec.tv_nsec)
        changedSeconds = Int64(s.st_ctimespec.tv_sec); changedNanoseconds = Int64(s.st_ctimespec.tv_nsec)
        #else
        modifiedSeconds = Int64(s.st_mtim.tv_sec); modifiedNanoseconds = Int64(s.st_mtim.tv_nsec)
        changedSeconds = Int64(s.st_ctim.tv_sec); changedNanoseconds = Int64(s.st_ctim.tv_nsec)
        #endif
    }
}

public struct StartupPlistSnapshot: Equatable, Sendable {
    public let url: URL
    public let folder: URL
    public let scope: StartupScope
    public let identity: StartupFileIdentity
    public let folderIdentity: StartupFileIdentity
    public let label: String?
    public let executable: String?
    public let arguments: [String]
    public let plistDisabled: Bool?
    public let guardReasons: [StartupGuardReason]
    // The bounded original bytes provide an exact comparison, not a weak hash.
    // These bytes can include environment secrets and are never exported or logged.
    fileprivate let originalBytes: Data
    public var canManageMetadata: Bool { guardReasons.isEmpty }
}

public struct StartupInventoryItem: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let scope: StartupScope
    public let snapshot: StartupPlistSnapshot?
    public let error: String?
}

public struct StartupInventory: Sendable {
    public let items: [StartupInventoryItem]
    public let warnings: [String]
    public let truncated: Bool
}

public enum StartupInspectionError: LocalizedError {
    case invalidPath, symbolicLink, notRegular, tooLarge, changed, invalidPlist, permission
    public var errorDescription: String? {
        switch self {
        case .invalidPath: return "The file is not directly inside the approved LaunchAgents/LaunchDaemons directory."
        case .symbolicLink: return "Symbolic links in the plist path are not supported."
        case .notRegular: return "Not a regular plist file."
        case .tooLarge: return "The plist exceeds the safe metadata size limit."
        case .changed: return "The plist or its identity changed; refresh and review again."
        case .invalidPlist: return "The file is not a supported, well-formed launchd property list."
        case .permission: return "The file or parent directory cannot be read safely."
        }
    }
}

public enum StartupInventoryReader {
    public static let maximumFileBytes = 128 * 1_024
    public static let maximumTotalBytes = 8 * 1_024 * 1_024
    public static let maximumEntriesPerFolder = 512

    public static func inventory(folders: [StartupFolder], userID: UInt32) -> StartupInventory {
        var rows: [StartupInventoryItem] = [], warnings: [String] = []
        var remainingBytes = maximumTotalBytes
        var truncated = false
        for folder in folders {
            if Task.isCancelled { truncated = true; break }
            var rootStat = stat()
            if lstat(folder.url.path, &rootStat) != 0 {
                if errno != ENOENT { warnings.append("Cannot read \(folder.url.path)") }
                continue
            }
            // URL equality includes representation details (base URL and
            // directory hint/trailing slash), not just the filesystem path.
            // Compare canonical paths while keeping lstat and symlink checks.
            guard folder.url.isFileURL, isDirectory(rootStat),
                  folder.url.standardizedFileURL.path == folder.url.path,
                  folder.url.resolvingSymlinksInPath().path == folder.url.path else {
                warnings.append("Unsafe or symbolic startup directory: \(folder.url.path)"); continue
            }
            guard let enumerator = FileManager.default.enumerator(at: folder.url,
                includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles],
                errorHandler: { url, _ in warnings.append("Cannot inspect \(url.path)"); return true }) else {
                warnings.append("Cannot enumerate \(folder.url.path)"); continue
            }
            var entries = 0
            for case let listedURL as URL in enumerator {
                if Task.isCancelled { truncated = true; break }
                entries += 1
                if entries > maximumEntriesPerFolder { truncated = true; break }
                guard listedURL.pathExtension.lowercased() == "plist" else { continue }
                let url: URL
                do { url = try inventoryChildURL(listedURL, within: folder.url) }
                catch {
                    rows.append(.init(url: listedURL, scope: folder.scope, snapshot: nil, error: error.localizedDescription))
                    continue
                }
                // Reserve the bytes before parsing, including malformed files.
                // Otherwise repeated invalid plists could bypass the aggregate
                // read budget. inspect() rejects a file that grows past this
                // reservation instead of silently reading beyond the budget.
                var candidate = stat()
                let reservation = lstat(url.path, &candidate) == 0
                    ? min(maximumFileBytes, max(1, Int(clamping: candidate.st_size)))
                    : maximumFileBytes
                guard remainingBytes >= reservation else { truncated = true; break }
                remainingBytes -= reservation
                do {
                    let snapshot = try inspect(url: url, folder: folder, userID: userID, byteBudget: reservation)
                    rows.append(.init(url: url, scope: folder.scope, snapshot: snapshot, error: nil))
                } catch {
                    rows.append(.init(url: url, scope: folder.scope, snapshot: nil, error: error.localizedDescription))
                    if remainingBytes <= 0 { truncated = true; break }
                }
            }
        }
        return .init(items: rows.sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending },
                     warnings: warnings, truncated: truncated)
    }

    public static func inspect(url: URL, folder: StartupFolder, userID: UInt32,
                               byteBudget: Int = maximumFileBytes) throws -> StartupPlistSnapshot {
        guard url.isFileURL, folder.url.isFileURL,
              url.deletingLastPathComponent().standardizedFileURL.path == folder.url.standardizedFileURL.path,
              url.standardizedFileURL.path == url.path, url.pathExtension.lowercased() == "plist",
              !url.path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw StartupInspectionError.invalidPath }
        guard url.resolvingSymlinksInPath().path == url.path,
              folder.url.resolvingSymlinksInPath().path == folder.url.path else { throw StartupInspectionError.symbolicLink }
        var parent = stat(), before = stat()
        guard lstat(folder.url.path, &parent) == 0, isDirectory(parent), lstat(url.path, &before) == 0 else { throw StartupInspectionError.permission }
        guard (before.st_mode & fileTypeMask) == regularFileType, before.st_nlink == 1 else { throw StartupInspectionError.notRegular }
        let limit = min(maximumFileBytes, max(0, byteBudget))
        guard before.st_size >= 0, before.st_size <= limit else { throw StartupInspectionError.tooLarge }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw StartupInspectionError.permission }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(fd, &opened) == 0, StartupFileIdentity(before) == StartupFileIdentity(opened) else { throw StartupInspectionError.changed }
        let bytes = try handle.read(upToCount: limit + 1) ?? Data()
        guard bytes.count <= limit else { throw StartupInspectionError.tooLarge }
        var after = stat(), pathAfter = stat()
        guard fstat(fd, &after) == 0, lstat(url.path, &pathAfter) == 0,
              StartupFileIdentity(opened) == StartupFileIdentity(after), StartupFileIdentity(after) == StartupFileIdentity(pathAfter),
              bytes.count == Int(after.st_size) else { throw StartupInspectionError.changed }
        // Custom XML entities are unnecessary for launchd metadata. Reject them
        // before parsing instead of accepting entity expansion or external data.
        if let xml = String(data: bytes, encoding: .utf8), xml.contains("<!ENTITY") { throw StartupInspectionError.invalidPlist }
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let dictionary = try? PropertyListSerialization.propertyList(from: bytes, options: [], format: &format) as? [String: Any],
              format == .xml || format == .binary else { throw StartupInspectionError.invalidPlist }
        let label = dictionary["Label"] as? String
        let args: [String]
        if let value = dictionary["ProgramArguments"] {
            guard let strings = value as? [String], !strings.isEmpty, strings.count <= 128,
                  strings.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 8_192 }) else { throw StartupInspectionError.invalidPlist }
            args = strings
        } else { args = [] }
        if dictionary["Program"] != nil && !(dictionary["Program"] is String) { throw StartupInspectionError.invalidPlist }
        let program = (dictionary["Program"] as? String) ?? args.first
        let disabled: Bool?
        if let value = dictionary["Disabled"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw StartupInspectionError.invalidPlist }
            disabled = number.boolValue
        } else { disabled = nil }
        var reasons: [StartupGuardReason] = []
        if folder.scope != .userAgent { reasons.append(.readOnlyScope) }
        if before.st_uid != userID || parent.st_uid != userID { reasons.append(.ownership) }
        if before.st_mode & 0o022 != 0 || parent.st_mode & 0o022 != 0 { reasons.append(.writableByOthers) }
        if label == nil || !StartupCommandPlan.isSafeLabel(label ?? "") { reasons.append(.invalidLabel) }
        let related = ([url.path, label ?? "", program ?? ""] + args).joined(separator: "\n").lowercased()
        if (label?.lowercased().hasPrefix("com.apple.") == true) || url.lastPathComponent.lowercased().hasPrefix("com.apple.") ||
            ["/System/", "/Library/Apple/", "/usr/libexec/"].contains(where: { program?.hasPrefix($0) == true }) { reasons.append(.protectedApple) }
        if related.contains("buho") { reasons.append(.protectedBuho) }
        if dictionary["UserName"] != nil || dictionary["GroupName"] != nil || dictionary["RootDirectory"] != nil { reasons.append(.privilegedConfiguration) }
        if let program, program.hasPrefix("/"), !program.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) {
            let executable = URL(fileURLWithPath: program)
            if executable.standardizedFileURL.path != program { reasons.append(.invalidProgram) }
            else if executable.resolvingSymlinksInPath().path != program { reasons.append(.symbolicExecutable) }
            else if !FileManager.default.isExecutableFile(atPath: program) { reasons.append(.missingExecutable) }
        } else { reasons.append(.invalidProgram) }
        return .init(url: url, folder: folder.url, scope: folder.scope, identity: .init(before), folderIdentity: .init(parent),
                     label: label, executable: program, arguments: args, plistDisabled: disabled, guardReasons: reasons, originalBytes: bytes)
    }

    public static func revalidate(_ expected: StartupPlistSnapshot, userID: UInt32) throws -> StartupPlistSnapshot {
        let current = try inspect(url: expected.url, folder: .init(url: expected.folder, scope: expected.scope), userID: userID)
        guard current == expected else { throw StartupInspectionError.changed }
        return current
    }

    /// FileManager may return an equivalent filesystem URL using /private/var
    /// while Foundation standardizes the approved root as /var. Treat that URL
    /// only as a directory-entry reference. Verify its physical parent, then
    /// rebuild the child under the original approved root. The rebuilt URL still
    /// goes through inspect()'s unchanged symlink/owner/O_NOFOLLOW protections.
    static func inventoryChildURL(_ listed: URL, within approvedRoot: URL) throws -> URL {
        let name = listed.lastPathComponent
        guard listed.isFileURL, approvedRoot.isFileURL,
              !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw StartupInspectionError.invalidPath
        }
        let listedParent = listed.deletingLastPathComponent().path
        guard try physicalPath(listedParent) == physicalPath(approvedRoot.path) else {
            throw StartupInspectionError.invalidPath
        }
        var actualParent = stat(), approved = stat()
        guard lstat(listedParent, &actualParent) == 0, lstat(approvedRoot.path, &approved) == 0,
              isDirectory(actualParent), isDirectory(approved), actualParent.st_dev == approved.st_dev,
              actualParent.st_ino == approved.st_ino else { throw StartupInspectionError.changed }
        return URL(fileURLWithPath: approvedRoot.path, isDirectory: true).appendingPathComponent(name, isDirectory: false)
    }

    private static func physicalPath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw StartupInspectionError.invalidPath }
        #if canImport(Darwin)
        guard let value = Darwin.realpath(path, nil) else { throw StartupInspectionError.permission }
        defer { Darwin.free(value) }
        #else
        guard let value = Glibc.realpath(path, nil) else { throw StartupInspectionError.permission }
        defer { Glibc.free(value) }
        #endif
        return String(cString: value)
    }

    #if canImport(Darwin)
    private static let fileTypeMask = mode_t(Darwin.S_IFMT)
    private static let regularFileType = mode_t(Darwin.S_IFREG)
    private static let directoryType = mode_t(Darwin.S_IFDIR)
    #else
    private static let fileTypeMask = mode_t(Glibc.S_IFMT)
    private static let regularFileType = mode_t(Glibc.S_IFREG)
    private static let directoryType = mode_t(Glibc.S_IFDIR)
    #endif
    private static func isDirectory(_ value: stat) -> Bool { (value.st_mode & fileTypeMask) == directoryType }
}

public enum StartupOverride: String, Equatable, Sendable {
    case enabled, disabled, absent
}

public struct StartupLoadedService: Equatable, Sendable {
    public let path: String
    public let program: String
    public let state: String
    public let pid: Int?
}

public enum StartupLoadState: Equatable, Sendable {
    case loaded(StartupLoadedService), notLoaded, unknown(String)
    public var isVerified: Bool { if case .unknown = self { return false }; return true }
    public var isLoaded: Bool { if case .loaded = self { return true }; return false }
}

public enum StartupContractError: LocalizedError {
    case invalidOutput, unsafeTarget, unverifiableState, mismatchedService
    public var errorDescription: String? {
        switch self {
        case .invalidOutput: return "The launchctl response is not a recognized complete format. Controls are disabled."
        case .unsafeTarget: return "This service is outside the supported own-user LaunchAgent boundary."
        case .unverifiableState: return "The service state could not be verified. Refresh before changing it."
        case .mismatchedService: return "The loaded service does not match the inspected plist and executable."
        }
    }
}

public enum LaunchctlOutputParser {
    /// Absence means no explicit launchctl override, not 'enabled'. Both known
    /// boolean and word spellings are accepted; unexpected syntax fails closed.
    public static func disabledOverrides(_ data: Data) throws -> [String: StartupOverride] {
        guard data.count <= 256 * 1_024, let text = String(data: data, encoding: .utf8), !text.contains("\u{1b}") else { throw StartupContractError.invalidOutput }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.first == "disabled services = {", lines.last == "}" else { throw StartupContractError.invalidOutput }
        let expression = try NSRegularExpression(pattern: #"^"([^"\\]+)"\s*=>\s*(true|false|enabled|disabled)\s*;?$"#)
        var result: [String: StartupOverride] = [:]
        for line in lines.dropFirst().dropLast() {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = expression.firstMatch(in: line, range: range), match.range == range,
                  let labelRange = Range(match.range(at: 1), in: line), let valueRange = Range(match.range(at: 2), in: line) else { throw StartupContractError.invalidOutput }
            let label = String(line[labelRange]), value = String(line[valueRange])
            guard !label.isEmpty, label.utf8.count <= 1_024, !label.contains("\0"), result[label] == nil else { throw StartupContractError.invalidOutput }
            result[label] = value == "true" || value == "disabled" ? .disabled : .enabled
        }
        return result
    }

    public static func service(stdout: Data, stderr: Data, exitCode: Int32, domain: String, label: String) throws -> StartupLoadState {
        guard StartupCommandPlan.isSafeLabel(label), validDomain(domain), stdout.count + stderr.count <= 128 * 1_024,
              let output = String(data: stdout, encoding: .utf8), let error = String(data: stderr, encoding: .utf8),
              !output.contains("\u{1b}"), !error.contains("\u{1b}") else { throw StartupContractError.invalidOutput }
        if exitCode != 0 {
            let suffix: String
            if domain.hasPrefix("gui/") { suffix = "for user gui: " + domain.dropFirst(4) }
            else if domain == "system" { suffix = "for system" }
            else { throw StartupContractError.invalidOutput }
            let expected = "Could not find service \"\(label)\" in domain " + suffix
            let lines = (output + "\n" + error).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard exitCode == 113, lines.contains(expected), lines.allSatisfy({ $0 == expected || $0 == "Bad request." }) else { throw StartupContractError.invalidOutput }
            return .notLoaded
        }
        guard error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StartupContractError.invalidOutput }
        let lines = output.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.first == "\(domain)/\(label) = {", lines.last == "}" else { throw StartupContractError.invalidOutput }
        var fields: [String: String] = [:]
        for line in lines.dropFirst().dropLast() {
            // launchctl nested dictionaries are not interpreted. Only a single
            // top-level indentation is allowed for the identity fields we use.
            let top: String
            if line.hasPrefix("\t"), !line.hasPrefix("\t\t") { top = String(line.dropFirst()) }
            else if line.hasPrefix("    "), !line.hasPrefix("     ") { top = String(line.dropFirst(4)) }
            else { continue }
            guard let separator = top.range(of: " = ") else { continue }
            let key = String(top[..<separator.lowerBound])
            guard ["path", "program", "state", "pid"].contains(key) else { continue }
            guard fields[key] == nil else { throw StartupContractError.invalidOutput }
            fields[key] = String(top[separator.upperBound...])
        }
        guard let path = fields["path"], path.hasPrefix("/"), let program = fields["program"], program.hasPrefix("/"),
              let state = fields["state"], !state.isEmpty, state.utf8.count <= 128,
              ![path, program, state].contains(where: { $0.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) }) else { throw StartupContractError.invalidOutput }
        let pid: Int?
        if let raw = fields["pid"] { guard let value = Int(raw), value > 0 else { throw StartupContractError.invalidOutput }; pid = value }
        else { pid = nil }
        return .loaded(.init(path: path, program: program, state: state, pid: pid))
    }

    private static func validDomain(_ value: String) -> Bool {
        if value == "system" { return true }
        guard value.hasPrefix("gui/"), let uid = UInt32(value.dropFirst(4)) else { return false }
        return value == "gui/\(uid)"
    }
}

public struct StartupCommandPlan: Identifiable, Sendable {
    public let id = UUID()
    public let snapshot: StartupPlistSnapshot
    public let enable: Bool
    public let previousOverride: StartupOverride
    public let previousLoadState: StartupLoadState
    public let commands: [[String]]

    public init(snapshot: StartupPlistSnapshot, enable: Bool, previousOverride: StartupOverride,
                loadState: StartupLoadState, userID: UInt32, duplicateLabel: Bool = false) throws {
        guard userID > 0, snapshot.scope == .userAgent, snapshot.identity.owner == userID,
              snapshot.folderIdentity.owner == userID, snapshot.canManageMetadata, !duplicateLabel,
              let label = snapshot.label, Self.isSafeLabel(label) else { throw StartupContractError.unsafeTarget }
        guard loadState.isVerified else { throw StartupContractError.unverifiableState }
        if case .loaded(let service) = loadState {
            guard service.path == snapshot.url.path, service.program == snapshot.executable else { throw StartupContractError.mismatchedService }
        }
        self.snapshot = snapshot; self.enable = enable; self.previousOverride = previousOverride; self.previousLoadState = loadState
        let domain = "gui/\(userID)", target = "gui/\(userID)/\(label)"
        var steps: [[String]] = [[enable ? "enable" : "disable", target]]
        if enable, !loadState.isLoaded { steps.append(["bootstrap", domain, snapshot.url.path]) }
        if !enable, loadState.isLoaded { steps.append(["bootout", target]) }
        commands = steps
    }

    public func matchesFreshState(override: StartupOverride, loadState: StartupLoadState) -> Bool {
        guard override == previousOverride else { return false }
        switch (previousLoadState, loadState) {
        case (.notLoaded, .notLoaded): return true
        case (.loaded(let old), .loaded(let new)): return old.path == new.path && old.program == new.program
        default: return false
        }
    }

    public static func isSafeLabel(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 255,
              let first = value.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first), first.isASCII else { return false }
        return value.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
    }
}
