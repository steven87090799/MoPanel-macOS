import Foundation
import XCTest
@testable import MoPanelCore

final class DiscoveryTests: XCTestCase {
    private let manager = FileManager.default
    private var directory: URL!

    override func setUpWithError() throws {
        directory = manager.temporaryDirectory.appendingPathComponent("MoPanelDiscovery-" + UUID().uuidString)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try manager.removeItem(at: directory) }
    }

    private func file(_ path: String, _ contents: String, executable: Bool = false) throws -> URL {
        let url = directory.appendingPathComponent(path)
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        if executable { try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        return url
    }

    func testExplicitPathDoesNotFallThroughToAnotherInstallation() throws {
        let candidates = try MoleExecutableLayout.candidates(custom: "~/custom tools/mo", home: directory, pathEnvironment: "/opt/homebrew/bin:/bin")
        XCTAssertEqual(candidates, [directory.appendingPathComponent("custom tools/mo")])
        XCTAssertThrowsError(try MoleExecutableLayout.candidates(custom: "relative/mo", home: directory, pathEnvironment: "/bin"))
    }

    func testDefaultCandidatesDeduplicateAndIgnoreRelativePATHComponents() throws {
        let candidates = try MoleExecutableLayout.candidates(custom: "", home: directory,
            pathEnvironment: "/opt/homebrew/bin::relative:/trusted/tools:/trusted/tools")
        XCTAssertEqual(candidates.map(\.path), ["/opt/homebrew/bin/mo", "/usr/local/bin/mo", directory.appendingPathComponent(".local/bin/mo").path, "/trusted/tools/mo"])
    }

    func testHomebrewSymlinkUsesResolvedResourceTree() throws {
        let launcher = try file("Cellar/mole/1.62/libexec/mole", "#!/bin/bash\nSCRIPT_DIR=\"$(dirname \"$SCRIPT_PATH\")\"\n", executable: true)
        _ = try file("Cellar/mole/1.62/libexec/lib/core/common.sh", "# official core fixture\n")
        _ = try file("bin/lib/core/common.sh", "# unrelated adjacent resource tree\n")
        let link = directory.appendingPathComponent("bin/mo")
        try manager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: link, withDestinationURL: launcher)
        let layout = try MoleExecutableLayout.inspect(link)
        XCTAssertEqual(layout.invoked, link)
        XCTAssertEqual(layout.resolved, launcher)
        XCTAssertEqual(layout.launcher, launcher)
        XCTAssertEqual(layout.resources, launcher.deletingLastPathComponent())
    }

    func testOfficialAliasUsesTheInvokedDirectory() throws {
        let launcher = try file("install/mole", "#!/bin/bash\nSCRIPT_DIR=\"$(dirname \"$SCRIPT_PATH\")\"\n", executable: true)
        _ = try file("install/lib/core/common.sh", "# fixture\n")
        let alias = try file("install/mo", "#!/bin/bash\nSCRIPT_DIR=\"$(dirname \"${BASH_SOURCE[0]}\")\"\nexec \"$SCRIPT_DIR/mole\" \"$@\"\n", executable: true)
        let layout = try MoleExecutableLayout.inspect(alias)
        XCTAssertEqual(layout.launcher, launcher)
        XCTAssertEqual(layout.resources, launcher.deletingLastPathComponent())
    }

    func testAliasMissingCompanionFailsWithoutDefaultFallback() throws {
        let alias = try file("install/mo", "#!/bin/bash\nexec \"$SCRIPT_DIR/mole\" \"$@\"\n", executable: true)
        XCTAssertThrowsError(try MoleExecutableLayout.inspect(alias))
    }

    func testLiteralRelocatedResourcesWinOverAdjacentResources() throws {
        let resource = directory.appendingPathComponent("custom resources")
        _ = try file("custom resources/lib/core/common.sh", "# relocated fixture\n")
        _ = try file("bin/lib/core/common.sh", "# unrelated fixture\n")
        let launcher = try file("bin/mole", "#!/bin/bash\nSCRIPT_DIR='\(resource.path)'\n", executable: true)
        let layout = try MoleExecutableLayout.inspect(launcher)
        XCTAssertEqual(layout.resources?.path, resource.path)
    }

    func testMissingPinnedResourcesNeverSelectAdjacentReceipt() throws {
        _ = try file("bin/lib/core/common.sh", "# unrelated installation\n")
        let launcher = try file("bin/mole", "#!/bin/bash\nSCRIPT_DIR='\(directory.path)/missing'\n", executable: true)
        XCTAssertNil(try MoleExecutableLayout.inspect(launcher).resources)
    }

    func testInstallerShellWordEscapesDecodeWithoutShellExecution() {
        XCTAssertEqual(MoleExecutableLayout.pinnedResourcePath(in: #"SCRIPT_DIR=/Users/Test\ User/.config/mole"#), "/Users/Test User/.config/mole")
        XCTAssertEqual(MoleExecutableLayout.pinnedResourcePath(in: #"SCRIPT_DIR=$'/tmp/\346\270\254\350\251\246/mole'"#), "/tmp/測試/mole")
        XCTAssertEqual(MoleExecutableLayout.pinnedResourcePath(in: #"SCRIPT_DIR="/tmp/with spaces/mole""#), "/tmp/with spaces/mole")
        XCTAssertEqual(MoleExecutableLayout.pinnedResourcePath(in: #"SCRIPT_DIR='/tmp/$literal/mole'"#), "/tmp/$literal/mole")
    }

    func testSubstitutionsMultipleAssignmentsAndNULAreRejected() {
        let unsafe = [#"SCRIPT_DIR="$(touch /tmp/never-execute)""#,
                      #"SCRIPT_DIR=`touch /tmp/never-execute`"#,
                      #"SCRIPT_DIR=/tmp/test; touch /tmp/never-execute"#,
                      "SCRIPT_DIR=/one\nSCRIPT_DIR=/two",
                      #"SCRIPT_DIR=$'/tmp/\000/mole'"#,
                      #"SCRIPT_DIR="${HOME}/.config/mole""#]
        for value in unsafe { XCTAssertNil(MoleExecutableLayout.pinnedResourcePath(in: value), value) }
    }

    func testReceiptChannelRequiresOneRecognizedBoundedAssignment() {
        XCTAssertEqual(MoleExecutableLayout.installationChannel(in: "CHANNEL=nightly\nCOMMIT_HASH=abc123\n"), "nightly")
        XCTAssertEqual(MoleExecutableLayout.installationChannel(in: "CHANNEL=dev\n"), "dev")
        XCTAssertEqual(MoleExecutableLayout.installationChannel(in: "CHANNEL=stable\n"), "stable")
        XCTAssertNil(MoleExecutableLayout.installationChannel(in: "CHANNEL=nightly\nCHANNEL=stable\n"))
        XCTAssertNil(MoleExecutableLayout.installationChannel(in: "CHANNEL=unknown\n"))
        XCTAssertNil(MoleExecutableLayout.installationChannel(in: "CHANNEL=stable\n" + String(repeating: "#", count: 4096)))
    }

    func testNonScriptAndOversizedLauncherFailBeforeAnyProbe() throws {
        let notScript = try file("binary-mo", "Mole version 1.62.0", executable: true)
        XCTAssertThrowsError(try MoleExecutableLayout.inspect(notScript))
        let large = try file("large-mo", "#!/bin/bash\n" + String(repeating: "#", count: 2 * 1024 * 1024), executable: true)
        XCTAssertThrowsError(try MoleExecutableLayout.inspect(large))
        XCTAssertThrowsError(try MoleExecutableLayout.inspect(directory))
    }
}
