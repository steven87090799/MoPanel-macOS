// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import MoPanelProcess

final class GitEnvironmentTests: XCTestCase {
    private let protections = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
                               "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0", "GIT_ATTR_NOSYSTEM": "1"]

    @MainActor func testGitIsolationIsExplicitAndRejectsAlternateValues() {
        let normal = ManagedProcess.safeEnvironment(interactive: false)
        for key in protections.keys { XCTAssertNil(normal[key], "Other tools must not implicitly receive Git overrides") }
        let isolated = ManagedProcess.safeEnvironment(overrides: protections, interactive: false)
        for (key, expected) in protections { XCTAssertEqual(isolated[key], expected) }
        for (key, expected) in protections {
            for rejected in ["", "/tmp/custom-config", "true", "false", expected + "\n", expected + "\0", "$(touch /tmp/never)"] {
                XCTAssertNil(ManagedProcess.safeEnvironment(overrides: [key: rejected], interactive: false)[key])
            }
        }
    }

    @MainActor func testGitIsolationDoesNotEnableRepositoryOrInterpreterInjection() {
        var requested = protections
        let forbidden = ["GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY",
                         "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0",
                         "GIT_EXEC_PATH", "GIT_SSH", "GIT_SSH_COMMAND", "GIT_ASKPASS", "GIT_EDITOR", "GIT_SEQUENCE_EDITOR",
                         "GIT_EXTERNAL_DIFF", "GIT_CONFIG_PARAMETERS", "GIT_REPLACE_REF_BASE", "GIT_TRACE", "GIT_TRACE2_EVENT"]
        for key in forbidden { requested[key] = "/tmp/untrusted-fixture" }
        let result = ManagedProcess.safeEnvironment(overrides: requested, interactive: true)
        for key in forbidden { XCTAssertNil(result[key], key) }
        for (key, value) in protections { XCTAssertEqual(result[key], value) }
    }

    @MainActor func testFixedGitProtectionsReachTheActualManagedChild() async throws {
        let helperPath = ProcessInfo.processInfo.environment["MOPANEL_GUARDIAN"]
            ?? FileManager.default.currentDirectoryPath + "/.build/debug/MoPanelGuardian"
        guard FileManager.default.isExecutableFile(atPath: helperPath) else {
            XCTFail("Git process isolation acceptance requires the compiled guardian"); return
        }
        var requested = protections
        requested["GIT_CONFIG_COUNT"] = "1"
        requested["GIT_CONFIG_KEY_0"] = "core.hooksPath"
        requested["GIT_CONFIG_VALUE_0"] = "/tmp/never"
        let script = "printf '%s\\0' \"${GIT_CONFIG_GLOBAL-unset}\" \"${GIT_CONFIG_SYSTEM-unset}\" \"${GIT_CONFIG_NOSYSTEM-unset}\" \"${GIT_TERMINAL_PROMPT-unset}\" \"${GIT_ATTR_NOSYSTEM-unset}\" \"${GIT_CONFIG_COUNT-unset}\" \"${GIT_CONFIG_KEY_0-unset}\" \"${GIT_CONFIG_VALUE_0-unset}\""
        let request = ProcessRequest(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                                     environment: requested, timeout: 5, outputLimit: 4_096)
        let result = try await ProcessRunner.capture(request, helperURL: URL(fileURLWithPath: helperPath))
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) },
                       ["/dev/null", "/dev/null", "1", "0", "1", "unset", "unset", "unset"])
    }
}
