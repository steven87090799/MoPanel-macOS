import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A read-only preflight. Ownership alone does not imply access: macOS can
/// reject opening a user-owned cache directory through its privacy policy.
public enum ReviewAccessIssue: String, Sendable {
    case locked, unreadable, notDeletable, unavailable

    public var explanation: String {
        switch self {
        case .locked: return "檔案已鎖定，先保留；可在 Finder 的「取得資訊」檢查。"
        case .unreadable: return "macOS 未允許讀取此項目，無法確認內容與容量，已保留原處。"
        case .notDeletable: return "目前沒有移動此項目的權限，已保留原處。"
        case .unavailable: return "無法確認目前的檔案狀態，請重新掃描。"
        }
    }

    public static func inspect(_ url: URL) -> Self? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .unavailable }
        #if canImport(Darwin)
        if info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) != 0 { return .locked }
        #endif
        // Open only the directory itself, without enumerating its contents or
        // altering permissions. access(2) alone misses privacy-denied folders.
        if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
            guard let directory = opendir(url.path) else { return .unreadable }
            closedir(directory)
        } else if !FileManager.default.isReadableFile(atPath: url.path) { return .unreadable }
        return FileManager.default.isDeletableFile(atPath: url.path) ? nil : .notDeletable
    }

    public static func isPermissionError(_ error: Error) -> Bool {
        var current = error as NSError
        for _ in 0..<8 {
            if current.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(current.code) { return true }
            if current.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(current.code) { return true }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        return false
    }
}

public enum ReviewSelectionState: Equatable, Sendable {
    case none, mixed, all
    public static func resolve(eligible: Set<String>, selected: Set<String>) -> Self {
        let count = eligible.intersection(selected).count
        if count == 0 { return .none }
        return count == eligible.count ? .all : .mixed
    }
}

public struct ReviewRunOutcome: Sendable {
    public let requested: Int
    public let moved: Int
    public let failed: Int
    public let cancelled: Bool
    public var unprocessed: Int { max(0, requested - moved - failed) }
    public var hasUnresolvedItems: Bool { failed > 0 || unprocessed > 0 || cancelled }
    public init(requested: Int, moved: Int, failed: Int, cancelled: Bool) {
        self.requested = requested; self.moved = moved; self.failed = failed; self.cancelled = cancelled
    }
}
