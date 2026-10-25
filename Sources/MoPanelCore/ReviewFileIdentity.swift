import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Captured identity used immediately before a user-approved, recoverable move.
public struct ReviewFileIdentity: Sendable {
    private let device: UInt64
    private let inode: UInt64
    private let kind: UInt32
    private let owner: UInt32
    private let modifiedSeconds: Int64
    private let modifiedNanos: Int64

    public static func capture(_ url: URL, home: String) throws -> Self {
        guard ReviewPathPolicy.permits(url.path, home: home),
              url.resolvingSymlinksInPath().standardizedFileURL.path == url.standardizedFileURL.path else {
            throw MoleError.invalidArgument("Path is outside the review scope or contains a symbolic link.")
        }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) || info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw MoleError.invalidArgument("File is missing, belongs to another user, or is not an ordinary file/directory.")
        }
        #if canImport(Darwin)
        let time = info.st_mtimespec
        #else
        let time = info.st_mtim
        #endif
        return Self(device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(info.st_ino),
                    kind: UInt32(info.st_mode & mode_t(S_IFMT)), owner: UInt32(info.st_uid),
                    modifiedSeconds: Int64(time.tv_sec), modifiedNanos: Int64(time.tv_nsec))
    }

    public func stillMatches(_ url: URL, home: String) -> Bool {
        guard let current = try? Self.capture(url, home: home),
              device == current.device, inode == current.inode, owner == current.owner, kind == current.kind else { return false }
        // Selecting a directory means its contents, which may gain new cache files.
        return kind == UInt32(S_IFDIR) || (modifiedSeconds == current.modifiedSeconds && modifiedNanos == current.modifiedNanos)
    }
}
