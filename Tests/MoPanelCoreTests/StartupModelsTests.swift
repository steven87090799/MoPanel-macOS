// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import MoPanelCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class StartupModelsTests: XCTestCase {
    private var folder: URL!
    private var executable: URL!
    private var userID: UInt32 = 0

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        folder = base.appendingPathComponent("MoPanelStartup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        userID = getuid() == 0 ? 501 : getuid()
        if getuid() == 0 { XCTAssertEqual(chown(folder.path, userID, gid_t.max), 0) }
        executable = folder.appendingPathComponent("harmless-fixture")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    override func tearDownWithError() throws {
        if let folder { try FileManager.default.removeItem(at: folder) }
    }

    private func write(_ name: String = "com.example.safe", label: String? = nil,
                       overrides: [String: Any] = [:], mode: Int = 0o644) throws -> URL {
        let url = folder.appendingPathComponent(name + ".plist")
        var values: [String: Any] = ["Label": label ?? name, "ProgramArguments": [executable.path, "argument with spaces", "$(not-executed)"]]
        for (key, value) in overrides { values[key] = value }
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        if getuid() == 0 { XCTAssertEqual(chown(url.path, userID, gid_t.max), 0) }
        return url
    }

    private func inspect(_ url: URL, scope: StartupScope = .userAgent) throws -> StartupPlistSnapshot {
        try StartupInventoryReader.inspect(url: url, folder: .init(url: folder, scope: scope), userID: userID)
    }

    func testEnablePlanPreservesUnicodePlistPathAsSingleArgument() throws {
        let url = try write("測試 ' $() path", label: "com.example.safe")
        let snapshot = try inspect(url)
        XCTAssertTrue(snapshot.canManageMetadata)
        let plan = try StartupCommandPlan(snapshot: snapshot, enable: true, previousOverride: .absent, loadState: .notLoaded, userID: userID)
        XCTAssertEqual(plan.commands, [["enable", "gui/\(userID)/com.example.safe"], ["bootstrap", "gui/\(userID)", url.path]])
        XCTAssertEqual(snapshot.arguments.last, "$(not-executed)")
    }

    func testDisablePlanOnlyTargetsVerifiedOwnService() throws {
        let snapshot = try inspect(write())
        let service = StartupLoadedService(path: snapshot.url.path, program: executable.path, state: "running", pid: 123)
        let plan = try StartupCommandPlan(snapshot: snapshot, enable: false, previousOverride: .enabled, loadState: .loaded(service), userID: userID)
        XCTAssertEqual(plan.commands, [["disable", "gui/\(userID)/com.example.safe"], ["bootout", "gui/\(userID)/com.example.safe"]])
        XCTAssertFalse(plan.matchesFreshState(override: .disabled, loadState: .loaded(service)))
        XCTAssertTrue(plan.matchesFreshState(override: .enabled, loadState: .loaded(.init(path: service.path, program: service.program, state: "not running", pid: nil))))
        XCTAssertThrowsError(try StartupCommandPlan(snapshot: snapshot, enable: false, previousOverride: .enabled,
            loadState: .loaded(.init(path: "/Library/LaunchAgents/other.plist", program: executable.path, state: "running", pid: 123)), userID: userID))
        XCTAssertThrowsError(try StartupCommandPlan(snapshot: snapshot, enable: true, previousOverride: .absent, loadState: .unknown("permission denied"), userID: userID))
        XCTAssertThrowsError(try StartupCommandPlan(snapshot: snapshot, enable: true, previousOverride: .absent, loadState: .notLoaded, userID: userID, duplicateLabel: true))
        XCTAssertThrowsError(try StartupCommandPlan(snapshot: snapshot, enable: true, previousOverride: .absent, loadState: .notLoaded, userID: 0))
    }

    func testAppleBuhoSharedScopeAndWritableFilesAreProtected() throws {
        XCTAssertTrue(try inspect(write("com.apple.owned")).guardReasons.contains(.protectedApple))
        XCTAssertTrue(try inspect(write("com.example.buhohelper")).guardReasons.contains(.protectedBuho))
        XCTAssertTrue(try inspect(write("com.example.shared"), scope: .sharedAgent).guardReasons.contains(.readOnlyScope))
        XCTAssertTrue(try inspect(write("com.example.daemon"), scope: .systemDaemon).guardReasons.contains(.readOnlyScope))
        XCTAssertTrue(try inspect(write("com.example.writable", mode: 0o666)).guardReasons.contains(.writableByOthers))
        XCTAssertTrue(try inspect(write("com.example.root", overrides: ["UserName": "root"])).guardReasons.contains(.privilegedConfiguration))
        XCTAssertTrue(try inspect(write("com.example.applepath", overrides: ["Program": "/System/Library/Example/agent"])).guardReasons.contains(.protectedApple))
    }

    func testSymlinksAndChangedSnapshotsAreRejected() throws {
        let original = try write()
        let alias = folder.appendingPathComponent("alias.plist")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
        XCTAssertThrowsError(try inspect(alias))
        let snapshot = try inspect(original)
        _ = try write(overrides: ["ProgramArguments": [executable.path, "changed after confirmation"]])
        XCTAssertThrowsError(try StartupInventoryReader.revalidate(snapshot, userID: userID))
        let executableAlias = folder.appendingPathComponent("linked-executable")
        try FileManager.default.createSymbolicLink(at: executableAlias, withDestinationURL: executable)
        XCTAssertTrue(try inspect(write("com.example.execsymlink", overrides: ["Program": executableAlias.path])).guardReasons.contains(.symbolicExecutable))
    }

    func testMalformedSchemaAndOversizedMetadataFailClosed() throws {
        XCTAssertThrowsError(try inspect(write("com.example.bool", overrides: ["Disabled": 1])))
        XCTAssertThrowsError(try inspect(write("com.example.args", overrides: ["ProgramArguments": "not an array"])))
        XCTAssertTrue(try inspect(write("com.example.relative", overrides: ["Program": "relative-command"])).guardReasons.contains(.invalidProgram))
        XCTAssertTrue(try inspect(write("com.example.label", label: "bad/target")).guardReasons.contains(.invalidLabel))
        let huge = folder.appendingPathComponent("huge.plist")
        try Data(repeating: 65, count: StartupInventoryReader.maximumFileBytes + 1).write(to: huge)
        XCTAssertThrowsError(try inspect(huge))
        let entity = folder.appendingPathComponent("entity.plist")
        try Data("<!DOCTYPE plist [<!ENTITY external SYSTEM 'file:///no-read'>]><plist><dict/></plist>".utf8).write(to: entity)
        XCTAssertThrowsError(try inspect(entity))
    }

    func testInventoryReportsErrorsAndNeverTraversesSubdirectories() throws {
        _ = try write()
        let nested = folder.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try Data("not read".utf8).write(to: nested.appendingPathComponent("nested.plist"))
        try Data("invalid plist".utf8).write(to: folder.appendingPathComponent("broken.plist"))
        let result = StartupInventoryReader.inventory(folders: [.init(url: folder, scope: .userAgent)], userID: userID)
        XCTAssertEqual(result.items.count, 2)
        XCTAssertEqual(result.items.filter { $0.error != nil }.count, 1)
        XCTAssertFalse(result.truncated)
    }

    func testMalformedFilesStillConsumeAggregateReadBudget() throws {
        let bytes = Data(repeating: 65, count: StartupInventoryReader.maximumFileBytes)
        let allowed = StartupInventoryReader.maximumTotalBytes / bytes.count
        for index in 0...allowed { try bytes.write(to: folder.appendingPathComponent("broken-\(index).plist")) }
        let result = StartupInventoryReader.inventory(folders: [.init(url: folder, scope: .userAgent)], userID: userID)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.items.count, allowed)
        XCTAssertTrue(result.items.allSatisfy { $0.error != nil })
    }

    func testDisabledMapRecognizesKnownFormatsWithoutGuessingAbsent() throws {
        let text = "disabled services = {\n\t\"com.example.one\" => true\n\t\"com.example.two\" => enabled\n}\n"
        let values = try LaunchctlOutputParser.disabledOverrides(Data(text.utf8))
        XCTAssertEqual(values["com.example.one"], .disabled)
        XCTAssertEqual(values["com.example.two"], .enabled)
        XCTAssertNil(values["com.example.absent"])
        for invalid in ["", "disabled services = {\n", "disabled services = {\n\"x\" => maybe\n}",
                        "disabled services = {\n\"x\" => true\n\"x\" => false\n}", "{\"x\": false}"] {
            XCTAssertThrowsError(try LaunchctlOutputParser.disabledOverrides(Data(invalid.utf8)))
        }
    }

    func testLoadedServiceRequiresMatchingHeaderAndCompleteIdentity() throws {
        let text = "gui/501/com.example.safe = {\n\tpath = /Users/Test User/Library/LaunchAgents/com.example.safe.plist\n\tprogram = /opt/vendor/bin/service\n\tstate = running\n\tpid = 123\n\tenvironment = {\n\t\tSECRET = not-returned\n\t}\n}\n"
        let result = try LaunchctlOutputParser.service(stdout: Data(text.utf8), stderr: Data(), exitCode: 0, domain: "gui/501", label: "com.example.safe")
        guard case .loaded(let service) = result else { return XCTFail("Expected loaded service") }
        XCTAssertEqual(service.pid, 123)
        XCTAssertEqual(service.path, "/Users/Test User/Library/LaunchAgents/com.example.safe.plist")
        XCTAssertThrowsError(try LaunchctlOutputParser.service(stdout: Data(text.utf8), stderr: Data(), exitCode: 0, domain: "gui/502", label: "com.example.safe"))
        XCTAssertThrowsError(try LaunchctlOutputParser.service(stdout: Data("gui/501/com.example.safe = {\n\tstate = running\n}\n".utf8), stderr: Data(), exitCode: 0, domain: "gui/501", label: "com.example.safe"))
    }

    func testMissingServiceIsDifferentFromPermissionFailure() throws {
        let missing = Data("Bad request.\nCould not find service \"com.example.safe\" in domain for user gui: 501\n".utf8)
        XCTAssertEqual(try LaunchctlOutputParser.service(stdout: Data(), stderr: missing, exitCode: 113, domain: "gui/501", label: "com.example.safe"), .notLoaded)
        XCTAssertThrowsError(try LaunchctlOutputParser.service(stdout: Data(), stderr: Data("Operation not permitted\n".utf8), exitCode: 1, domain: "gui/501", label: "com.example.safe"))
        XCTAssertThrowsError(try LaunchctlOutputParser.service(stdout: Data(), stderr: missing, exitCode: 113, domain: "gui/501", label: "com.example.other"))
    }

    func testLabelValidationCannotEscapeServiceTarget() {
        XCTAssertTrue(StartupCommandPlan.isSafeLabel("org.vendor.agent-1"))
        for label in ["", "-option", "a/b", "../x", "a\nnext", "a\0b", "a;evil", "$(cmd)", "服務", String(repeating: "a", count: 256)] {
            XCTAssertFalse(StartupCommandPlan.isSafeLabel(label), label)
        }
    }
}
