// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// This module uses installed Git; it is a MoPanel addition, not a Mole command.
public enum GitWorktreeError: LocalizedError, Sendable {
    case invalidOutput(String), unsafePath, changed, unsupported(String), command(String, Int32), protectedItem, destinationExists
    public var errorDescription: String? {
        switch self {
        case .invalidOutput(let part): return "Unrecognized or incomplete Git output: " + part
        case .unsafePath: return "The selected path or its ownership cannot be verified safely."
        case .changed: return "The repository, worktree, recovery branch, or destination changed. Scan and review again."
        case .unsupported(let reason): return "This Git configuration is not supported: " + reason
        case .command(let name, let code): return "Git did not complete " + name + " (exit " + String(code) + "). No force or manual deletion was attempted."
        case .protectedItem: return "This worktree is protected. Review its protection reasons."
        case .destinationExists: return "The recovery destination already exists or overlaps a registered worktree. Nothing will be overwritten."
        }
    }
}

public enum GitWorktreeGuard: String, CaseIterable, Codable, Sendable {
    case main, bare, locked, prunable, dirty, untracked, ignored, submodule, hiddenIndexChanges,
         privateMetadata, commitDraft, unretainedHistory, specialConfiguration, unverifiable, overlap

    public func explanation(language: String) -> String {
        let zh = language != "en"
        switch self {
        case .main: return zh ? "主工作目錄受到保護。" : "The main worktree is protected."
        case .bare: return zh ? "Bare 倉庫僅供檢視。" : "Bare repositories are read-only here."
        case .locked: return zh ? "Git 已鎖定此工作目錄。" : "Git has locked this worktree."
        case .prunable: return zh ? "Git 將此項目標示為 prunable；MoPanel 不修補或清除其紀錄。" : "Git marks this entry as prunable; MoPanel does not repair or prune it."
        case .dirty: return zh ? "存在已追蹤檔案變更或衝突。" : "Tracked changes or conflicts are present."
        case .untracked: return zh ? "存在未追蹤檔案或巢狀倉庫。" : "Untracked files or nested repositories are present."
        case .ignored: return zh ? "存在被 Git 忽略的檔案；這些內容也必須保留。" : "Git-ignored files are present and must also be preserved."
        case .submodule: return zh ? "含 submodule／gitlink；不支援直接移除。" : "Submodules or gitlinks prevent direct removal."
        case .hiddenIndexChanges: return zh ? "索引使用 skip-worktree 或 assume-unchanged，無法可靠判定檔案是否乾淨。" : "Skip-worktree or assume-unchanged index flags prevent a reliable clean-state check."
        case .privateMetadata: return zh ? "含工作目錄私有設定、refs 或尚未完成的 Git 操作紀錄。" : "Private worktree configuration, refs, or Git operation state is present."
        case .commitDraft: return zh ? "COMMIT_EDITMSG 與 HEAD 的提交訊息不同；無法證明草稿已保留。" : "COMMIT_EDITMSG differs from HEAD's commit message; the draft is not proven to be retained."
        case .unretainedHistory: return zh ? "HEAD reflog 仍有未被目前 HEAD 或本地分支保留的提交。" : "The HEAD reflog contains commits not retained by the current HEAD or local branches."
        case .specialConfiguration: return zh ? "偵測到自訂 filter、sparse、partial clone 或其他不支援的設定。" : "Custom filters, sparse checkout, partial cloning, or other unsupported configuration was found."
        case .unverifiable: return zh ? "無法完整驗證格式、路徑、權限或 Git 狀態。" : "The format, path, permissions, or Git state could not be fully verified."
        case .overlap: return zh ? "工作目錄路徑彼此重疊或包含倉庫中繼資料。" : "Worktree paths overlap each other or repository metadata."
        }
    }
}

public struct GitWorktreeEntry: Equatable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let head: String?
    public let branch: String?
    public let detached: Bool
    public let bare: Bool
    public let lockReason: String?
    public let pruneReason: String?
    public let isMain: Bool
}

public struct GitWorktreeFileIdentity: Equatable, Sendable {
    public let device: UInt64, inode: UInt64
    public let owner: UInt32, mode: UInt32
    public let size: Int64, modifiedSeconds: Int64, modifiedNanoseconds: Int64, changedSeconds: Int64, changedNanoseconds: Int64
    func sameObject(as other: Self) -> Bool {
        device == other.device && inode == other.inode && owner == other.owner && mode == other.mode
    }
}

public struct GitRepositoryIdentity: Equatable, Sendable {
    public let mainPath: String
    public let commonDirectory: String
    let mainIdentity: GitWorktreeFileIdentity
    let commonIdentity: GitWorktreeFileIdentity
    let configurationIdentity: GitWorktreeFileIdentity
}

public struct GitTrackedEntry: Equatable, Sendable {
    public let path: String
    public let mode: String
    public let object: String
}

public struct GitWorktreeProof: Equatable, Sendable {
    public let repository: GitRepositoryIdentity
    public let entry: GitWorktreeEntry
    public let canonicalPath: String
    public let administrativeDirectory: String
    public let trackedEntries: [GitTrackedEntry]
    let directoryIdentity: GitWorktreeFileIdentity
    let administrativeIdentity: GitWorktreeFileIdentity
    let files: [String: GitWorktreeFileIdentity]
    let pointerBytes: [String: Data]
    let reflogHeads: [String]
}

public struct GitWorktreeRow: Identifiable, Sendable {
    public var id: String { entry.id }
    public let entry: GitWorktreeEntry
    public let protection: [GitWorktreeGuard]
    public let detail: String?
    public let proof: GitWorktreeProof?
    public var canRemove: Bool { protection.isEmpty && proof != nil }
}

public struct GitRecoveryPoint: Identifiable, Equatable, Sendable {
    public var id: String { reference }
    public let repository: GitRepositoryIdentity
    public let reference: String
    public let head: String
    public let checkedOutPath: String?
    public var branchName: String { String(reference.dropFirst("refs/heads/".count)) }
}

public struct GitWorktreeInventory: Sendable {
    public let gitVersion: String
    public let repository: GitRepositoryIdentity?
    public let rows: [GitWorktreeRow]
    public let recoveryPoints: [GitRecoveryPoint]
}

public struct GitWorktreeRemovalPlan: Identifiable, Sendable {
    public let id: UUID
    public let proof: GitWorktreeProof
    public let recoveryReference: String
    public let preparedAt: Date
}

public struct GitWorktreeRestorePlan: Identifiable, Sendable {
    public let id: UUID
    public let recovery: GitRecoveryPoint
    public let destination: String
    public let expectedTree: [GitTrackedEntry]
    let parentIdentity: GitWorktreeFileIdentity
    public let preparedAt: Date
}

public struct GitWorktreeOutcome: Sendable {
    public let recoveryReference: String
    public let head: String
    public let recoveryVerified: Bool
    public let mutationStarted: Bool
    public let completedAndVerified: Bool
    public let cancelled: Bool
    public let detail: String?
}

public struct GitWorktreeCommandResult: Sendable {
    public let stdout: Data
    public let exitCode: Int32
    public let cancelled: Bool, timedOut: Bool, truncated: Bool
    public init(stdout: Data, exitCode: Int32, cancelled: Bool = false, timedOut: Bool = false, truncated: Bool = false) {
        self.stdout = stdout; self.exitCode = exitCode; self.cancelled = cancelled; self.timedOut = timedOut; self.truncated = truncated
    }
}

public struct GitWorktreeInvocation: Sendable {
    public let arguments: [String]
    public let repositoryPath: String?
    public let mutating: Bool
    public let operation: String
    public let outputLimit: Int
    public var timeout: TimeInterval { mutating ? 0 : 45 }
}

public typealias GitWorktreeRunner = @Sendable (GitWorktreeInvocation) async throws -> GitWorktreeCommandResult

/// Strict public-format parsers. Human-readable output is never a deletion plan.
public enum GitWorktreeParser {
    public static let maximumOutput = 16 * 1024 * 1024
    public static let maximumWorktrees = 128

    public static func validObject(_ value: String) -> Bool {
        [40, 64].contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    public static func validRecoveryReference(_ value: String) -> Bool {
        guard value.hasPrefix("refs/heads/mopanel-recovery/") else { return false }
        let suffix = String(value.dropFirst("refs/heads/mopanel-recovery/".count))
        return UUID(uuidString: suffix)?.uuidString.lowercased() == suffix
    }
    static func validBranch(_ value: String) -> Bool {
        value.hasPrefix("refs/heads/") && value.utf8.count < 4096 && !value.hasSuffix("/") && !value.hasSuffix(".") &&
        !value.contains("..") && !value.contains("@{") && !value.contains("//") &&
        !value.unicodeScalars.contains { $0.value < 33 || $0.value == 127 || "~^:?*[\\".unicodeScalars.contains($0) }
    }
    static func nulFields(_ data: Data, name: String) throws -> [String] {
        guard data.count <= maximumOutput, data.isEmpty || data.last == 0,
              let text = String(data: data, encoding: .utf8) else { throw GitWorktreeError.invalidOutput(name) }
        if text.isEmpty { return [] }
        return text.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
    }
    public static func list(_ data: Data) throws -> [GitWorktreeEntry] {
        let fields = try nulFields(data, name: "worktree list --porcelain -z")
        guard !fields.isEmpty else { throw GitWorktreeError.invalidOutput("empty worktree list") }
        var records: [[String: String]] = [], current: [String: String] = [:]
        for field in fields {
            if field.isEmpty {
                guard current["worktree"] != nil else { throw GitWorktreeError.invalidOutput("empty worktree record") }
                records.append(current); current = [:]
                guard records.count <= maximumWorktrees else { throw GitWorktreeError.invalidOutput("worktree count limit") }
                continue
            }
            let pair = field.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(pair[0]), value = pair.count == 2 ? String(pair[1]) : ""
            guard ["worktree", "HEAD", "branch", "bare", "detached", "locked", "prunable"].contains(key),
                  current[key] == nil, (!current.isEmpty || key == "worktree") else { throw GitWorktreeError.invalidOutput("worktree attribute") }
            current[key] = value
        }
        guard current.isEmpty, !records.isEmpty else { throw GitWorktreeError.invalidOutput("unterminated worktree record") }
        var paths = Set<String>()
        return try records.enumerated().map { index, record in
            guard let path = record["worktree"], path.hasPrefix("/"), path.utf8.count <= 32768,
                  paths.insert(path).inserted else { throw GitWorktreeError.invalidOutput("worktree path") }
            let bare = record["bare"] != nil, detached = record["detached"] != nil
            guard record["bare"] == nil || record["bare"] == "",
                  record["detached"] == nil || record["detached"] == "" else { throw GitWorktreeError.invalidOutput("boolean attribute") }
            if bare {
                guard index == 0, record["HEAD"] == nil, record["branch"] == nil, !detached else { throw GitWorktreeError.invalidOutput("bare record") }
            } else {
                guard let head = record["HEAD"], validObject(head), (record["branch"] != nil) != detached else { throw GitWorktreeError.invalidOutput("HEAD or branch") }
                if let branch = record["branch"], !validBranch(branch) { throw GitWorktreeError.invalidOutput("branch name") }
            }
            return .init(path: path, head: record["HEAD"], branch: record["branch"], detached: detached, bare: bare,
                         lockReason: record["locked"], pruneReason: record["prunable"], isMain: index == 0)
        }
    }
    public static func statusProtection(_ data: Data) throws -> [GitWorktreeGuard] {
        let fields = try nulFields(data, name: "status porcelain v2")
        var result = Set<GitWorktreeGuard>(), index = 0
        while index < fields.count {
            let field = fields[index]
            guard field.utf8.count > 2 else { throw GitWorktreeError.invalidOutput("status record") }
            if field.hasPrefix("? ") { result.insert(.untracked) }
            else if field.hasPrefix("! ") { result.insert(.ignored) }
            else if field.hasPrefix("1 ") || field.hasPrefix("u ") { result.insert(.dirty) }
            else if field.hasPrefix("2 ") {
                result.insert(.dirty); index += 1
                guard index < fields.count, !fields[index].isEmpty else { throw GitWorktreeError.invalidOutput("rename record") }
            } else { throw GitWorktreeError.invalidOutput("unknown status record") }
            index += 1
        }
        return GitWorktreeGuard.allCases.filter { result.contains($0) }
    }
    public static func indexHasHiddenChanges(_ data: Data) throws -> Bool {
        var hidden = false
        for field in try nulFields(data, name: "ls-files -v") {
            let bytes = Array(field.utf8)
            guard bytes.count > 2, bytes[1] == 32, "HSMRCK?Uhsmrcku".utf8.contains(bytes[0]) else { throw GitWorktreeError.invalidOutput("index flag") }
            if bytes[0] == 83 || (97...122).contains(bytes[0]) { hidden = true }
        }
        return hidden
    }
    public static func trackedEntries(_ data: Data, tree: Bool = false) throws -> [GitTrackedEntry] {
        var seen = Set<String>()
        return try nulFields(data, name: tree ? "ls-tree" : "ls-files --stage").map { field in
            guard let tab = field.firstIndex(of: "\t") else { throw GitWorktreeError.invalidOutput("tracked entry") }
            let header = field[..<tab].split(separator: " "), path = String(field[field.index(after: tab)...])
            guard header.count == 3, !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
                  seen.insert(path).inserted else { throw GitWorktreeError.invalidOutput("tracked path") }
            let mode = String(header[0]), object = String(header[tree ? 2 : 1])
            guard ["100644", "100755", "120000", "160000"].contains(mode), validObject(object),
                  tree ? ["blob", "commit"].contains(String(header[1])) : header[2] == "0" else { throw GitWorktreeError.invalidOutput("tracked mode/object/stage") }
            return .init(path: path, mode: mode, object: object)
        }
    }
}
