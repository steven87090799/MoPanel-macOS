import XCTest
@testable import MoPanelCore

final class BackgroundStartupReadPlanTests: XCTestCase {
    func testAuthorizedReadIsOneFixedCommandWithCleanEnvironmentAndRootDeadline() {
        XCTAssertEqual(BackgroundStartupReadPlan.rootCommand, #"/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C LANG=C /usr/bin/perl -T -e '$ENV{PATH}="/usr/bin:/bin:/usr/sbin:/sbin"; alarm 12; exec {"/usr/bin/sfltool"} "/usr/bin/sfltool", "dumpbtm"; exit 127;'"#)
        XCTAssertEqual(BackgroundStartupReadPlan.rootExecutionLimitSeconds, 12)
        XCTAssertEqual(BackgroundStartupReadPlan.authorizedTimeout, 120)
        XCTAssertEqual(BackgroundStartupReadPlan.outputLimit, 2 * 1024 * 1024)
    }
    func testSystemPromptContainsNoSuppliedCredentialOrApplicationAutomation() {
        for english in [true, false] {
            let script = BackgroundStartupReadPlan.authorizationScript(english: english)
            XCTAssertTrue(script.hasPrefix("do shell script \"/usr/bin/env -i"))
            XCTAssertTrue(script.contains("with administrator privileges with prompt"))
            XCTAssertTrue(script.hasSuffix("without altering line endings"))
            XCTAssertTrue(script.contains(#"exec {\"/usr/bin/sfltool\"}"#))
            for forbidden in ["password", "user name", "tell application", "System Events", "launchctl", "sudoers", "write", ">"] {
                XCTAssertFalse(script.contains(forbidden), forbidden)
            }
        }
    }
    #if os(macOS)
    func testFixedGuardCanExecAndItsDeadlineSurvivesExec() throws {
        // Exercise the actual fixed command's quoting, clean environment and
        // taint checks. Only the deadline and known target are substituted;
        // this test launches an unprivileged sleep and never authorizes.
        let command = BackgroundStartupReadPlan.rootCommand
            .replacingOccurrences(of: "alarm 12;", with: "alarm 1;")
            .replacingOccurrences(of: "/usr/bin/sfltool", with: "/bin/sleep")
            .replacingOccurrences(of: "\"dumpbtm\"", with: "\"5\"")
        let process = Process(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = FileHandle.nullDevice; process.standardError = errors
        let start = Date()
        try process.run(); process.waitUntilExit()
        let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal, detail)
        XCTAssertEqual(process.terminationStatus, 14, detail)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }
    #endif
    func testCancellationRequiresTheAppleScriptCancellationErrorSuffix() {
        XCTAssertTrue(BackgroundStartupReadPlan.authorizationWasCancelled(stderr: "execution error: User canceled. (-128)\n"))
        XCTAssertFalse(BackgroundStartupReadPlan.authorizationWasCancelled(stderr: "not authorized (-1743)"))
        XCTAssertFalse(BackgroundStartupReadPlan.authorizationWasCancelled(stderr: "(-128) appeared earlier, then read failed (1)"))
    }
}
