// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum PurgePathsError: LocalizedError {
    case wrongFile, unsafeFile, changed, invalidText(String), io(Int32)
    public var errorDescription: String? {
        switch self {
        case .wrongFile: return "Only the current user's official Mole purge_paths file can be edited."
        case .unsafeFile: return "The configuration is not a regular user-owned file, is a symbolic link, or exceeds 256 KiB."
        case .changed: return "The configuration changed while this window was open. Cancel, reopen, and review the current file."
        case .invalidText(let text): return text
        case .io(let code): return "Configuration access failed: \(String(cString: strerror(code)))."
        }
    }
}

/// Editor for the documented `$EDITOR "$PURGE_PATHS_CONFIG"` interface.
/// CLI owns creation/reload; this class only edits the exact existing config.
public final class PurgePathsDocument {
    public static let maximumBytes = 256 * 1024
    public let url: URL
    public let originalText: String
    private let original: Data
    private let fingerprint: Fingerprint
    private let parentFingerprint: Fingerprint
    private let home: URL

    private struct Fingerprint: Equatable {
        let device: UInt64, inode: UInt64, size: Int64, mode: UInt32, owner: UInt32
        let modifiedSeconds: Int64, modifiedNanoseconds: Int64
        init(_ value: stat) {
            device = UInt64(truncatingIfNeeded: value.st_dev); inode = UInt64(value.st_ino); size = Int64(value.st_size)
            mode = UInt32(value.st_mode); owner = UInt32(value.st_uid)
            #if canImport(Darwin)
            modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
            #else
            modifiedSeconds = Int64(value.st_mtim.tv_sec); modifiedNanoseconds = Int64(value.st_mtim.tv_nsec)
            #endif
        }
    }

    public convenience init(url: URL) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        try self.init(url: url, expectedURL: home.appendingPathComponent(".config/mole/purge_paths"), home: home)
    }

    /// Explicit expected URL allows isolated tests; the executable always uses
    /// the public single-argument initializer with the actual user's home.
    init(url: URL, expectedURL: URL, home: URL) throws {
        guard url.isFileURL, url.standardizedFileURL == expectedURL.standardizedFileURL else { throw PurgePathsError.wrongFile }
        self.url = url.standardizedFileURL; self.home = home
        try Self.validateNoSymlink(url)
        let parentFD = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw PurgePathsError.io(errno) }
        defer { close(parentFD) }
        var parentStat = stat(); guard fstat(parentFD, &parentStat) == 0 else { throw PurgePathsError.io(errno) }
        parentFingerprint = Fingerprint(parentStat)
        let snapshot = try Self.readSnapshot(parentFD: parentFD, name: url.lastPathComponent)
        original = snapshot.0; fingerprint = snapshot.1
        guard let text = String(data: original, encoding: .utf8) else { throw PurgePathsError.invalidText("Configuration must be valid UTF-8.") }
        originalText = text
    }

    public static func validate(_ text: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        guard text.utf8.count <= maximumBytes else { throw PurgePathsError.invalidText("Configuration exceeds 256 KiB.") }
        guard !text.unicodeScalars.contains(where: { ($0.value < 32 && $0.value != 10) || $0.value == 127 }) else {
            throw PurgePathsError.invalidText("Paths cannot contain control characters, tabs, or carriage returns.")
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count <= 4096 else { throw PurgePathsError.invalidText("There are too many configuration lines.") }
        for (index, raw) in lines.enumerated() {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let path: String
            if line == "~" { path = home.path }
            else if line.hasPrefix("~/") { path = home.appendingPathComponent(String(line.dropFirst(2))).path }
            else if line.hasPrefix("/") { path = line }
            else { throw PurgePathsError.invalidText("Line \(index + 1): use an absolute directory path or ~/.") }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else {
                throw PurgePathsError.invalidText("Line \(index + 1): directory is unavailable: \(line)")
            }
        }
    }

    public func save(_ text: String) throws {
        try Self.validate(text, home: home)
        try Self.validateNoSymlink(url)
        let parentFD = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw PurgePathsError.io(errno) }
        defer { close(parentFD) }
        var directory = stat(); guard fstat(parentFD, &directory) == 0 else { throw PurgePathsError.io(errno) }
        guard UInt64(truncatingIfNeeded: directory.st_dev) == parentFingerprint.device,
              UInt64(directory.st_ino) == parentFingerprint.inode else { throw PurgePathsError.changed }
        let currentFD = openat(parentFD, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard currentFD >= 0 else { throw PurgePathsError.changed }
        defer { close(currentFD) }
        guard flock(currentFD, LOCK_EX | LOCK_NB) == 0 else { throw PurgePathsError.changed }
        defer { _ = flock(currentFD, LOCK_UN) }
        let latest = try Self.readSnapshot(parentFD: parentFD, name: url.lastPathComponent)
        guard latest.0 == original, latest.1 == fingerprint else { throw PurgePathsError.changed }
        let temporaryName = ".mopanel-purge-\(UUID().uuidString)"
        let temporaryFD = openat(parentFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(fingerprint.mode & 0o777))
        guard temporaryFD >= 0 else { throw PurgePathsError.io(errno) }
        var renamed = false
        defer { close(temporaryFD); if !renamed { _ = unlinkat(parentFD, temporaryName, 0) } }
        let data = Data(text.utf8)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let count = write(temporaryFD, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw PurgePathsError.io(errno) }
                offset += count
            }
        }
        guard fchmod(temporaryFD, mode_t(fingerprint.mode & 0o777)) == 0, fsync(temporaryFD) == 0 else { throw PurgePathsError.io(errno) }
        // Compare immediately before commit as well as before preparing the temp.
        let beforeCommit = try Self.readSnapshot(parentFD: parentFD, name: url.lastPathComponent)
        guard beforeCommit.0 == original, beforeCommit.1 == fingerprint else { throw PurgePathsError.changed }
        try Self.validateNoSymlink(url)
        guard renameat(parentFD, temporaryName, parentFD, url.lastPathComponent) == 0 else { throw PurgePathsError.io(errno) }
        renamed = true
        _ = fsync(parentFD)
    }

    private static func validateNoSymlink(_ url: URL) throws {
        guard url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL else { throw PurgePathsError.unsafeFile }
    }

    private static func readSnapshot(parentFD: Int32, name: String) throws -> (Data, Fingerprint) {
        let fd = openat(parentFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw PurgePathsError.io(errno) }
        defer { close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0 else { throw PurgePathsError.io(errno) }
        guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_uid == geteuid(),
              before.st_size >= 0, Int64(before.st_size) <= Int64(maximumBytes) else { throw PurgePathsError.unsafeFile }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw PurgePathsError.io(errno) }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumBytes else { throw PurgePathsError.unsafeFile }
        }
        guard fstat(fd, &after) == 0 else { throw PurgePathsError.io(errno) }
        guard Fingerprint(before) == Fingerprint(after) else { throw PurgePathsError.changed }
        return (data, Fingerprint(before))
    }
}
