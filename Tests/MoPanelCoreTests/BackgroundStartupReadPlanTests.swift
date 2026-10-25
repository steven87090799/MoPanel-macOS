import XCTest
@testable import MoPanelCore

final class BackgroundStartupReadPlanTests: XCTestCase {
    func testAuthorizedReadIsOneFixedCommandWithCleanEnvironmentAndRootDeadline() {
        XCTAssertEqual(BackgroundStartupReadPlan.rootCommand, #"/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C LANG=C /usr/bin/perl -T -e 'alarm 12; exec {"/usr/bin/sfltool"} "/usr/bin/sfltool", "dumpbtm"; exit 127;'"#)
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
    func testCancellationRequiresTheAppleScriptCancellationErrorSuffix() {
        XCTAssertTrue(BackgroundStartupReadPlan.authorizationWasCancelled(stderr: "execution error: User canceled. (-128)\n"))
        XCTAssertFalse(BackgroundStartupReadPlan.authorizationWasCancelled(stderr: "not authorized (-1743)"))
        XCTAssertFalse(BackgroundStartupReadPlan.authorizationWasCancelled(stderr: "(-128) appeared earlier, then read failed (1)"))
    }
}
