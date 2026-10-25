// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
@testable import MoPanelProcess

final class ManagedProcessTests: XCTestCase {
    private func helper() throws -> URL {
        let path = ProcessInfo.processInfo.environment["MOPANEL_GUARDIAN"]
            ?? FileManager.default.currentDirectoryPath + "/.build/debug/MoPanelGuardian"
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw XCTSkip("Build MoPanelGuardian first, or set MOPANEL_GUARDIAN to the built helper.")
        }
        return URL(fileURLWithPath: path)
    }
    private func shell(_ script: String, args: [String] = [], timeout: TimeInterval = 5,
                       outputLimit: Int = 1024 * 1024, retainsOutput: Bool = true) -> ProcessRequest {
        ProcessRequest(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script, "fixture"] + args,
                       timeout: timeout, outputLimit: outputLimit, retainsOutput: retainsOutput)
    }

    @MainActor func testExactArgumentsWithoutInterpolation() async throws {
        let values = ["two words", "繁體中文", "$(touch MOPANEL_BAD)", "; exit 9", "line\nbreak", "'\"`"]
        let result = try await ProcessRunner.capture(shell("printf '%s\\0' \"$@\"", args: values), helperURL: helper())
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }, values)
    }

    @MainActor func testStdoutStderrAndExitCode() async throws {
        let result = try await ProcessRunner.capture(shell("printf out; printf err >&2; exit 17"), helperURL: helper())
        XCTAssertEqual(result.stdoutText, "out")
        XCTAssertEqual(result.stderrText, "err")
        XCTAssertEqual(result.exitCode, 17)
        XCTAssertFalse(result.succeeded)
    }

    @MainActor func testMissingCLIIsExplicitFailure() async throws {
        do {
            _ = try await ProcessRunner.capture(ProcessRequest(executable: URL(fileURLWithPath: "/mopanel-nonexistent-cli"), arguments: []), helperURL: helper())
            XCTFail("Missing executable must fail before launch")
        } catch ManagedProcessError.executableMissing {} catch { throw error }
    }

    @MainActor func testMissingHelperIsExplicitFailure() async throws {
        do {
            _ = try await ProcessRunner.capture(shell("exit 0"), helperURL: URL(fileURLWithPath: "/mopanel-nonexistent-helper"))
            XCTFail("Missing guardian must fail before launch")
        } catch ManagedProcessError.helperMissing {} catch { throw error }
    }

    @MainActor func testInvalidNULArgumentRejected() async throws {
        do {
            _ = try await ProcessRunner.capture(shell("exit 0", args: ["bad\0argument"]), helperURL: helper())
            XCTFail("Embedded NUL must never be silently truncated")
        } catch ManagedProcessError.invalidRequest {} catch { throw error }
    }

    @MainActor func testPermissionDeniedExecutable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoPanel-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("no executable permission")
        try Data("fixture".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        do {
            _ = try await ProcessRunner.capture(ProcessRequest(executable: file, arguments: []), helperURL: helper())
            XCTFail("Permission error must fail before launch")
        } catch ManagedProcessError.executableMissing {} catch { throw error }
    }

    @MainActor func testTimeout() async throws {
        let result = try await ProcessRunner.capture(shell("trap '' INT; sleep 30", timeout: 0.1), helperURL: helper())
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.exitCode, 124)
    }

    @MainActor func testUserCancellation() async throws {
        let session = ManagedProcess(helperURL: try helper())
        try session.start(request: shell("printf ready; sleep 30", timeout: 0))
        try await Task.sleep(nanoseconds: 80_000_000)
        session.cancel()
        let result = await session.wait()
        XCTAssertTrue(result.cancelled)
        XCTAssertFalse(session.running)
    }

    @MainActor func testTaskCancellation() async throws {
        let guardian = try helper()
        let request = shell("sleep 30", timeout: 0)
        let task = Task { try await ProcessRunner.capture(request, helperURL: guardian) }
        try await Task.sleep(nanoseconds: 80_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Task cancellation must propagate") }
        catch is CancellationError {} catch { throw error }
    }

    @MainActor func testOutputLimitStopsCommand() async throws {
        let result = try await ProcessRunner.capture(shell("/usr/bin/yes x", timeout: 5, outputLimit: 2048), helperURL: helper())
        XCTAssertEqual(result.stdout.count, 2048)
        XCTAssertTrue(result.outputTruncated)
        XCTAssertFalse(result.succeeded)
    }

    @MainActor func testStreamDoesNotAccumulateSnapshots() async throws {
        let session = ManagedProcess(helperURL: try helper())
        var observed = Data()
        session.onOutput = { observed.append($0) }
        try session.start(request: shell("printf 'one\\ntwo\\nthree\\n'", retainsOutput: false))
        let result = await session.wait()
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertEqual(String(decoding: observed, as: UTF8.self), "one\ntwo\nthree\n")
    }

    @MainActor func testStreamingDiagnosticsKeepOnlyTheTailWithoutStoppingTheCollector() async throws {
        let session = ManagedProcess(helperURL: try helper())
        var observedErrors = 0
        session.onError = { observedErrors += $0.count }
        try session.start(request: shell("/usr/bin/head -c 131072 /dev/zero >&2; printf STREAM-END >&2; printf complete", outputLimit: 2048, retainsOutput: false))
        let result = await session.wait()
        XCTAssertTrue(result.succeeded, "A continuous stream must not stop because its diagnostic history reached a retention limit.")
        XCTAssertEqual(observedErrors, 131082)
        XCTAssertLessThanOrEqual(result.stderr.count, 2048)
        XCTAssertEqual(String(decoding: result.stderr.suffix(10), as: UTF8.self), "STREAM-END")
        XCTAssertTrue(result.stdout.isEmpty)
    }

    @MainActor func testCaptureStderrLimitStillStopsCommand() async throws {
        let result = try await ProcessRunner.capture(shell("/usr/bin/yes warning >&2", outputLimit: 2048), helperURL: helper())
        XCTAssertEqual(result.stderr.count, 2048)
        XCTAssertTrue(result.outputTruncated)
        XCTAssertFalse(result.succeeded)
    }

    @MainActor func testCaptureCannotAnswerConfirmation() async throws {
        let result = try await ProcessRunner.capture(shell("if read answer; then exit 12; else printf no-input; fi"), helperURL: helper())
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdoutText, "no-input")
    }

    @MainActor func testPTYRetainsStartupPromptUntilViewAttaches() async throws {
        let session = ManagedProcess(helperURL: try helper())
        try session.start(request: shell("printf 'READY\\n'; read answer; printf 'VALUE:%s\\n' \"$answer\""), interactive: true)
        try await Task.sleep(nanoseconds: 150_000_000)
        var observed = Data()
        session.onOutput = { observed.append($0) }
        session.send(Data("hello\r".utf8))
        let result = await session.wait()
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(String(decoding: observed, as: UTF8.self).contains("READY"))
        XCTAssertTrue(String(decoding: observed, as: UTF8.self).contains("VALUE:hello"))
        XCTAssertTrue(result.stdout.isEmpty, "Interactive output is ephemeral, not an operation log")
    }

    @MainActor func testSafeEnvironmentRejectsHooksAndCLIOverrides() {
        let environment = ManagedProcess.safeEnvironment(overrides: ["BASH_ENV": "/evil", "DYLD_INSERT_LIBRARIES": "/evil", "MOLE_DRY_RUN": "0", "HOME": "/tmp/fixture", "EDITOR": "/evil", "MOPANEL_LANGUAGE": "unexpected", "SHELL": "/evil"], interactive: true)
        XCTAssertNil(environment["BASH_ENV"])
        XCTAssertNil(environment["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(environment["MOLE_DRY_RUN"])
        XCTAssertNil(environment["EDITOR"])
        XCTAssertNil(environment["MOPANEL_LANGUAGE"])
        XCTAssertEqual(environment["HOME"], "/tmp/fixture")
        XCTAssertEqual(environment["TERM"], "xterm-256color")
        XCTAssertTrue(environment["SHELL"]?.hasPrefix("/") == true)
        XCTAssertNotEqual(environment["SHELL"], "/evil")
    }

    @MainActor func testHomebrewProtectiveOverridesAcceptOnlyExactOne() {
        let keys = ["HOMEBREW_NO_AUTO_UPDATE", "HOMEBREW_NO_INSTALL_CLEANUP", "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK"]
        let accepted = ManagedProcess.safeEnvironment(overrides: Dictionary(uniqueKeysWithValues: keys.map { ($0, "1") }), interactive: true)
        for key in keys { XCTAssertEqual(accepted[key], "1") }
        for rejected in ["0", "", "true", "1\n", "1\0", "$(touch /tmp/never)", "--force"] {
            let environment = ManagedProcess.safeEnvironment(overrides: Dictionary(uniqueKeysWithValues: keys.map { ($0, rejected) }), interactive: false)
            for key in keys { XCTAssertNil(environment[key], "Rejected \(key) value \(rejected.debugDescription)") }
        }
    }

    @MainActor func testHomebrewProtectionsDoNotPermitArbitraryHomebrewOverrides() {
        let environment = ManagedProcess.safeEnvironment(overrides: [
            "HOMEBREW_NO_ANALYTICS": "0", "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1",
            "HOMEBREW_BREW_GIT_REMOTE": "https://attacker.invalid/brew", "HOMEBREW_API_DOMAIN": "https://attacker.invalid",
            "HOMEBREW_CASK_OPTS": "--no-quarantine", "HOMEBREW_NO_ASK": "1", "HOMEBREW_FORCE_API_AUTO_UPDATE": "1"
        ], interactive: true)
        XCTAssertEqual(environment["HOMEBREW_NO_ANALYTICS"], "1")
        for key in ["HOMEBREW_BREW_GIT_REMOTE", "HOMEBREW_API_DOMAIN", "HOMEBREW_CASK_OPTS", "HOMEBREW_NO_ASK", "HOMEBREW_FORCE_API_AUTO_UPDATE"] {
            XCTAssertNil(environment[key])
        }
    }
}
