// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// No Process, shell, network, or recursive deletion lives in this service.
/// Production uses MoPanel's owned-process runner; tests use fresh Git repos.
public struct GitWorktreeService: Sendable {
    private let runner: GitWorktreeRunner
    public init(runner: @escaping GitWorktreeRunner) { self.runner = runner }

    public static let protectiveEnvironment = [
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0", "GIT_ATTR_NOSYSTEM": "1"
    ]
    public static let commandPrefix = [
        "--no-pager", "--no-optional-locks", "--no-lazy-fetch", "--no-replace-objects", "--literal-pathspecs",
        "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false",
        "-c", "core.attributesFile=/dev/null", "-c", "core.trustctime=true", "-c", "core.checkStat=default",
        "-c", "core.ignoreStat=false", "-c", "gc.auto=0", "-c", "maintenance.auto=false",
        "-c", "protocol.allow=never", "-c", "submodule.recurse=false", "-c", "color.ui=false"
    ]

    public func scan(repository selected: URL) async throws -> GitWorktreeInventory {
        let version = try await validateCapabilities()
        let selectedPath = try GitWorktreeFS.directory(selected.path).path
        let entries = try await list(at: selectedPath)
        guard let first = entries.first else { throw GitWorktreeError.invalidOutput("worktree list") }
        if first.bare {
            return .init(gitVersion: version, repository: nil,
                         rows: entries.map { .init(entry: $0, protection: [.bare], detail: nil, proof: nil) }, recoveryPoints: [])
        }
        let repository = try await repositoryIdentity(main: first.path)
        let selectedCommon = try await resolvedDirectory(at: selectedPath, option: "--git-common-dir")
        guard selectedCommon.path == repository.commonDirectory else { throw GitWorktreeError.changed }
        var rows: [GitWorktreeRow] = []
        for entry in entries {
            try Task.checkCancellation()
            rows.append(try await inspect(entry, in: repository, all: entries))
        }
        try await verifyRepository(repository)
        guard try await list(at: repository.mainPath) == entries else { throw GitWorktreeError.changed }
        let recovery = try await recoveryPoints(repository: repository, entries: entries)
        return .init(gitVersion: version, repository: repository, rows: rows, recoveryPoints: recovery)
    }

    /// This is a read-only review, not a pretend `git worktree remove --dry-run`.
    public func prepareRemoval(_ row: GitWorktreeRow, recoveryID: UUID = UUID()) async throws -> GitWorktreeRemovalPlan {
        guard row.canRemove, let previous = row.proof else { throw GitWorktreeError.protectedItem }
        _ = try await validateCapabilities()
        let fresh = try await revalidate(previous)
        let reference = "refs/heads/mopanel-recovery/" + recoveryID.uuidString.lowercased()
        guard !(try await referenceExists(reference, at: fresh.repository.mainPath)) else {
            throw GitWorktreeError.changed
        }
        return .init(id: recoveryID, proof: fresh, recoveryReference: reference, preparedAt: Date())
    }

    /// Only a reviewed plan can reach mutations. A recovery ref is never removed
    /// on errors/cancellation: Git removal is not an atomic filesystem snapshot.
    public func remove(_ plan: GitWorktreeRemovalPlan) async -> GitWorktreeOutcome {
        let head = plan.proof.entry.head ?? ""
        var refVerified = false, removalStarted = false
        do {
            try requireCurrent(plan.preparedAt)
            guard GitWorktreeParser.validRecoveryReference(plan.recoveryReference), GitWorktreeParser.validObject(head) else {
                throw GitWorktreeError.protectedItem
            }
            _ = try await validateCapabilities()
            _ = try await revalidate(plan.proof)
            // Git 2.51's zero-old-OID update can replace a dangling symbolic
            // ref. Check raw ref existence immediately before creation; do not
            // mistake rev-parse's failure to resolve an object for absence.
            guard !(try await referenceExists(plan.recoveryReference, at: plan.proof.repository.mainPath)) else { throw GitWorktreeError.changed }
            _ = try await run(at: plan.proof.repository.mainPath,
                             arguments: ["-c", "user.name=MoPanel Recovery", "-c", "user.email=recovery@mopanel.invalid",
                                         "update-ref", "--no-deref", "--create-reflog", plan.recoveryReference, head,
                                         String(repeating: "0", count: head.count)], operation: "create recovery branch", mutating: true)
            guard try await directRecoveryValue(plan.recoveryReference, at: plan.proof.repository.mainPath) == head else { throw GitWorktreeError.changed }
            refVerified = true
            _ = try await revalidate(plan.proof)
            guard try await directRecoveryValue(plan.recoveryReference, at: plan.proof.repository.mainPath) == head else { throw GitWorktreeError.changed }
            try Task.checkCancellation()
            removalStarted = true
            _ = try await run(at: plan.proof.repository.mainPath,
                             arguments: ["worktree", "remove", "--", plan.proof.canonicalPath], operation: "worktree remove", mutating: true)
            try await verifyRepository(plan.proof.repository)
            let remaining = try await list(at: plan.proof.repository.mainPath)
            guard !remaining.contains(where: { $0.path == plan.proof.entry.path }),
                  try GitWorktreeFS.isAbsent(plan.proof.canonicalPath),
                  try await directRecoveryValue(plan.recoveryReference, at: plan.proof.repository.mainPath) == head else { throw GitWorktreeError.changed }
            if let original = plan.proof.entry.branch {
                guard try await referenceValue(original, at: plan.proof.repository.mainPath) == head else { throw GitWorktreeError.changed }
            }
            return .init(recoveryReference: plan.recoveryReference, head: head, recoveryVerified: true,
                         mutationStarted: true, completedAndVerified: true, cancelled: false, detail: nil)
        } catch {
            return .init(recoveryReference: plan.recoveryReference, head: head, recoveryVerified: refVerified,
                         mutationStarted: removalStarted, completedAndVerified: false,
                         cancelled: error is CancellationError, detail: error.localizedDescription)
        }
    }

    public func prepareRestore(_ recovery: GitRecoveryPoint, destination: URL) async throws -> GitWorktreeRestorePlan {
        _ = try await validateCapabilities()
        try await verifyRecovery(recovery)
        let tree = try await recoveryTree(recovery)
        let entries = try await list(at: recovery.repository.mainPath)
        let target = try GitWorktreeFS.newDestination(destination, repository: recovery.repository, entries: entries)
        return .init(id: UUID(), recovery: recovery, destination: target.path, expectedTree: tree,
                     parentIdentity: target.parent, preparedAt: Date())
    }

    public func restore(_ plan: GitWorktreeRestorePlan) async -> GitWorktreeOutcome {
        var started = false
        do {
            try requireCurrent(plan.preparedAt)
            _ = try await validateCapabilities()
            try await verifyRecovery(plan.recovery)
            guard try await recoveryTree(plan.recovery) == plan.expectedTree else { throw GitWorktreeError.changed }
            let entries = try await list(at: plan.recovery.repository.mainPath)
            let target = try GitWorktreeFS.newDestination(URL(fileURLWithPath: plan.destination), repository: plan.recovery.repository, entries: entries)
            guard target.path == plan.destination, target.parent == plan.parentIdentity else { throw GitWorktreeError.changed }
            try Task.checkCancellation()
            started = true
            _ = try await run(at: plan.recovery.repository.mainPath,
                             arguments: ["worktree", "add", "--no-guess-remote", "--", plan.destination, plan.recovery.branchName],
                             operation: "worktree restore", mutating: true)
            try await verifyRepository(plan.recovery.repository)
            guard try await directRecoveryValue(plan.recovery.reference, at: plan.recovery.repository.mainPath) == plan.recovery.head else { throw GitWorktreeError.changed }
            let freshEntries = try await list(at: plan.recovery.repository.mainPath)
            guard let restored = freshEntries.first(where: { (try? GitWorktreeFS.directory($0.path).path) == plan.destination }),
                  restored.head == plan.recovery.head, restored.branch == plan.recovery.reference else { throw GitWorktreeError.changed }
            let row = try await inspect(restored, in: plan.recovery.repository, all: freshEntries)
            guard row.canRemove, row.proof?.trackedEntries == plan.expectedTree else { throw GitWorktreeError.changed }
            return .init(recoveryReference: plan.recovery.reference, head: plan.recovery.head, recoveryVerified: true,
                         mutationStarted: true, completedAndVerified: true, cancelled: false, detail: nil)
        } catch {
            return .init(recoveryReference: plan.recovery.reference, head: plan.recovery.head, recoveryVerified: false,
                         mutationStarted: started, completedAndVerified: false, cancelled: error is CancellationError,
                         detail: error.localizedDescription)
        }
    }

    private func run(at path: String?, arguments: [String], operation: String, mutating: Bool = false,
                     allowedExitCodes: Set<Int32> = [0]) async throws -> GitWorktreeCommandResult {
        try Task.checkCancellation()
        guard arguments.allSatisfy({ !$0.utf8.contains(0) }), arguments.count <= 3072,
              path == nil || (path!.hasPrefix("/") && !path!.utf8.contains(0)) else { throw GitWorktreeError.unsafePath }
        let invocation = GitWorktreeInvocation(arguments: Self.commandPrefix + (path.map { ["-C", $0] } ?? []) + arguments,
                                              repositoryPath: path, mutating: mutating, operation: operation,
                                              outputLimit: GitWorktreeParser.maximumOutput)
        let result = try await runner(invocation)
        if result.cancelled || Task.isCancelled { throw CancellationError() }
        guard !result.timedOut, !result.truncated, result.stdout.count <= invocation.outputLimit else {
            throw GitWorktreeError.invalidOutput(operation + " timed out or exceeded its output bound")
        }
        guard allowedExitCodes.contains(result.exitCode) else { throw GitWorktreeError.command(operation, result.exitCode) }
        return result
    }

    private func validateCapabilities() async throws -> String {
        let result: GitWorktreeCommandResult
        do { result = try await run(at: nil, arguments: ["--version"], operation: "protective Git capability probe") }
        catch GitWorktreeError.command(_, 129) {
            throw GitWorktreeError.unsupported("Required protective flags, including --no-lazy-fetch, are unavailable. Update the installed Git; these protections are not silently omitted.")
        }
        guard let version = String(data: result.stdout, encoding: .utf8),
              version.range(of: #"^git version [2-9]\.[0-9]+(\.[0-9]+)?[^\r\n]*\n?$"#, options: .regularExpression) != nil else {
            throw GitWorktreeError.unsupported("protective global flags or version output")
        }
        return version.trimmingCharacters(in: .newlines)
    }
    private func list(at path: String) async throws -> [GitWorktreeEntry] {
        try GitWorktreeParser.list(await run(at: path, arguments: ["worktree", "list", "--porcelain", "-z"], operation: "worktree inventory").stdout)
    }
    private func singleLine(_ data: Data, name: String) throws -> String {
        guard data.count < 32768, let text = String(data: data, encoding: .utf8), text.hasSuffix("\n"), !text.utf8.contains(0) else {
            throw GitWorktreeError.invalidOutput(name)
        }
        // Path values may themselves contain newlines: remove exactly Git's one
        // terminator, never split lines or trim path whitespace.
        return String(text.dropLast())
    }
    private func resolvedDirectory(at path: String, option: String) async throws -> (path: String, identity: GitWorktreeFileIdentity) {
        let value = try singleLine(await run(at: path, arguments: ["rev-parse", "--path-format=absolute", option], operation: "repository path").stdout, name: option)
        return try GitWorktreeFS.directory(value)
    }
    private func repositoryIdentity(main raw: String) async throws -> GitRepositoryIdentity {
        let main = try GitWorktreeFS.directory(raw)
        let bare = try singleLine(await run(at: main.path, arguments: ["rev-parse", "--is-bare-repository"], operation: "repository kind").stdout, name: "bare flag")
        guard bare == "false" else { throw GitWorktreeError.protectedItem }
        let root = try await resolvedDirectory(at: main.path, option: "--show-toplevel")
        let common = try await resolvedDirectory(at: main.path, option: "--git-common-dir")
        let actualGit = try await resolvedDirectory(at: main.path, option: "--absolute-git-dir")
        guard root.path == main.path, common.path == actualGit.path else { throw GitWorktreeError.changed }
        let configuration = try GitWorktreeFS.regularFile(common.path + "/config")
        return .init(mainPath: main.path, commonDirectory: common.path, mainIdentity: main.identity,
                     commonIdentity: common.identity, configurationIdentity: configuration)
    }
    private func verifyRepository(_ expected: GitRepositoryIdentity) async throws {
        guard try await repositoryIdentity(main: expected.mainPath) == expected else { throw GitWorktreeError.changed }
    }

    private func specialConfiguration(at path: String) async throws -> Bool {
        // Names only: do not display or retain credentials, URLs, or filter
        // command strings from a repository's configuration. Includes are
        // refused so another file cannot silently change this review later.
        let pattern = #"^(filter\.|include\.|includeif\.|submodule\.|worktree\.userelativepaths$|core\.(sparsecheckout|sparsecheckoutcone|worktree)$|extensions\.(partialclone|worktreeconfig|refstorage)$|remote\..*\.promisor$)"#
        let result = try await run(at: path, arguments: ["config", "--local", "--null", "--name-only", "--get-regexp", pattern],
                                   operation: "supported repository configuration", allowedExitCodes: [0, 1])
        if result.exitCode == 1 {
            guard result.stdout.isEmpty else { throw GitWorktreeError.invalidOutput("configuration exit status") }
            return false
        }
        guard !(try GitWorktreeParser.nulFields(result.stdout, name: "configuration names")).isEmpty else { throw GitWorktreeError.invalidOutput("configuration names") }
        return true
    }

    private func inspect(_ entry: GitWorktreeEntry, in repository: GitRepositoryIdentity, all: [GitWorktreeEntry]) async throws -> GitWorktreeRow {
        var reasons: [GitWorktreeGuard] = []
        if entry.isMain { reasons.append(.main) }
        if entry.bare { reasons.append(.bare) }
        if entry.lockReason != nil { reasons.append(.locked) }
        if entry.pruneReason != nil { reasons.append(.prunable) }
        if !reasons.isEmpty { return .init(entry: entry, protection: reasons, detail: nil, proof: nil) }
        do {
            let directory = try GitWorktreeFS.directory(entry.path)
            let admin = try await resolvedDirectory(at: directory.path, option: "--absolute-git-dir")
            let common = try await resolvedDirectory(at: directory.path, option: "--git-common-dir")
            let top = try await resolvedDirectory(at: directory.path, option: "--show-toplevel")
            guard common.path == repository.commonDirectory, top.path == directory.path,
                  admin.path != common.path, URL(fileURLWithPath: admin.path).deletingLastPathComponent().path == repository.commonDirectory + "/worktrees" else {
                throw GitWorktreeError.changed
            }
            _ = try GitWorktreeFS.directory(repository.commonDirectory + "/worktrees")
            let otherPaths = try all.filter { $0.id != entry.id && $0.pruneReason == nil && !$0.bare }.map { try GitWorktreeFS.directory($0.path).path }
            if otherPaths.contains(where: { GitWorktreeFS.overlap($0, directory.path) }) || GitWorktreeFS.overlap(directory.path, repository.commonDirectory) {
                reasons.append(.overlap)
            }
            if try await specialConfiguration(at: directory.path) || unsupportedObjectStorage(repository) { reasons.append(.specialConfiguration) }
            let metadata = try GitWorktreeFS.metadata(worktree: directory.path, administrative: admin.path)
            if metadata.hasPrivateMetadata { reasons.append(.privateMetadata) }
            if !reasons.isEmpty { return .init(entry: entry, protection: reasons, detail: nil, proof: nil) }
            if let draft = metadata.bytes["COMMIT_EDITMSG"], let head = entry.head {
                let object = try await run(at: directory.path, arguments: ["cat-file", "commit", head], operation: "retained commit message")
                guard let separator = object.stdout.range(of: Data([10, 10])) else { throw GitWorktreeError.invalidOutput("commit message") }
                if Data(object.stdout[separator.upperBound...]) != draft {
                    return .init(entry: entry, protection: [.commitDraft], detail: nil, proof: nil)
                }
            }

            let index = try GitWorktreeParser.trackedEntries(await run(at: directory.path, arguments: ["ls-files", "--stage", "-z"], operation: "tracked index").stdout)
            if index.contains(where: { $0.mode == "160000" }) { reasons.append(.submodule) }
            if try GitWorktreeParser.indexHasHiddenChanges(await run(at: directory.path, arguments: ["ls-files", "-v", "-z"], operation: "index flags").stdout) {
                reasons.append(.hiddenIndexChanges)
            }
            // Do not ask status to recurse into an already-protected submodule.
            if reasons.isEmpty {
                let status = try await run(at: directory.path,
                                          arguments: ["status", "--porcelain=v2", "-z", "--untracked-files=all", "--ignored=matching", "--ignore-submodules=none"],
                                          operation: "tracked, untracked and ignored status")
                reasons += try GitWorktreeParser.statusProtection(status.stdout)
            }
            if !reasons.isEmpty { return .init(entry: entry, protection: reasons, detail: nil, proof: nil) }
            let privateRefs = try await run(at: directory.path,
                                            arguments: ["for-each-ref", "--format=%(refname)%00%(objectname)%00", "refs/bisect/", "refs/worktree/", "refs/rewritten/"],
                                            operation: "private refs")
            if !privateRefs.stdout.isEmpty { return .init(entry: entry, protection: [.privateMetadata], detail: nil, proof: nil) }
            let log = try await run(at: directory.path, arguments: ["reflog", "show", "--max-count=2049", "--format=%H", "HEAD", "--"], operation: "HEAD reflog")
            guard let logText = String(data: log.stdout, encoding: .utf8), logText.isEmpty || logText.hasSuffix("\n") else { throw GitWorktreeError.invalidOutput("HEAD reflog") }
            var logHeads = logText.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
            guard logHeads.count <= 2048, logHeads.allSatisfy(GitWorktreeParser.validObject), let head = entry.head else {
                throw GitWorktreeError.invalidOutput("HEAD reflog bound or object")
            }
            // Git's normal worktree add/reset can leave ORIG_HEAD. Preserve its
            // commit reachability too; it is not by itself an in-progress merge.
            if metadata.files["ORIG_HEAD"] != nil {
                guard let original = try await referenceValue("ORIG_HEAD", at: directory.path) else { throw GitWorktreeError.changed }
                logHeads.append(original)
            }
            if !logHeads.isEmpty {
                let uniqueHeads = Array(Set(logHeads)).sorted()
                let orphan = try await run(at: directory.path,
                                          arguments: ["rev-list", "--max-count=1"] + uniqueHeads + ["--not", head, "--branches", "--"],
                                          operation: "reflog reachability")
                if !orphan.stdout.isEmpty {
                    guard GitWorktreeParser.validObject(try singleLine(orphan.stdout, name: "unretained commit")) else { throw GitWorktreeError.invalidOutput("unretained commit") }
                    return .init(entry: entry, protection: [.unretainedHistory], detail: nil, proof: nil)
                }
            }
            guard try await referenceValue("HEAD", at: directory.path) == head,
                  try GitWorktreeFS.metadata(worktree: directory.path, administrative: admin.path) == metadata,
                  try GitWorktreeFS.directory(directory.path).identity == directory.identity,
                  try GitWorktreeFS.directory(admin.path).identity == admin.identity,
                  try await list(at: repository.mainPath).first(where: { $0.id == entry.id }) == entry else { throw GitWorktreeError.changed }
            let proof = GitWorktreeProof(repository: repository, entry: entry, canonicalPath: directory.path,
                                         administrativeDirectory: admin.path, trackedEntries: index,
                                         directoryIdentity: directory.identity, administrativeIdentity: admin.identity,
                                         files: metadata.files, pointerBytes: metadata.bytes, reflogHeads: logHeads)
            return .init(entry: entry, protection: [], detail: nil, proof: proof)
        } catch is CancellationError { throw CancellationError() }
        catch { return .init(entry: entry, protection: [.unverifiable], detail: error.localizedDescription, proof: nil) }
    }

    private func revalidate(_ expected: GitWorktreeProof) async throws -> GitWorktreeProof {
        try await verifyRepository(expected.repository)
        let entries = try await list(at: expected.repository.mainPath)
        guard let entry = entries.first(where: { $0.id == expected.entry.id }), entry == expected.entry else { throw GitWorktreeError.changed }
        let row = try await inspect(entry, in: expected.repository, all: entries)
        guard row.canRemove, let fresh = row.proof, fresh == expected else { throw GitWorktreeError.changed }
        return fresh
    }

    private func referenceValue(_ reference: String, at path: String, missingAllowed: Bool = false) async throws -> String? {
        guard ["HEAD", "ORIG_HEAD"].contains(reference) || GitWorktreeParser.validBranch(reference) else { throw GitWorktreeError.invalidOutput("reference") }
        let result = try await run(at: path, arguments: ["rev-parse", "--verify", "--quiet", "--end-of-options", reference + "^{commit}"],
                                   operation: "exact commit reference", allowedExitCodes: missingAllowed ? [0, 1] : [0])
        if result.exitCode == 1 {
            guard result.stdout.isEmpty else { throw GitWorktreeError.invalidOutput("missing reference") }
            return nil
        }
        let object = try singleLine(result.stdout, name: "commit reference")
        guard GitWorktreeParser.validObject(object) else { throw GitWorktreeError.invalidOutput("commit reference") }
        return object
    }
    private func referenceExists(_ reference: String, at path: String) async throws -> Bool {
        guard GitWorktreeParser.validRecoveryReference(reference) else { throw GitWorktreeError.protectedItem }
        let symbolic = try await run(at: path, arguments: ["symbolic-ref", "--quiet", reference], operation: "recovery symbolic ref collision", allowedExitCodes: [0, 1])
        if symbolic.exitCode == 0 { return true }
        guard symbolic.stdout.isEmpty else { throw GitWorktreeError.invalidOutput("symbolic-ref collision check") }
        let result = try await run(at: path, arguments: ["show-ref", "--exists", reference], operation: "raw recovery ref existence", allowedExitCodes: [0, 2])
        guard result.stdout.isEmpty else { throw GitWorktreeError.invalidOutput("show-ref --exists") }
        return result.exitCode == 0
    }
    private func directRecoveryValue(_ reference: String, at path: String) async throws -> String? {
        guard GitWorktreeParser.validRecoveryReference(reference) else { throw GitWorktreeError.protectedItem }
        let symbolic = try await run(at: path, arguments: ["symbolic-ref", "--quiet", reference], operation: "direct recovery ref", allowedExitCodes: [0, 1])
        guard symbolic.exitCode == 1, symbolic.stdout.isEmpty else { throw GitWorktreeError.changed }
        return try await referenceValue(reference, at: path)
    }
    private func recoveryPoints(repository: GitRepositoryIdentity, entries: [GitWorktreeEntry]) async throws -> [GitRecoveryPoint] {
        let result = try await run(at: repository.mainPath,
                                   arguments: ["for-each-ref", "--format=%(refname)%00%(objectname)%00%(symref)%00", "refs/heads/mopanel-recovery/"],
                                   operation: "recovery branches")
        guard let text = String(data: result.stdout, encoding: .utf8), text.isEmpty || text.hasSuffix("\n") else { throw GitWorktreeError.invalidOutput("recovery refs") }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        guard lines.count <= 512 else { throw GitWorktreeError.invalidOutput("recovery ref count") }
        return try lines.map { line in
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, fields[2].isEmpty, fields[3].isEmpty, GitWorktreeParser.validRecoveryReference(fields[0]),
                  GitWorktreeParser.validObject(fields[1]) else { throw GitWorktreeError.invalidOutput("recovery ref") }
            return .init(repository: repository, reference: fields[0], head: fields[1], checkedOutPath: entries.first(where: { $0.branch == fields[0] })?.path)
        }
    }
    private func verifyRecovery(_ recovery: GitRecoveryPoint) async throws {
        guard GitWorktreeParser.validRecoveryReference(recovery.reference), GitWorktreeParser.validObject(recovery.head), recovery.checkedOutPath == nil else {
            throw GitWorktreeError.protectedItem
        }
        try await verifyRepository(recovery.repository)
        guard !(try await specialConfiguration(at: recovery.repository.mainPath)), !unsupportedObjectStorage(recovery.repository),
              try await directRecoveryValue(recovery.reference, at: recovery.repository.mainPath) == recovery.head,
              !(try await list(at: recovery.repository.mainPath)).contains(where: { $0.branch == recovery.reference }) else { throw GitWorktreeError.changed }
    }
    private func unsupportedObjectStorage(_ repository: GitRepositoryIdentity) -> Bool {
        // A ref in the original repository cannot independently retain objects
        // supplied by an alternate store or a grafted/shallow history. Do not
        // silently advertise a recovery guarantee for those arrangements.
        let common = repository.commonDirectory
        for suffix in ["/objects/info/alternates", "/objects/info/http-alternates", "/info/grafts", "/shallow"] {
            if (try? GitWorktreeFS.isAbsent(common + suffix)) != true { return true }
        }
        for suffix in ["/objects", "/objects/info", "/info"] {
            if let checked = try? GitWorktreeFS.directory(common + suffix), checked.path == common + suffix { continue }
            return true
        }
        return false
    }
    private func recoveryTree(_ recovery: GitRecoveryPoint) async throws -> [GitTrackedEntry] {
        let result = try await run(at: recovery.repository.mainPath, arguments: ["ls-tree", "-r", "-z", "--full-tree", recovery.head], operation: "recovery commit tree")
        let entries = try GitWorktreeParser.trackedEntries(result.stdout, tree: true)
        guard !entries.contains(where: { $0.mode == "160000" }) else { throw GitWorktreeError.protectedItem }
        return entries
    }
    private func requireCurrent(_ date: Date) throws {
        let age = Date().timeIntervalSince(date)
        guard age >= 0, age <= 300 else { throw GitWorktreeError.changed }
    }
}

/// Physical paths, not Foundation URL presentation equivalence, bind identities.
/// No method here removes a worktree or writes inside a repository.
enum GitWorktreeFS {
    struct Metadata: Equatable, Sendable {
        let files: [String: GitWorktreeFileIdentity]
        let bytes: [String: Data]
        let hasPrivateMetadata: Bool
    }
    private static var typeMask: mode_t {
        #if canImport(Darwin)
        Darwin.S_IFMT
        #else
        Glibc.S_IFMT
        #endif
    }
    private static var directoryMode: mode_t {
        #if canImport(Darwin)
        Darwin.S_IFDIR
        #else
        Glibc.S_IFDIR
        #endif
    }
    private static var regularMode: mode_t {
        #if canImport(Darwin)
        Darwin.S_IFREG
        #else
        Glibc.S_IFREG
        #endif
    }
    static func identity(_ value: stat, directory: Bool = false) -> GitWorktreeFileIdentity {
        #if canImport(Darwin)
        let mt = value.st_mtimespec, ct = value.st_ctimespec
        #else
        let mt = value.st_mtim, ct = value.st_ctim
        #endif
        return .init(device: UInt64(truncatingIfNeeded: value.st_dev), inode: UInt64(value.st_ino), owner: value.st_uid, mode: UInt32(value.st_mode),
                     size: directory ? 0 : Int64(value.st_size), modifiedSeconds: directory ? 0 : Int64(mt.tv_sec),
                     modifiedNanoseconds: directory ? 0 : Int64(mt.tv_nsec), changedSeconds: directory ? 0 : Int64(ct.tv_sec),
                     changedNanoseconds: directory ? 0 : Int64(ct.tv_nsec))
    }
    static func directory(_ raw: String) throws -> (path: String, identity: GitWorktreeFileIdentity) {
        guard raw.hasPrefix("/"), raw.utf8.count <= 32768, !raw.utf8.contains(0),
              !raw.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw GitWorktreeError.unsafePath }
        var before = stat()
        guard lstat(raw, &before) == 0, before.st_mode & typeMask == directoryMode,
              before.st_uid == getuid(), before.st_mode & 0o022 == 0 else { throw GitWorktreeError.unsafePath }
        guard let pointer = realpath(raw, nil) else { throw GitWorktreeError.unsafePath }
        defer { free(pointer) }
        guard let canonical = String(validatingUTF8: pointer) else { throw GitWorktreeError.unsafePath }
        var after = stat()
        guard lstat(canonical, &after) == 0, identity(before, directory: true) == identity(after, directory: true) else { throw GitWorktreeError.changed }
        return (canonical, identity(after, directory: true))
    }
    static func regularFile(_ path: String) throws -> GitWorktreeFileIdentity {
        var value = stat()
        guard lstat(path, &value) == 0, value.st_mode & typeMask == regularMode, value.st_uid == getuid(),
              value.st_mode & 0o022 == 0, value.st_nlink == 1 else { throw GitWorktreeError.unsafePath }
        return identity(value)
    }
    static func readPointer(_ path: String) throws -> Data {
        let before = try regularFile(path)
        guard before.size >= 0, before.size <= 65536 else { throw GitWorktreeError.unsafePath }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw GitWorktreeError.unsafePath }
        defer { _ = close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, identity(opened) == before else { throw GitWorktreeError.changed }
        var buffer = [UInt8](repeating: 0, count: Int(before.size) + 1), total = 0
        while total < buffer.count {
            let count = buffer.withUnsafeMutableBytes { raw in read(descriptor, raw.baseAddress!.advanced(by: total), raw.count - total) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw GitWorktreeError.unsafePath }
            if count == 0 { break }
            total += count
        }
        guard total == Int(before.size), try regularFile(path) == before else { throw GitWorktreeError.changed }
        return Data(buffer.prefix(total))
    }
    static func isAbsent(_ path: String) throws -> Bool {
        var value = stat()
        if lstat(path, &value) == 0 { return false }
        guard errno == ENOENT else { throw GitWorktreeError.unsafePath }
        return true
    }
    static func overlap(_ a: String, _ b: String) -> Bool { a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/") }
    static func metadata(worktree: String, administrative: String) throws -> Metadata {
        var files: [String: GitWorktreeFileIdentity] = [:], bytes: [String: Data] = [:]
        let names = try FileManager.default.contentsOfDirectory(atPath: administrative)
        let allowed: Set<String> = ["HEAD", "ORIG_HEAD", "index", "gitdir", "commondir", "logs", "refs", "COMMIT_EDITMSG"]
        var privateState = !Set(names).isSubset(of: allowed)
        for name in ["HEAD", "ORIG_HEAD", "index", "gitdir", "commondir", "COMMIT_EDITMSG"] where names.contains(name) {
            files[name] = try regularFile(administrative + "/" + name)
        }
        guard ["HEAD", "index", "gitdir", "commondir"].allSatisfy({ files[$0] != nil }) else { throw GitWorktreeError.unsafePath }
        files[".git"] = try regularFile(worktree + "/.git")
        for (key, path) in [(".git", worktree + "/.git"), ("HEAD", administrative + "/HEAD"),
                            ("gitdir", administrative + "/gitdir"), ("commondir", administrative + "/commondir")] {
            bytes[key] = try readPointer(path)
        }
        if names.contains("COMMIT_EDITMSG") { bytes["COMMIT_EDITMSG"] = try readPointer(administrative + "/COMMIT_EDITMSG") }
        if names.contains("logs") {
            _ = try directory(administrative + "/logs")
            let logs = try FileManager.default.contentsOfDirectory(atPath: administrative + "/logs")
            if !Set(logs).isSubset(of: ["HEAD"]) { privateState = true }
            if logs.contains("HEAD") { files["logs/HEAD"] = try regularFile(administrative + "/logs/HEAD") }
        }
        // Newer Git creates empty refs/{heads,tags} in each worktree. Allow the
        // empty directory scaffolding, never private ref files or symlinks.
        if names.contains("refs"), !(try emptyDirectoryTree(administrative + "/refs", depth: 0)) { privateState = true }
        return .init(files: files, bytes: bytes, hasPrivateMetadata: privateState)
    }
    private static func emptyDirectoryTree(_ path: String, depth: Int) throws -> Bool {
        guard depth <= 3, (try? directory(path)) != nil else { return false }
        let names = try FileManager.default.contentsOfDirectory(atPath: path)
        guard names.count <= 32 else { return false }
        for name in names {
            guard !name.contains("/"), name != ".", name != "..",
                  try emptyDirectoryTree(path + "/" + name, depth: depth + 1) else { return false }
        }
        return true
    }
    static func newDestination(_ url: URL, repository: GitRepositoryIdentity, entries: [GitWorktreeEntry]) throws -> (path: String, parent: GitWorktreeFileIdentity) {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0),
              !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw GitWorktreeError.unsafePath }
        let name = url.lastPathComponent
        guard !name.isEmpty, name != "/", name != ".", name != "..", name != ".git", !name.contains("/") else { throw GitWorktreeError.unsafePath }
        let parent = try directory(url.deletingLastPathComponent().path)
        let path = parent.path + "/" + name
        guard try isAbsent(path), !overlap(path, repository.commonDirectory) else { throw GitWorktreeError.destinationExists }
        for entry in entries {
            let candidate = (try? directory(entry.path).path) ?? entry.path
            guard !overlap(path, candidate) else { throw GitWorktreeError.destinationExists }
        }
        return (path, parent.identity)
    }
}
