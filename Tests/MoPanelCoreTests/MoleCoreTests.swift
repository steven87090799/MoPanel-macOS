import Foundation
import XCTest
@testable import MoPanelCore

final class MoleCoreTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
    private func changed(_ data: Data, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        change(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }
    private func helps(omitting: MoleCommand? = nil) -> [MoleCommand: String] {
        Dictionary(uniqueKeysWithValues: MoleCommand.allCases.filter { $0 != omitting }.map {
            ($0, "Usage: mo \($0.rawValue) " + $0.requiredHelpFlags.sorted().joined(separator: " "))
        })
    }
    private var rootHelp: String { "Mole\n" + MoleCommand.allCases.map(\.rawValue).joined(separator: " ") }

    func testStatusUsesOfficialUnitsAndEstimatedPerCoreFlag() throws {
        let snapshot = try MoleJSON.decodeStatus(fixture("status"))
        XCTAssertEqual(snapshot.diskIO?.readRate, 1.25)
        XCTAssertEqual(snapshot.network.first?.rxRateMbs, 0.125)
        XCTAssertEqual(snapshot.cpu.perCoreEstimated, true)
        XCTAssertEqual(snapshot.cpu.logicalCPU, 2)
        XCTAssertEqual(snapshot.memory.used, 8_589_934_592)
        XCTAssertEqual(snapshot.topProcesses.first?.cpu, 102.5) // Process CPU may exceed 100.
    }

    func testRequiredFlagsMatchAuditedUpstreamHelp() throws {
        let actualHelp = try JSONDecoder().decode([String: String].self, from: fixture("help-contract"))
        for command in MoleCommand.allCases where !command.requiredHelpFlags.isEmpty {
            let text = try XCTUnwrap(actualHelp[command.rawValue], "Missing upstream help for \(command)")
            let missing = command.requiredHelpFlags.subtracting(TerminalText.optionNames(text))
            XCTAssertTrue(missing.isEmpty, "Adapter requires flags upstream does not expose: \(command) \(missing)")
        }
    }

    func testStatusPreservesUnknownAndStaleData() throws {
        let snapshot = try MoleJSON.decodeStatus(fixture("status"))
        XCTAssertTrue(snapshot.batteries.isEmpty)
        XCTAssertNil(snapshot.disks.first?.purgeable)
        XCTAssertEqual(snapshot.processStale, true)
        XCTAssertNotNil(snapshot.processCollectedAt)
        XCTAssertEqual(snapshot.zombieParentsComplete, false)
        XCTAssertNil(ThermalStatus.availablePositive(snapshot.thermal?.cpuTemp))
        XCTAssertNil(ThermalStatus.availablePositive(snapshot.thermal?.systemPower))
    }

    func testAddedJSONFieldsAreForwardCompatible() throws {
        let data = try changed(fixture("status")) { $0["future_metric"] = ["extra": 42] }
        XCTAssertEqual(try MoleJSON.decodeStatus(data).healthScore, 88)
    }

    func testMissingRequiredStatusGroupFails() throws {
        let data = try changed(fixture("status")) { $0.removeValue(forKey: "cpu") }
        XCTAssertThrowsError(try MoleJSON.decodeStatus(data))
    }

    func testNoUsableCoreMetricsIsAnError() throws {
        let data = try changed(fixture("status")) {
            $0["cpu"] = ["usage": 0, "logical_cpu": 0]
            $0["memory"] = ["used": 0, "total": 0, "available": 0, "used_percent": 0, "swap_used": 0, "swap_total": 0]
            $0["disks"] = []
            $0.removeValue(forKey: "process_collected_at")
        }
        XCTAssertThrowsError(try MoleJSON.decodeStatus(data))
    }

    func testAnalyzePartialUnavailableAndLargeIntegers() throws {
        let snapshot = try MoleJSON.decodeAnalyze(fixture("analyze"))
        XCTAssertEqual(snapshot.scanStatus, .partial)
        XCTAssertEqual(snapshot.entries[0].measuredBytes, 9_007_199_254_740_993)
        XCTAssertEqual(snapshot.entries[1].measuredBytes, 2048)
        XCTAssertNil(snapshot.entries[2].measuredBytes) // Never convert unavailable to zero.
        XCTAssertEqual(snapshot.entries[3].measuredBytes, 0)
        XCTAssertTrue(snapshot.entries[3].name.contains("\n"))
        XCTAssertTrue(snapshot.entries[3].path.contains("$(echo blocked)"))
    }

    func testAnalyzeNewScanStatusFailsClosed() throws {
        let data = try changed(fixture("analyze")) { $0["scan_status"] = "invented-status" }
        XCTAssertThrowsError(try MoleJSON.decodeAnalyze(data))
    }

    func testAnalyzeInvalidTotalAndRelativePathFailClosed() throws {
        XCTAssertThrowsError(try MoleJSON.decodeAnalyze(changed(fixture("analyze")) { $0["total_size"] = -1 }))
        XCTAssertThrowsError(try MoleJSON.decodeAnalyze(changed(fixture("analyze")) { $0["path"] = "../../etc" }))
    }

    func testAnalyzeLargeListDoesNotTruncateEntries() throws {
        let entries: [[String: Any]] = (0..<25_000).map {
            ["scan_status": "complete", "name": "item \($0)", "path": "/tmp/fixture/item \($0)", "size": $0, "is_dir": false]
        }
        let data = try JSONSerialization.data(withJSONObject: ["scan_status": "complete", "path": "/tmp/fixture", "overview": false, "entries": entries, "total_size": 312_487_500])
        let snapshot = try MoleJSON.decodeAnalyze(data)
        XCTAssertEqual(snapshot.entries.count, 25_000)
        XCTAssertEqual(snapshot.entries.last?.name, "item 24999")
    }

    func testOfficialHistoryOutputKeepsIncompleteAndLegacyAttribution() throws {
        let history = try MoleJSON.decodeHistory(fixture("history"))
        XCTAssertEqual(history.sessions.count, 2)
        XCTAssertFalse(history.sessions[0].isComplete)
        XCTAssertFalse(history.sessions[0].isUnambiguous)
        XCTAssertEqual(history.sessions[0].attribution, "command")
        XCTAssertEqual(history.sessions[1].actions.failed, 1)
        XCTAssertEqual(history.sessions[1].actions.trashed, 1)
        XCTAssertNil(history.deletions[0].sizeKb)
    }

    func testHistoryAmbiguousSessionIsNotAuthoritative() throws {
        let data = try changed(fixture("history")) {
            var sessions = $0["sessions"] as! [[String: Any]]
            sessions[0]["attribution"] = "ambiguous"
            sessions[0]["run_id"] = "run-123"
            $0["sessions"] = sessions
        }
        XCTAssertFalse(try MoleJSON.decodeHistory(data).sessions[0].isUnambiguous)
    }

    func testAppInventoryIsAuthoritativeAndUnicodeSurvives() throws {
        let apps = try MoleJSON.decodeApps(fixture("apps"))
        XCTAssertEqual(apps[1].uninstallName, "程式 🐈")
        XCTAssertEqual(apps[2].source, "Homebrew")
        XCTAssertEqual(apps[2].size, "~50MB")
        XCTAssertEqual(try InstalledAppSelection.validatedNames(selected: [apps[0], apps[1]], inventory: apps), ["Text Edit", "程式 🐈"])
    }

    func testCaskAliasCannotPretendToBeExactPathSelection() throws {
        let apps = try MoleJSON.decodeApps(fixture("apps"))
        XCTAssertThrowsError(try InstalledAppSelection.validatedNames(selected: [apps[2]], inventory: apps))
    }

    func testDuplicateAppNamesRequireOfficialSelector() throws {
        let apps = try MoleJSON.decodeApps(fixture("apps"))
        var objects = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("apps")) as? [[String: Any]])
        var duplicate = objects[0]
        duplicate["path"] = "/Users/fixture/Applications/Text Edit.app"
        objects.append(duplicate)
        let inventory = try MoleJSON.decodeApps(JSONSerialization.data(withJSONObject: objects))
        XCTAssertThrowsError(try InstalledAppSelection.validatedNames(selected: [apps[0]], inventory: inventory))
    }

    func testUnsafeAppNameStillDisplaysButCannotBeSelectedDirectly() throws {
        let data = Data(#"[{"name":"-danger","bundle_id":"org.fixture","source":"App","uninstall_name":"-danger","path":"/Applications/-danger.APP","size":"1KB"}]"#.utf8)
        let apps = try MoleJSON.decodeApps(data)
        XCTAssertEqual(apps.count, 1)
        XCTAssertThrowsError(try InstalledAppSelection.validatedNames(selected: apps, inventory: apps))
    }

    func testCommandArgumentsPreserveShellMetacharactersLiterally() throws {
        let name = "Editor's $(touch never); 真實 App"
        let command = try MoleInvocation.make(command: .uninstall, options: [.dryRun, .apps([name])])
        XCTAssertEqual(command.arguments, ["uninstall", "--dry-run", name])
        XCTAssertFalse(command.isDestructive)
        XCTAssertFalse(command.requiresPTY)
    }

    func testUninstallDefaultsPreservePersonalDataAndTrash() throws {
        let command = try MoleInvocation.make(command: .uninstall, options: [.apps(["Text Edit"])])
        XCTAssertFalse(command.arguments.contains("--with-data"))
        XCTAssertFalse(command.arguments.contains("--permanent"))
        XCTAssertTrue(command.requiresPTY)
        XCTAssertTrue(command.isDestructive)
    }

    func testUnsupportedWhitelistAndInjectionOptionsRejected() throws {
        XCTAssertThrowsError(try MoleInvocation.make(command: .uninstall, options: [.whitelist]))
        XCTAssertThrowsError(try MoleInvocation.make(command: .clean, options: [.apps(["cache"])]))
        XCTAssertThrowsError(try MoleInvocation.make(command: .uninstall, options: [.apps(["--permanent"])]))
        XCTAssertThrowsError(try MoleInvocation.make(command: .uninstall, options: [.apps(["a\nb"])]))
    }

    func testConfigFlagsCannotMasqueradeAsDryRun() throws {
        XCTAssertThrowsError(try MoleInvocation.make(command: .clean, options: [.dryRun, .whitelist]))
        XCTAssertThrowsError(try MoleInvocation.make(command: .purge, options: [.dryRun, .purgePaths]))
    }

    func testAnalyzeInteractiveModeIsDestructiveCapable() throws {
        XCTAssertTrue(try MoleInvocation.make(command: .analyze).isDestructive)
        XCTAssertTrue(try MoleInvocation.make(command: .analyze).requiresPTY)
        XCTAssertFalse(try MoleInvocation.make(command: .analyze, options: [.json]).isDestructive)
    }

    func testStatusWatchDoesNotNeedPTYAndIntervalsAreBounded() throws {
        let invocation = try MoleInvocation.make(command: .status, options: [.watch, .intervalSeconds(2), .procCPUAlerts(false)])
        XCTAssertEqual(invocation.arguments, ["status", "--watch", "--interval", "2s", "--proc-cpu-alerts=false"])
        XCTAssertFalse(invocation.requiresPTY)
        XCTAssertThrowsError(try MoleInvocation.make(command: .status, options: [.intervalSeconds(2)]))
        XCTAssertThrowsError(try MoleInvocation.make(command: .status, options: [.watch, .intervalSeconds(0)]))
    }

    func testSettingsOperationsHaveCorrectRiskAndPreview() throws {
        XCTAssertEqual(try MoleInvocation.make(command: .completion).risk, .changesSettings)
        XCTAssertEqual(try MoleInvocation.make(command: .completion, options: [.completionShell(.zsh)]).risk, .readOnly)
        XCTAssertEqual(try MoleInvocation.make(command: .touchid, options: [.touchID(.status)]).risk, .readOnly)
        XCTAssertEqual(try MoleInvocation.make(command: .touchid, options: [.touchID(.enable)]).risk, .changesSettings)
        XCTAssertEqual(try MoleInvocation.make(command: .remove).risk, .removesEngine)
        XCTAssertEqual(try MoleInvocation.make(command: .remove, options: [.dryRun]).risk, .readOnly)
        XCTAssertTrue(try MoleInvocation.make(command: .update, options: [.force, .nightly]).isDestructive)
    }

    func testExternalVolumeAndHistoryBounds() throws {
        XCTAssertNoThrow(try MoleInvocation.make(command: .clean, options: [.dryRun, .externalVolume("/Volumes/外接 SSD")]))
        XCTAssertThrowsError(try MoleInvocation.make(command: .clean, options: [.externalVolume("/")]))
        XCTAssertThrowsError(try MoleInvocation.make(command: .history, options: [.historyLimit(0)]))
        XCTAssertThrowsError(try MoleInvocation.make(command: .history, options: [.historyLimit(201)]))
    }

    func testVersionParsingRequiresMoleIdentity() throws {
        XCTAssertEqual(MoleVersion.parseVersionOutput("\u{1B}[32mMole version 1.62.0\u{1B}[0m\nArchitecture: arm64")?.description, "1.62.0")
        XCTAssertNil(MoleVersion.parseVersionOutput("Not Mole 1.62.0"))
        XCTAssertNil(MoleVersion(string: "1.62"))
    }

    func testNewStableEngineNegotiatesWithoutExactVersionPin() throws {
        let report = MoleCompatibility.assess(versionOutput: "Mole version 1.63.2", mainHelp: rootHelp, helps: helps())
        XCTAssertEqual(report.level, .compatibleInterface)
        XCTAssertNoThrow(try report.validate(MoleInvocation.make(command: .clean)))
    }

    func testMajorNightlyAndOldVersionsBlockMutation() throws {
        for text in ["Mole version 2.0.0", "Mole version 1.61.0", "Mole version 1.62.0\nChannel: Nightly (abc123)", "Mole version 1.62.0\nInstall: Homebrew (HEAD abc123)"] {
            let report = MoleCompatibility.assess(versionOutput: text, mainHelp: rootHelp, helps: helps())
            XCTAssertEqual(report.level, .blocked)
            XCTAssertThrowsError(try report.validate(MoleInvocation.make(command: .clean)))
            XCTAssertThrowsError(try report.validate(MoleInvocation.make(command: .analyze)))
            XCTAssertNoThrow(try report.validate(MoleInvocation.make(command: .history, options: [.json])))
        }
    }

    func testChangedHelpBlocksAffectedCommand() throws {
        var commandHelp = helps()
        commandHelp[.clean] = "Usage: mo clean --dry-run-unsafe --external --whitelist"
        let report = MoleCompatibility.assess(versionOutput: "Mole version 1.62.0", mainHelp: rootHelp, helps: commandHelp)
        XCTAssertThrowsError(try report.validate(MoleInvocation.make(command: .clean)))
        XCTAssertThrowsError(try report.validate(MoleInvocation.make(command: .menu)))
        XCTAssertNoThrow(try report.validate(MoleInvocation.make(command: .status, options: [.json])))
    }

    func testStableRecoveryRequiresOfficialScriptAndNoNightlyOption() throws {
        let report = MoleCompatibility.assess(versionOutput: "Mole version 1.62.0\nChannel: Nightly (abc1234)", mainHelp: rootHelp, helps: helps())
        XCTAssertEqual(report.level, .blocked)
        XCTAssertTrue(report.stableScriptRecoveryAvailable)
        let update = try MoleInvocation.make(command: .update)
        XCTAssertNoThrow(try report.validate(update, updateSource: .officialScript))
        XCTAssertNoThrow(try report.validate(MoleInvocation.make(command: .update, options: [.force, .debug]), updateSource: .officialScript))
        XCTAssertThrowsError(try report.validate(update))
        XCTAssertThrowsError(try report.validate(update, updateSource: .homebrew))
        XCTAssertThrowsError(try report.validate(MoleInvocation.make(command: .update, options: [.nightly]), updateSource: .officialScript))
        for command: MoleCommand in [.clean, .uninstall, .optimize, .analyze, .purge, .installer, .slim, .menu, .remove] {
            XCTAssertThrowsError(try report.validate(MoleInvocation.make(command: command), updateSource: .officialScript), command.rawValue)
        }
    }

    func testDevelopmentReceiptRemainsBlockedExceptStableRecovery() throws {
        // Upstream show_version does not print a Channel line for CHANNEL=dev.
        let report = MoleCompatibility.assess(versionOutput: "Mole version 1.62.0\nInstall: Manual", mainHelp: rootHelp, helps: helps(), installationChannel: "dev")
        XCTAssertEqual(report.channel, .development)
        XCTAssertEqual(report.level, .blocked)
        XCTAssertThrowsError(try report.validate(MoleInvocation.make(command: .clean), updateSource: .officialScript))
        XCTAssertNoThrow(try report.validate(MoleInvocation.make(command: .update), updateSource: .officialScript))
    }

    func testStableRecoveryRejectsOldNewMajorUnknownIdentityAndHelpDrift() throws {
        for version in ["Mole version 2.0.0", "Mole version 1.61.0", "Mole version 1.62.0-beta", "unidentified 1.62.0"] {
            let report = MoleCompatibility.assess(versionOutput: version + "\nChannel: Nightly", mainHelp: rootHelp, helps: helps())
            XCTAssertFalse(report.stableScriptRecoveryAvailable)
            XCTAssertThrowsError(try report.validate(MoleInvocation.make(command: .update), updateSource: .officialScript))
        }
        let identity = MoleCompatibility.assess(versionOutput: "Mole version 1.62.0\nChannel: Nightly", mainHelp: "unknown application", helps: helps())
        XCTAssertThrowsError(try identity.validate(MoleInvocation.make(command: .update), updateSource: .officialScript))
        var changed = helps()
        changed[.update] = "Usage: mo update --nightly"
        let drifted = MoleCompatibility.assess(versionOutput: "Mole version 1.62.0\nChannel: Nightly", mainHelp: rootHelp, helps: changed)
        XCTAssertFalse(drifted.stableScriptRecoveryAvailable)
        XCTAssertThrowsError(try drifted.validate(MoleInvocation.make(command: .update), updateSource: .officialScript))
    }

    func testHomebrewHEADIsNotTreatedAsStableRecovery() throws {
        let report = MoleCompatibility.assess(versionOutput: "Mole version 1.62.0\nInstall: Homebrew (HEAD abc1234)", mainHelp: rootHelp, helps: helps())
        XCTAssertEqual(report.channel, .homebrewHEAD)
        XCTAssertFalse(report.stableScriptRecoveryAvailable)
        for source: StableUpdateSource in [.homebrew, .officialScript, .unverified] {
            XCTAssertThrowsError(try report.validate(MoleInvocation.make(command: .update), updateSource: source))
        }
    }

    func testStableHomebrewUpdateStillWorks() throws {
        let report = MoleCompatibility.assess(versionOutput: "Mole version 1.62.0\nInstall: Homebrew", mainHelp: rootHelp, helps: helps())
        XCTAssertEqual(report.channel, .stable)
        XCTAssertNoThrow(try report.validate(MoleInvocation.make(command: .update), updateSource: .homebrew))
        XCTAssertNoThrow(try report.validate(MoleInvocation.make(command: .clean), updateSource: .homebrew))
    }

    func testMissingCLIIdentityDoesNotAuthorizeOperations() throws {
        let report = MoleCompatibility.assess(versionOutput: "Mole version 1.62.0", mainHelp: "unrelated executable", helps: helps())
        XCTAssertThrowsError(try report.validate(MoleInvocation.make(command: .clean)))
        XCTAssertThrowsError(try report.validate(MoleInvocation.make(command: .history, options: [.json])))
    }

    func testNDJSONFramesAcrossUTF8ChunkBoundaries() throws {
        let stream = Data("{\"name\":\"貓\"}\n{\"name\":\"two\"}\n".utf8)
        var framer = NDJSONFramer()
        var lines: [Data] = []
        for byte in stream { lines += try framer.append(Data([byte])) }
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(String(data: lines[0], encoding: .utf8), "{\"name\":\"貓\"}")
        XCTAssertNoThrow(try framer.finish())
    }

    func testNDJSONRejectsTruncatedAndOversizeLines() throws {
        var truncated = NDJSONFramer()
        _ = try truncated.append(Data("{\"a\":".utf8))
        XCTAssertThrowsError(try truncated.finish())
        var huge = NDJSONFramer(maximumLineBytes: 16)
        XCTAssertThrowsError(try huge.append(Data(repeating: 65, count: 17)))
        var framedHuge = NDJSONFramer(maximumLineBytes: 16)
        XCTAssertThrowsError(try framedHuge.append(Data((String(repeating: "x", count: 17) + "\n").utf8)))
    }
}
