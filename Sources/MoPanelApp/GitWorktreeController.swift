// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import MoPanelCore
import MoPanelProcess

/// Optional native service. Initialization performs no inventory or Git calls.
@MainActor final class GitWorktreeController: ObservableObject {
    @Published var language: String
    @Published private(set) var isBusy = false
    @Published private(set) var activity = ""
    @Published private(set) var rows: [GitWorktreeRow] = []
    @Published private(set) var recoveryPoints: [GitRecoveryPoint] = []
    @Published private(set) var selectedRepository: URL?
    @Published private(set) var gitPath: String?
    @Published private(set) var gitVersion: String?
    @Published private(set) var hasLoaded = false
    @Published private(set) var lastOutcome = ""
    @Published private(set) var lastRecoveryReference: String?
    @Published private(set) var cancellationRequested = false
    @Published var pendingRemoval: GitWorktreeRemovalPlan?
    @Published var pendingRestore: GitWorktreeRestorePlan?
    @Published var errorMessage: String?
    var externalOperationInProgress: (() -> Bool)?
    let actionsAllowed: Bool

    private let helperURL: URL?
    private var tool: GitWorktreeExecutable?
    private var reviewedTool: GitWorktreeExecutable?
    private var activeProcess: ManagedProcess?
    private var mutationOperation = false
    private var shuttingDown = false
    private var terminationObserver: NSObjectProtocol?

    init(language: String = "zh-Hant", helperURL: URL? = nil) {
        self.language = language; self.helperURL = helperURL
        actionsAllowed = !ReadOnlyBenchmark.isTestLaunch(ProcessInfo.processInfo.arguments)
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                      object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
    }
    deinit { if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) } }
    func t(_ zh: String, _ en: String) -> String { language == "en" ? en : zh }

    func chooseRepository() {
        guard canBeginAction() else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = t("選擇你要管理的 Git 倉庫或 linked worktree。只檢查此倉庫，不搜尋個人資料夾。",
                          "Choose the Git repository or linked worktree to manage. Only this repository is inspected; personal folders are not searched.")
        if panel.runModal() == .OK, let url = panel.url {
            selectedRepository = url; rows = []; recoveryPoints = []; hasLoaded = false
            pendingRemoval = nil; pendingRestore = nil; reviewedTool = nil
            lastOutcome = ""; lastRecoveryReference = nil
            Task { await refresh() }
        }
    }

    func refresh() async {
        guard let selectedRepository, begin(t("檢查 Git worktrees…", "Checking Git worktrees…")) else { return }
        defer { finish() }
        pendingRemoval = nil; pendingRestore = nil; reviewedTool = nil
        do {
            try await loadTool()
            let result = try await service().scan(repository: selectedRepository)
            try checkCancellation()
            accept(result)
            activity = t("已完成保護檢查；不會自動選取或移除任何工作目錄。", "Protection checks finished. No worktree is automatically selected or removed.")
        } catch {
            rows = []; recoveryPoints = []; hasLoaded = false
            report(error)
        }
    }

    func prepareRemoval(_ row: GitWorktreeRow) async {
        guard row.canRemove, begin(t("重驗選定工作目錄…", "Rechecking the selected worktree…")) else { return }
        defer { finish() }
        pendingRemoval = nil; pendingRestore = nil; reviewedTool = nil
        do {
            try await loadTool()
            let plan = try await service().prepareRemoval(row)
            try checkCancellation()
            reviewedTool = tool; pendingRemoval = plan
            activity = t("預覽已備妥；尚未建立分支或移除檔案。", "The preview is ready. No branch was created and no files were removed.")
        } catch { report(error) }
    }

    func confirmRemoval(_ plan: GitWorktreeRemovalPlan) async {
        guard pendingRemoval?.id == plan.id, let expected = reviewedTool,
              begin(t("建立復原點並由 Git 移除…", "Creating a recovery point, then removing through Git…"), mutation: true) else { return }
        pendingRemoval = nil; pendingRestore = nil
        defer { finish() }
        do {
            try await loadTool(expected: expected)
            let result = await service().remove(plan)
            lastRecoveryReference = result.recoveryReference
            lastOutcome = outcomeText(result, restoring: false)
            // A cancelled or failed removal can be partial. Invalidate the old
            // rows instead of letting an old preview be reused.
            rows = []; recoveryPoints = []; hasLoaded = false
            if result.completedAndVerified { await refreshWithinOperation() }
        } catch { report(error) }
    }

    func chooseRestoreDestination(_ recovery: GitRecoveryPoint) {
        guard recovery.checkedOutPath == nil, canBeginAction() else { return }
        let panel = NSSavePanel()
        panel.title = t("選擇新的工作目錄位置", "Choose a New Worktree Location")
        panel.message = t("目的地必須尚不存在。Git 會由保留分支重建已提交內容；不會覆寫原路徑，也不復原已忽略檔案或外部資料。",
                          "The destination must not exist. Git reconstructs committed contents from the recovery branch. Existing paths are never overwritten; ignored files and external data are not restored.")
        panel.nameFieldStringValue = "recovered-worktree"
        panel.canCreateDirectories = false
        if panel.runModal() == .OK, let destination = panel.url {
            Task { await prepareRestore(recovery, destination: destination) }
        }
    }

    func prepareRestore(_ recovery: GitRecoveryPoint, destination: URL) async {
        guard begin(t("檢查復原分支與新目的地…", "Checking the recovery branch and new destination…")) else { return }
        defer { finish() }
        pendingRemoval = nil; pendingRestore = nil; reviewedTool = nil
        do {
            try await loadTool()
            let plan = try await service().prepareRestore(recovery, destination: destination)
            try checkCancellation()
            reviewedTool = tool; pendingRestore = plan
            activity = t("復原預覽已備妥；尚未建立目的地。", "The recovery preview is ready. The destination has not been created.")
        } catch { report(error) }
    }

    func confirmRestore(_ plan: GitWorktreeRestorePlan) async {
        guard pendingRestore?.id == plan.id, let expected = reviewedTool,
              begin(t("由保留分支重建工作目錄…", "Rebuilding the worktree from its retained branch…"), mutation: true) else { return }
        pendingRemoval = nil; pendingRestore = nil
        defer { finish() }
        do {
            try await loadTool(expected: expected)
            let result = await service().restore(plan)
            lastRecoveryReference = result.recoveryReference
            lastOutcome = outcomeText(result, restoring: true)
            rows = []; recoveryPoints = []; hasLoaded = false
            if result.completedAndVerified { await refreshWithinOperation() }
        } catch { report(error) }
    }

    func cancelReview() {
        if pendingRemoval != nil { pendingRemoval = nil }
        if pendingRestore != nil { pendingRestore = nil }
        reviewedTool = nil
    }
    func cancelReadOnly() {
        cancelReview()
        if isBusy && !mutationOperation { requestCancellation() }
    }
    func requestCancellation() {
        guard isBusy else { cancelReview(); return }
        guard !cancellationRequested else { return }
        cancellationRequested = true; cancelReview(); activeProcess?.cancel()
        activity = t("已要求停止，等待 Git 結束。復原分支會保留，檔案或中繼資料可能已部分變更。",
                     "Stop requested; waiting for Git to exit. Recovery branches remain, and files or metadata may already be partially changed.")
    }
    func shutdown() { shuttingDown = true; requestCancellation() }
    func reveal(_ path: String) {
        guard actionsAllowed, !shuttingDown else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
    func copyReference(_ reference: String) {
        guard actionsAllowed, GitWorktreeParser.validRecoveryReference(reference) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(reference, forType: .string)
    }

    private func canBeginAction() -> Bool {
        guard actionsAllowed, !shuttingDown, getuid() > 0, geteuid() == getuid() else {
            errorMessage = t("測試／效能模式或 root 執行不會存取真實 Git 倉庫。", "Test/benchmark launches and root execution do not access real Git repositories.")
            return false
        }
        guard !isBusy else { return false }
        guard externalOperationInProgress?() != true else {
            errorMessage = t("其他作業仍在執行，請完成或停止後再試。", "Another operation is active. Finish or stop it first.")
            return false
        }
        return true
    }
    private func begin(_ message: String, mutation: Bool = false) -> Bool {
        guard canBeginAction() else { return false }
        isBusy = true; mutationOperation = mutation; cancellationRequested = false; errorMessage = nil; activity = message
        return true
    }
    private func finish() { activeProcess = nil; isBusy = false; mutationOperation = false }
    private func checkCancellation() throws { if cancellationRequested || shuttingDown || Task.isCancelled { throw CancellationError() } }
    private func service() -> GitWorktreeService {
        GitWorktreeService { [weak self] invocation in
            guard let self else { throw CancellationError() }
            return try await self.execute(invocation)
        }
    }
    private func loadTool(expected: GitWorktreeExecutable? = nil) async throws {
        try checkCancellation()
        let candidate = try await Task.detached(priority: .userInitiated) { try GitWorktreeExecutable.discover() }.value
        try checkCancellation()
        if let expected, expected != candidate { throw GitWorktreeError.changed }
        tool = candidate; gitPath = candidate.path
    }
    private func execute(_ invocation: GitWorktreeInvocation) async throws -> GitWorktreeCommandResult {
        try checkCancellation()
        guard actionsAllowed, isBusy, let tool else { throw GitWorktreeError.unsafePath }
        try tool.verifyMetadata()
        activity = t("Git：", "Git: ") + invocation.operation
        let child = ManagedProcess(helperURL: helperURL)
        activeProcess = child
        defer { activeProcess = nil }
        try child.start(request: .init(executable: URL(fileURLWithPath: tool.path), arguments: invocation.arguments,
                                       environment: GitWorktreeService.protectiveEnvironment,
                                       workingDirectory: invocation.repositoryPath.map { URL(fileURLWithPath: $0, isDirectory: true) },
                                       timeout: invocation.timeout, outputLimit: invocation.outputLimit,
                                       cooperativeCancellation: invocation.mutating))
        let result = await child.wait()
        return .init(stdout: result.stdout, exitCode: result.exitCode, cancelled: result.cancelled || cancellationRequested || shuttingDown,
                     timedOut: result.timedOut, truncated: result.outputTruncated)
    }
    private func accept(_ inventory: GitWorktreeInventory) {
        rows = inventory.rows; recoveryPoints = inventory.recoveryPoints; gitVersion = inventory.gitVersion; hasLoaded = true
    }
    private func refreshWithinOperation() async {
        guard !cancellationRequested, let selectedRepository else { return }
        mutationOperation = false
        do { accept(try await service().scan(repository: selectedRepository)) }
        catch { lastOutcome += "\n" + t("作業結果已記錄，但重新整理未完成；請再掃描。", "The outcome was recorded, but refresh did not finish. Scan again.") }
    }
    private func report(_ error: Error) {
        if error is CancellationError { activity = t("已停止檢查；尚未確認的操作不會執行。", "Checks stopped. Unconfirmed actions will not run.") }
        else { errorMessage = t("Git 操作無法完成：", "Git operation could not finish: ") + error.localizedDescription }
    }
    private func outcomeText(_ outcome: GitWorktreeOutcome, restoring: Bool) -> String {
        var result: String
        if outcome.completedAndVerified {
            result = restoring
                ? t("已由 Git 重建工作目錄，並驗證 HEAD、索引內容與乾淨狀態。保留分支仍在原倉庫中。", "Git rebuilt the worktree. HEAD, tracked entries and clean status were verified. The recovery branch remains in the original repository.")
                : t("Git 已移除選定工作目錄；已確認路徑消失及復原分支指向原 HEAD。此功能不刪除既有分支。", "Git removed the selected worktree. Path removal and the recovery branch's exact HEAD were verified. This feature does not delete existing branches.")
        } else if outcome.mutationStarted {
            result = t("操作未完成驗證。檔案或 Git 中繼資料可能已部分變更；MoPanel 不會自行刪除剩餘檔案或強制回復。請重新掃描。",
                       "The operation did not complete verification. Files or Git metadata may have changed partially. MoPanel does not manually delete leftovers or force rollback. Scan again.")
        } else {
            result = t("尚未呼叫 Git 移除／重建工作目錄。可能已建立保留分支；請重新掃描確認。", "Git worktree removal/reconstruction was not started. A recovery branch may have been created; scan again to verify.")
        }
        if outcome.cancelled { result = t("已要求停止。", "Stop was requested. ") + result }
        result += "\n" + t("復原 ref：", "Recovery ref: ") + outcome.recoveryReference
        result += "\nHEAD: " + outcome.head
        if !outcome.completedAndVerified {
            result += "\n" + (outcome.recoveryVerified ? t("此 ref 已建立並讀回確認；不會自動移除。", "This ref was created and verified; it will not be removed automatically.") : t("本次未完成 ref 狀態驗證；請重新掃描，勿假設成功。", "The ref state was not fully verified in this attempt. Scan again; do not assume success."))
        }
        if let detail = outcome.detail { result += "\n" + t("執行摘要：", "Execution summary: ") + detail }
        return result
    }
}

private struct GitWorktreeExecutable: Equatable, Sendable {
    let path: String
    let device: UInt64, inode: UInt64, size: Int64, modifiedSeconds: Int64, modifiedNanoseconds: Int64,
        changedSeconds: Int64, changedNanoseconds: Int64, owner: UInt32, mode: UInt32
    let digest: String
    static func discover() throws -> Self {
        for selected in ["/opt/homebrew/bin/git", "/usr/bin/git"] where FileManager.default.isExecutableFile(atPath: selected) {
            guard let pointer = realpath(selected, nil) else { continue }
            let canonical = String(cString: pointer); free(pointer)
            let standard = canonical == "/usr/bin/git" || canonical.range(of: #"^/opt/homebrew/Cellar/git/[^/]+/bin/git$"#, options: .regularExpression) != nil
            guard standard else { continue }
            let metadata = try attributes(canonical)
            guard metadata.st_size > 0, metadata.st_size <= 64 * 1024 * 1024 else { continue }
            let descriptor = open(canonical, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw GitWorktreeError.unsafePath }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, opened.st_dev == metadata.st_dev, opened.st_ino == metadata.st_ino,
                  opened.st_size == metadata.st_size else { throw GitWorktreeError.changed }
            var hash = SHA256()
            var total = 0
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                total += data.count
                guard total <= Int(metadata.st_size) else { throw GitWorktreeError.changed }
                hash.update(data: data)
            }
            guard total == Int(metadata.st_size) else { throw GitWorktreeError.changed }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            let proof = Self(path: canonical, device: UInt64(truncatingIfNeeded: metadata.st_dev), inode: UInt64(metadata.st_ino),
                             size: Int64(metadata.st_size), modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
                             changedSeconds: Int64(metadata.st_ctimespec.tv_sec), changedNanoseconds: Int64(metadata.st_ctimespec.tv_nsec), owner: metadata.st_uid,
                             mode: UInt32(metadata.st_mode), digest: digest)
            try proof.verifyMetadata()
            return proof
        }
        throw GitWorktreeError.unsupported("Install a current Git through Apple's developer tools or your existing Homebrew. MoPanel does not install Git automatically.")
    }
    private static func attributes(_ path: String) throws -> stat {
        var value = stat()
        guard lstat(path, &value) == 0, value.st_mode & Darwin.S_IFMT == Darwin.S_IFREG,
              [0, getuid()].contains(value.st_uid), value.st_mode & 0o022 == 0 else { throw GitWorktreeError.unsafePath }
        return value
    }
    func verifyMetadata() throws {
        let value = try Self.attributes(path)
        guard UInt64(truncatingIfNeeded: value.st_dev) == device, UInt64(value.st_ino) == inode,
              Int64(value.st_size) == size, Int64(value.st_mtimespec.tv_sec) == modifiedSeconds,
              Int64(value.st_mtimespec.tv_nsec) == modifiedNanoseconds,
              Int64(value.st_ctimespec.tv_sec) == changedSeconds, Int64(value.st_ctimespec.tv_nsec) == changedNanoseconds,
              value.st_uid == owner, UInt32(value.st_mode) == mode else { throw GitWorktreeError.changed }
    }
}
