// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import MoPanelCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Every Git invocation is confined to a newly-created, owned temp fixture.
/// No test uses the checkout containing MoPanel or any user's repository.
private final class GitTemporaryRepository: @unchecked Sendable {
    let root: URL
    let main: URL
    let executable: URL
    private let lock = NSLock()
    private var recorded: [GitWorktreeInvocation] = []
    var invocations: [GitWorktreeInvocation] { lock.lock(); defer { lock.unlock() }; return recorded }

    init() throws {
        let candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("A real Git installation is required for isolated worktree integration tests.")
        }
        executable = URL(fileURLWithPath: path)
        let created = FileManager.default.temporaryDirectory.appendingPathComponent("MoPanelGitCase-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        root = URL(fileURLWithPath: try GitWorktreeFS.directory(created.path).path, isDirectory: true)
        main = root.appendingPathComponent("main", isDirectory: true)
        do {
            _ = try setup(["init", "--initial-branch=main", main.path])
            try Data("baseline\n".utf8).write(to: main.appendingPathComponent("README.txt"))
            try Data("cache/\n*.tmp\n".utf8).write(to: main.appendingPathComponent(".gitignore"))
            _ = try setup(["-C", main.path, "add", "--", "README.txt", ".gitignore"])
            _ = try setup(["-C", main.path, "commit", "-m", "Temporary test baseline"])
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
    func dispose() throws {
        guard root.lastPathComponent.hasPrefix("MoPanelGitCase-"), try GitWorktreeFS.directory(root.path).path == root.path else {
            throw GitWorktreeError.unsafePath
        }
        try FileManager.default.removeItem(at: root)
    }
    func execute(_ invocation: GitWorktreeInvocation) throws -> GitWorktreeCommandResult {
        if let path = invocation.repositoryPath {
            guard path.hasPrefix(root.path + "/") else { throw GitWorktreeError.unsafePath }
        }
        lock.lock(); recorded.append(invocation); lock.unlock()
        return try execute(arguments: invocation.arguments)
    }
    @discardableResult func setup(_ arguments: [String]) throws -> GitWorktreeCommandResult {
        let result = try execute(arguments: GitWorktreeService.commandPrefix + ["-c", "user.name=MoPanel Test", "-c", "user.email=test@mopanel.invalid"] + arguments)
        guard result.exitCode == 0 else { throw GitWorktreeError.command("isolated test setup", result.exitCode) }
        return result
    }
    func add(_ name: String = "linked", detached: Bool = false) throws -> URL {
        let path = root.appendingPathComponent(name, isDirectory: true)
        let options = detached ? ["--detach"] : ["-b", "topic-" + UUID().uuidString.lowercased()]
        _ = try setup(["-C", main.path, "worktree", "add"] + options + ["--", path.path, "HEAD"])
        return path
    }
    func commit(in path: URL, text: String = "unique committed content\n") throws {
        try Data(text.utf8).write(to: path.appendingPathComponent("README.txt"))
        _ = try setup(["-C", path.path, "add", "--", "README.txt"])
        _ = try setup(["-C", path.path, "commit", "-m", "Temporary unique commit"])
    }
    func service(intercept: (@Sendable (GitWorktreeInvocation) throws -> GitWorktreeCommandResult?)? = nil) -> GitWorktreeService {
        GitWorktreeService { [self] invocation in
            if let result = try intercept?(invocation) { return result }
            return try await Task.detached { try self.execute(invocation) }.value
        }
    }
    private func execute(arguments: [String]) throws -> GitWorktreeCommandResult {
        let process = Process(), output = root.appendingPathComponent("capture-" + UUID().uuidString)
        let errors = root.appendingPathComponent("capture-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              FileManager.default.createFile(atPath: errors.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw GitWorktreeError.unsafePath }
        let out = try FileHandle(forWritingTo: output), err = try FileHandle(forWritingTo: errors)
        defer {
            try? out.close(); try? err.close()
            try? FileManager.default.removeItem(at: output); try? FileManager.default.removeItem(at: errors)
        }
        process.executableURL = executable; process.arguments = arguments
        process.currentDirectoryURL = root
        process.environment = GitWorktreeService.protectiveEnvironment.merging(["PATH": "/usr/bin:/bin:/opt/homebrew/bin", "LANG": "C", "LC_ALL": "C"]) { _, b in b }
        process.standardInput = FileHandle.nullDevice; process.standardOutput = out; process.standardError = err
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        try process.run()
        if completed.wait(timeout: .now() + 15) == .timedOut {
            process.terminate(); process.waitUntilExit()
            return .init(stdout: Data(), exitCode: process.terminationStatus, timedOut: true)
        }
        process.waitUntilExit()
        let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= GitWorktreeParser.maximumOutput else { return .init(stdout: Data(), exitCode: process.terminationStatus, truncated: true) }
        return .init(stdout: try Data(contentsOf: output), exitCode: process.terminationStatus)
    }
}

final class GitWorktreeIntegrationTests: XCTestCase {
    private var fixture: GitTemporaryRepository!
    override func setUpWithError() throws { fixture = try GitTemporaryRepository() }
    override func tearDownWithError() throws { try fixture?.dispose(); fixture = nil }
    private func row(_ path: URL, using service: GitWorktreeService? = nil) async throws -> GitWorktreeRow {
        let rows = try await (service ?? fixture.service()).scan(repository: fixture.main).rows
        return try XCTUnwrap(rows.first(where: { (try? GitWorktreeFS.directory($0.entry.path).path) == path.path }), String(describing: rows))
    }

    func testRealCleanUniqueCommitRemovalAndRecoveryPreserveContentsAndOriginalBranch() async throws {
        let path = try fixture.add("研究 ' $(never-executed)\nlinked")
        try fixture.commit(in: path)
        let expected = try Data(contentsOf: path.appendingPathComponent("README.txt"))
        let service = fixture.service(), candidate = try await row(path, using: service)
        XCTAssertTrue(candidate.canRemove, candidate.detail ?? String(describing: candidate.protection))
        let plan = try await service.prepareRemoval(candidate)
        let outcome = await service.remove(plan)
        XCTAssertTrue(outcome.completedAndVerified, outcome.detail ?? "")
        XCTAssertTrue(outcome.recoveryVerified); XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        let scan = try await service.scan(repository: fixture.main)
        let point = try XCTUnwrap(scan.recoveryPoints.first { $0.reference == plan.recoveryReference })
        let destination = fixture.root.appendingPathComponent("restored")
        let restorePlan = try await service.prepareRestore(point, destination: destination)
        let restored = await service.restore(restorePlan)
        XCTAssertTrue(restored.completedAndVerified, restored.detail ?? "")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("README.txt")), expected)
        XCTAssertTrue(fixture.invocations.contains { $0.mutating && $0.arguments.contains("update-ref") })
        XCTAssertTrue(fixture.invocations.contains { $0.mutating && $0.arguments.contains("remove") })
        XCTAssertFalse(fixture.invocations.contains { $0.arguments.contains("--force") || $0.arguments.contains("-f") || $0.arguments.contains("clean") })
    }

    func testDetachedHEADGetsReachableRecoveryBranchBeforeRemoval() async throws {
        let path = try fixture.add(detached: true)
        try fixture.commit(in: path)
        let service = fixture.service(), candidate = try await row(path)
        XCTAssertTrue(candidate.entry.detached)
        let plan = try await service.prepareRemoval(candidate)
        let result = await service.remove(plan)
        XCTAssertTrue(result.completedAndVerified, result.detail ?? "")
        let references = try await service.scan(repository: fixture.main).recoveryPoints
        XCTAssertEqual(references.first?.head, candidate.entry.head)
    }

    func testMainLockedDirtyUntrackedAndIgnoredAreProtectedWithoutMutations() async throws {
        let locked = try fixture.add("locked"), dirty = try fixture.add("dirty"), untracked = try fixture.add("untracked"), ignored = try fixture.add("ignored")
        _ = try fixture.setup(["-C", fixture.main.path, "worktree", "lock", "--reason", "keep", locked.path])
        try Data("changed\n".utf8).write(to: dirty.appendingPathComponent("README.txt"))
        try Data("untracked personal work".utf8).write(to: untracked.appendingPathComponent("private.txt"))
        try FileManager.default.createDirectory(at: ignored.appendingPathComponent("cache"), withIntermediateDirectories: false)
        try Data("ignored personal content".utf8).write(to: ignored.appendingPathComponent("cache/content"))
        let inventory = try await fixture.service().scan(repository: fixture.main)
        XCTAssertEqual(inventory.rows.first?.protection, [.main])
        for (path, reason) in [(locked, GitWorktreeGuard.locked), (dirty, .dirty), (untracked, .untracked), (ignored, .ignored)] {
            let entry = try XCTUnwrap(inventory.rows.first { $0.id == path.path })
            XCTAssertTrue(entry.protection.contains(reason), "\(path.path): \(entry.protection) \(entry.detail ?? "")")
            do { _ = try await fixture.service().prepareRemoval(entry); XCTFail("Protected worktree was accepted") } catch {}
            XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        }
        XCTAssertTrue(fixture.invocations.allSatisfy { !$0.mutating })
    }

    func testAssumeUnchangedAndSkipWorktreeCannotHideDirtyContent() async throws {
        for (name, flag) in [("assume", "--assume-unchanged"), ("skip", "--skip-worktree")] {
            let path = try fixture.add(name)
            _ = try fixture.setup(["-C", path.path, "update-index", flag, "--", "README.txt"])
            try Data("hidden work\n".utf8).write(to: path.appendingPathComponent("README.txt"))
            let candidate = try await row(path)
            XCTAssertTrue(candidate.protection.contains(.hiddenIndexChanges), candidate.detail ?? "")
            XCTAssertFalse(candidate.canRemove)
        }
    }

    func testSubmoduleGitlinkAndPrivateRefsAreProtected() async throws {
        let submodule = try fixture.add("submodule"), privateRef = try fixture.add("private-ref")
        let initial = try await row(submodule)
        let head = try XCTUnwrap(initial.entry.head)
        _ = try fixture.setup(["-C", submodule.path, "update-index", "--add", "--cacheinfo", "160000," + head + ",nested"])
        let sub = try await row(submodule)
        XCTAssertTrue(sub.protection.contains(.submodule), sub.detail ?? "")
        _ = try fixture.setup(["-C", privateRef.path, "update-ref", "refs/worktree/private", head])
        let item = try await row(privateRef)
        XCTAssertTrue(item.protection.contains(.privateMetadata), item.detail ?? "")
        XCTAssertTrue(fixture.invocations.allSatisfy { !$0.mutating })
    }

    func testOldDetachedReflogCommitIsNotMistakenForRetainedHEADHistory() async throws {
        let path = try fixture.add(detached: true)
        try fixture.commit(in: path)
        _ = try fixture.setup(["-C", path.path, "checkout", "--detach", "main"])
        // Isolate the reflog safeguard from the separately-tested draft guard.
        let metadata = try fixture.setup(["-C", path.path, "rev-parse", "--absolute-git-dir"])
        let admin = String(decoding: metadata.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        XCTAssertTrue(admin.hasPrefix(fixture.root.path + "/"))
        try FileManager.default.removeItem(atPath: admin + "/COMMIT_EDITMSG")
        let candidate = try await row(path)
        XCTAssertTrue(candidate.protection.contains(.unretainedHistory), candidate.detail ?? String(describing: candidate.protection))
        XCTAssertFalse(candidate.canRemove)
    }

    func testCustomFiltersSparsePartialAndIncludeSettingsAreBlockedBeforeStatus() async throws {
        let path = try fixture.add()
        for (key, value) in [("filter.custom.process", "never-execute"), ("core.sparseCheckout", "false"),
                              ("remote.origin.promisor", "true"), ("include.path", "/does-not-exist")] {
            _ = try fixture.setup(["-C", fixture.main.path, "config", key, value])
            let candidate = try await row(path)
            XCTAssertTrue(candidate.protection.contains(.specialConfiguration), "\(key): \(candidate.detail ?? "")")
            _ = try fixture.setup(["-C", fixture.main.path, "config", "--unset", key])
        }
        XCTAssertTrue(fixture.invocations.allSatisfy { !$0.mutating })
    }

    func testFreshStatusAndHEADChangesInvalidateConfirmation() async throws {
        let path = try fixture.add(), service = fixture.service()
        var plan = try await service.prepareRemoval(row(path))
        try Data("new untracked work".utf8).write(to: path.appendingPathComponent("new.txt"))
        let changedStatus = await service.remove(plan)
        XCTAssertFalse(changedStatus.mutationStarted); XCTAssertFalse(changedStatus.completedAndVerified)
        try FileManager.default.removeItem(at: path.appendingPathComponent("new.txt"))
        plan = try await service.prepareRemoval(row(path))
        try fixture.commit(in: path)
        let changedHEAD = await service.remove(plan)
        XCTAssertFalse(changedHEAD.mutationStarted); XCTAssertFalse(changedHEAD.completedAndVerified)
        XCTAssertTrue(fixture.invocations.allSatisfy { !$0.mutating })
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }

    func testChangedDirectoryIdentityOrSymlinkNeverTargetsReplacement() async throws {
        let path = try fixture.add(), service = fixture.service()
        let plan = try await service.prepareRemoval(row(path))
        let moved = fixture.root.appendingPathComponent("moved-original")
        try FileManager.default.moveItem(at: path, to: moved)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: moved)
        let result = await service.remove(plan)
        XCTAssertFalse(result.completedAndVerified); XCTAssertFalse(result.mutationStarted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("README.txt").path))
        XCTAssertTrue(fixture.invocations.allSatisfy { !$0.mutating })
    }

    func testCancelOrFailureAfterRecoveryRefLeavesItIntactAndDoesNotClaimRemoval() async throws {
        for cancelled in [false, true] {
            let path = try fixture.add(cancelled ? "cancelled" : "failed")
            let service = fixture.service { invocation in
                invocation.operation == "worktree remove" ? .init(stdout: Data(), exitCode: cancelled ? 130 : 1, cancelled: cancelled) : nil
            }
            let plan = try await service.prepareRemoval(row(path, using: service))
            let result = await service.remove(plan)
            XCTAssertTrue(result.recoveryVerified); XCTAssertTrue(result.mutationStarted)
            XCTAssertEqual(result.cancelled, cancelled); XCTAssertFalse(result.completedAndVerified)
            XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
            let recovery = try await fixture.service().scan(repository: fixture.main).recoveryPoints
            XCTAssertTrue(recovery.contains { $0.reference == plan.recoveryReference && $0.head == plan.proof.entry.head })
        }
    }

    func testRecoveryRefCollisionIsNeverOverwritten() async throws {
        let path = try fixture.add(), service = fixture.service(), id = UUID()
        let candidate = try await row(path), head = try XCTUnwrap(candidate.entry.head)
        let reference = "refs/heads/mopanel-recovery/" + id.uuidString.lowercased()
        let plan = try await service.prepareRemoval(candidate, recoveryID: id)
        _ = try fixture.setup(["-C", fixture.main.path, "update-ref", reference, head])
        let result = await service.remove(plan)
        XCTAssertFalse(result.mutationStarted); XCTAssertFalse(result.completedAndVerified)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        do { _ = try await service.prepareRemoval(candidate, recoveryID: id); XCTFail("Existing ref must be rejected") } catch {}
    }

    func testRestoreRejectsExistingDestinationAndChangedRecoveryBranch() async throws {
        let path = try fixture.add(), service = fixture.service()
        let removal = try await service.prepareRemoval(row(path))
        let removed = await service.remove(removal)
        XCTAssertTrue(removed.completedAndVerified, removed.detail ?? "")
        let inventory = try await service.scan(repository: fixture.main)
        let point = try XCTUnwrap(inventory.recoveryPoints.first)
        do { _ = try await service.prepareRestore(point, destination: fixture.main); XCTFail("Existing target accepted") } catch {}
        let destination = fixture.root.appendingPathComponent("restore-after-review")
        let plan = try await service.prepareRestore(point, destination: destination)
        try fixture.commit(in: fixture.main, text: "new main content\n")
        let newHead = try fixture.setup(["-C", fixture.main.path, "rev-parse", "HEAD"])
        let newObject = String(decoding: newHead.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        _ = try fixture.setup(["-C", fixture.main.path, "update-ref", point.reference, newObject])
        let result = await service.restore(plan)
        XCTAssertFalse(result.mutationStarted); XCTAssertFalse(result.completedAndVerified)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testRepositoryHooksNeverRunDuringScanRefCreationRemovalOrRestore() async throws {
        let path = try fixture.add(), canary = fixture.root.appendingPathComponent("HOOK_RAN")
        let hooks = fixture.main.appendingPathComponent(".git/hooks")
        for name in ["reference-transaction", "post-checkout"] {
            let hook = hooks.appendingPathComponent(name)
            try Data(("#!/bin/sh\n/usr/bin/touch '" + canary.path + "'\n").utf8).write(to: hook)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        }
        let service = fixture.service(), plan = try await service.prepareRemoval(row(path))
        let removed = await service.remove(plan)
        XCTAssertTrue(removed.completedAndVerified, removed.detail ?? "")
        let inventory = try await service.scan(repository: fixture.main)
        let point = try XCTUnwrap(inventory.recoveryPoints.first)
        let restore = try await service.prepareRestore(point, destination: fixture.root.appendingPathComponent("restored"))
        let result = await service.restore(restore)
        XCTAssertTrue(result.completedAndVerified, result.detail ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: canary.path))
    }

    func testUnsupportedProtectiveFlagAndTruncatedOutputStopBeforeMutations() async throws {
        let path = try fixture.add()
        for versionFailure in [true, false] {
            let service = fixture.service { invocation in
                if versionFailure && invocation.operation == "protective Git capability probe" { return .init(stdout: Data(), exitCode: 129) }
                if !versionFailure && invocation.operation == "worktree inventory" { return .init(stdout: Data("worktree incomplete".utf8), exitCode: 0, truncated: true) }
                return nil
            }
            do { _ = try await service.scan(repository: fixture.main); XCTFail("Unsupported output accepted") } catch {}
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path)); XCTAssertTrue(fixture.invocations.allSatisfy { !$0.mutating })
    }

    func testBareAndMissingPrunableEntriesRemainReadOnly() async throws {
        let bare = fixture.root.appendingPathComponent("bare.git")
        _ = try fixture.setup(["init", "--bare", bare.path])
        let inventory = try await fixture.service().scan(repository: bare)
        XCTAssertNil(inventory.repository); XCTAssertTrue(inventory.rows.allSatisfy { $0.protection.contains(.bare) && !$0.canRemove })
        let linked = try fixture.add(), moved = fixture.root.appendingPathComponent("unregistered-moved")
        try FileManager.default.moveItem(at: linked, to: moved)
        let listed = try await fixture.service().scan(repository: fixture.main)
        let missing = try XCTUnwrap(listed.rows.first { $0.id == linked.path })
        XCTAssertTrue(missing.protection.contains(.prunable), String(describing: missing.protection))
        XCTAssertFalse(missing.canRemove)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("README.txt").path))
        XCTAssertTrue(fixture.invocations.allSatisfy { !$0.mutating })
    }

    func testInProgressMetadataAndExternalObjectStorageAreProtected() async throws {
        let path = try fixture.add(), candidate = try await row(path)
        let proof = try XCTUnwrap(candidate.proof)
        let merge = URL(fileURLWithPath: proof.administrativeDirectory).appendingPathComponent("MERGE_HEAD")
        try Data(((candidate.entry.head ?? "") + "\n").utf8).write(to: merge)
        let merging = try await row(path)
        XCTAssertTrue(merging.protection.contains(.privateMetadata), merging.detail ?? "")
        try FileManager.default.removeItem(at: merge)
        let alternate = fixture.main.appendingPathComponent(".git/objects/info/alternates")
        // An empty alternates file is still a special-storage arrangement and
        // must not be silently treated as an independently retained object DB.
        try Data().write(to: alternate)
        let alternateRow = try await row(path)
        XCTAssertTrue(alternateRow.protection.contains(.specialConfiguration), alternateRow.detail ?? "")
        XCTAssertTrue(fixture.invocations.allSatisfy { !$0.mutating })
    }

    func testCustomFilterCanaryIsNotExecutedByInspection() async throws {
        let path = try fixture.add(), canary = fixture.root.appendingPathComponent("FILTER_RAN")
        let program = fixture.root.appendingPathComponent("filter-canary")
        try Data(("#!/bin/sh\n/usr/bin/touch '" + canary.path + "'\n/bin/cat\n").utf8).write(to: program)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: program.path)
        try Data("*.txt filter=guarded\n".utf8).write(to: path.appendingPathComponent(".gitattributes"))
        _ = try fixture.setup(["-C", path.path, "add", "--", ".gitattributes"])
        _ = try fixture.setup(["-C", path.path, "commit", "-m", "Fixture attributes before filter configuration"])
        _ = try fixture.setup(["-C", fixture.main.path, "config", "filter.guarded.clean", program.path])
        _ = try fixture.setup(["-C", fixture.main.path, "config", "filter.guarded.smudge", program.path])
        let candidate = try await row(path)
        XCTAssertTrue(candidate.protection.contains(.specialConfiguration))
        XCTAssertFalse(FileManager.default.fileExists(atPath: canary.path))
        XCTAssertFalse(fixture.invocations.contains { $0.operation == "tracked, untracked and ignored status" })
    }

    func testPhysicalAncestorAliasesAndTrackedSpecialFilenamesRestoreCorrectly() async throws {
        let path = try fixture.add(), name = "內容 ' $(not-run)\nfile.txt"
        let contents = Data([0, 255, 10, 39, 36, 42])
        try contents.write(to: path.appendingPathComponent(name))
        try FileManager.default.createSymbolicLink(atPath: path.appendingPathComponent("tracked-link").path, withDestinationPath: "README.txt")
        _ = try fixture.setup(["-C", path.path, "add", "--", name, "tracked-link"])
        _ = try fixture.setup(["-C", path.path, "commit", "-m", "Fixture special names"])
        let alias = fixture.root.appendingPathComponent("parent-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
        let service = fixture.service(), inventory = try await service.scan(repository: alias.appendingPathComponent("main"))
        XCTAssertEqual(inventory.repository?.mainPath, fixture.main.path)
        let candidate = try XCTUnwrap(inventory.rows.first { $0.id == path.path })
        let plan = try await service.prepareRemoval(candidate), result = await service.remove(plan)
        XCTAssertTrue(result.completedAndVerified, result.detail ?? "")
        let fresh = try await service.scan(repository: fixture.main)
        let point = try XCTUnwrap(fresh.recoveryPoints.first)
        let destination = fixture.root.appendingPathComponent("restored-special")
        let restorePlan = try await service.prepareRestore(point, destination: destination)
        let restored = await service.restore(restorePlan)
        XCTAssertTrue(restored.completedAndVerified, restored.detail ?? "")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(name)), contents)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("tracked-link").path), "README.txt")
    }

    func testConfigurationAndDestinationChangesAfterReviewStopBeforeMutation() async throws {
        let path = try fixture.add(), service = fixture.service()
        let removal = try await service.prepareRemoval(row(path))
        _ = try fixture.setup(["-C", fixture.main.path, "config", "core.filemode", "false"])
        let changed = await service.remove(removal)
        XCTAssertFalse(changed.mutationStarted); XCTAssertFalse(changed.completedAndVerified)
        let newRemoval = try await service.prepareRemoval(row(path))
        let removed = await service.remove(newRemoval)
        XCTAssertTrue(removed.completedAndVerified, removed.detail ?? "")
        let inventory = try await service.scan(repository: fixture.main)
        let point = try XCTUnwrap(inventory.recoveryPoints.first)
        let destination = fixture.root.appendingPathComponent("arrived-after-review")
        let plan = try await service.prepareRestore(point, destination: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("must survive".utf8).write(to: destination.appendingPathComponent("personal.txt"))
        let restored = await service.restore(plan)
        XCTAssertFalse(restored.mutationStarted); XCTAssertFalse(restored.completedAndVerified)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("personal.txt"), encoding: .utf8), "must survive")
    }

    func testSymbolicRefCollisionsArePreservedBeforeAndAfterReview() async throws {
        let path = try fixture.add(), service = fixture.service(), candidate = try await row(path)
        for target in ["refs/heads/not-created-by-mopanel", "refs/heads/main"] {
            let existingID = UUID(), existing = "refs/heads/mopanel-recovery/" + existingID.uuidString.lowercased()
            _ = try fixture.setup(["-C", fixture.main.path, "symbolic-ref", existing, target])
            do { _ = try await service.prepareRemoval(candidate, recoveryID: existingID); XCTFail("Symbolic ref accepted") } catch {}
            let before = try fixture.setup(["-C", fixture.main.path, "symbolic-ref", "--quiet", existing])
            XCTAssertEqual(String(decoding: before.stdout, as: UTF8.self), target + "\n")
            let plan = try await service.prepareRemoval(candidate)
            _ = try fixture.setup(["-C", fixture.main.path, "symbolic-ref", plan.recoveryReference, target])
            let outcome = await service.remove(plan)
            XCTAssertFalse(outcome.mutationStarted); XCTAssertFalse(outcome.completedAndVerified)
            let after = try fixture.setup(["-C", fixture.main.path, "symbolic-ref", "--quiet", plan.recoveryReference])
            XCTAssertEqual(String(decoding: after.stdout, as: UTF8.self), target + "\n")
        }
        XCTAssertTrue(fixture.invocations.allSatisfy { !$0.mutating })
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }

    func testCommittedMessageIsAcceptedButUniqueOrChangedDraftIsProtected() async throws {
        let path = try fixture.add()
        try fixture.commit(in: path)
        let service = fixture.service(), candidate = try await row(path)
        XCTAssertTrue(candidate.canRemove, candidate.detail ?? "")
        let plan = try await service.prepareRemoval(candidate)
        let admin = try XCTUnwrap(candidate.proof?.administrativeDirectory)
        let draft = URL(fileURLWithPath: admin).appendingPathComponent("COMMIT_EDITMSG")
        let original = try Data(contentsOf: draft)
        try Data("unique unfinished draft that is not a commit\n".utf8).write(to: draft)
        let changed = try await row(path)
        XCTAssertTrue(changed.protection.contains(.commitDraft), changed.detail ?? String(describing: changed.protection))
        let result = await service.remove(plan)
        XCTAssertFalse(result.mutationStarted); XCTAssertFalse(result.completedAndVerified)
        XCTAssertEqual(try String(contentsOf: draft, encoding: .utf8), "unique unfinished draft that is not a commit\n")
        try original.write(to: draft)
        let restoredMessage = try await row(path)
        XCTAssertTrue(restoredMessage.canRemove, restoredMessage.detail ?? "")
        try Data(repeating: 65, count: 65537).write(to: draft)
        let oversized = try await row(path)
        XCTAssertFalse(oversized.canRemove)
        XCTAssertTrue(fixture.invocations.allSatisfy { !$0.mutating })
    }
}
