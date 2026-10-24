import Foundation
import XCTest
@testable import MoPanelCore

final class ReadOnlyBenchmarkTests: XCTestCase {
    private var root: URL!
    private var runner: URL!
    private var session: URL!
    private var engine: URL!
    private let now = Date(timeIntervalSince1970: 100_000)
    private let manager = FileManager.default

    override func setUpWithError() throws {
        root = manager.temporaryDirectory.appendingPathComponent("MoPanelReadOnlyTests-" + UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
        runner = root.appendingPathComponent("runner", isDirectory: true)
        session = runner.appendingPathComponent("mopanel-real-benchmark-" + UUID().uuidString, isDirectory: true)
        engine = runner.appendingPathComponent("engine", isDirectory: true)
        for folder in [session!, engine.appendingPathComponent("lib/core", isDirectory: true), engine.appendingPathComponent("bin", isDirectory: true)] {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: session.path)
        for name in ["home", "tmp", "corpus"] { try manager.createDirectory(at: session.appendingPathComponent(name), withIntermediateDirectories: true) }
        let cli = engine.appendingPathComponent("mo")
        try Data("#!/bin/bash\nSCRIPT_DIR=\"$(dirname \"$SCRIPT_PATH\")\"\n".utf8).write(to: cli)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        try Data("# test-only core\n".utf8).write(to: engine.appendingPathComponent("lib/core/common.sh"))
        try writeSource()
        for index in 0..<3 {
            try Data(repeating: UInt8(index), count: 4096).write(to: session.appendingPathComponent("corpus/測試 \(index).dat"))
        }
    }

    override func tearDownWithError() throws { if let root { try manager.removeItem(at: root) } }

    private func writeSource(_ overrides: [String: Any] = [:]) throws {
        var source: [String: Any] = ["tag": "V1.62.0", "commit": MoleCompatibility.auditedCommit, "official_binaries_verified": true]
        source.merge(overrides) { _, new in new }
        try JSONSerialization.data(withJSONObject: source).write(to: engine.appendingPathComponent("MOPANEL_CI_SOURCE.json"))
    }

    private func prepare(_ mode: String = "scan", overrides: [String: Any] = [:]) throws -> [String: String] {
        let manifest = session.appendingPathComponent("manifest-\(mode).json")
        let report = session.appendingPathComponent("\(mode).json")
        var object: [String: Any] = [
            "schema_version": 1, "mode": mode, "created_at_epoch": now.timeIntervalSince1970,
            "session_root": session.path, "cli_path": engine.appendingPathComponent("mo").path,
            "cli_sha256": String(repeating: "a", count: 64),
            "home_path": session.appendingPathComponent("home").path,
            "tmp_path": session.appendingPathComponent("tmp").path,
            "corpus_path": session.appendingPathComponent("corpus").path, "report_path": report.path
        ]
        object.merge(overrides) { _, new in new }
        try JSONSerialization.data(withJSONObject: object).write(to: manifest)
        return ["CI": "true", "GITHUB_ACTIONS": "true", "RUNNER_TEMP": runner.path,
                "MOPANEL_BENCHMARK_MANIFEST": manifest.path, "MOPANEL_BENCHMARK_REPORT": report.path,
                "MOPANEL_AUDIT_CLI": engine.appendingPathComponent("mo").path]
    }

    private func load(_ mode: String = "scan", environment: [String: String]? = nil) throws -> ReadOnlyBenchmark {
        let values = try environment ?? prepare(mode)
        return try ReadOnlyBenchmark.load(arguments: ["MoPanel", "--benchmark-real", mode], environment: values, now: now)
    }

    func testPreparedSourceAndFlatCorpusAreAcceptedWithChildOnlyIsolation() throws {
        let config = try load()
        XCTAssertEqual(config.corpusFileCount, 3)
        XCTAssertEqual(config.corpusLogicalBytes, 12_288)
        XCTAssertEqual(config.sourceCommit, MoleCompatibility.auditedCommit)
        let base = ["HOME": "/untouched-user-home", "TMPDIR": "/untouched-temp", "PATH": "/usr/bin:/bin"]
        let child = config.childEnvironment(from: base)
        XCTAssertEqual(child["HOME"], session.appendingPathComponent("home").path)
        XCTAssertEqual(child["TMPDIR"], session.appendingPathComponent("tmp").path + "/")
        XCTAssertEqual(base["HOME"], "/untouched-user-home")
        XCTAssertEqual(child["PATH"], base["PATH"])
    }

    func testEveryRequiredCIGuardFailsWithoutDiscoveryFallback() throws {
        let environment = try prepare()
        for key in ["CI", "GITHUB_ACTIONS", "RUNNER_TEMP", "MOPANEL_BENCHMARK_MANIFEST", "MOPANEL_BENCHMARK_REPORT", "MOPANEL_AUDIT_CLI"] {
            var missing = environment
            missing.removeValue(forKey: key)
            XCTAssertThrowsError(try load(environment: missing), key)
        }
        var mismatched = environment
        mismatched["MOPANEL_AUDIT_CLI"] = "/opt/homebrew/bin/mo"
        XCTAssertThrowsError(try load(environment: mismatched))
    }

    func testMalformedAndMixedTestFlagsStayRecognizedButNeverRun() throws {
        let environment = try prepare()
        for flags in [["--benchmark-real"], ["--benchmark-real=scan"], ["--benchmark-real", "unknown"],
                      ["--benchmark-real", "scan", "--smoke-test"], ["--benchmark-real", "scan", "--benchmark", "idle"]] {
            let arguments = ["MoPanel"] + flags
            XCTAssertTrue(ReadOnlyBenchmark.isTestLaunch(arguments))
            XCTAssertTrue(ReadOnlyBenchmark.isRequested(arguments))
            XCTAssertThrowsError(try ReadOnlyBenchmark.load(arguments: arguments, environment: environment, now: now))
        }
        XCTAssertTrue(ReadOnlyBenchmark.isTestLaunch(["MoPanel", "--benchmark=scan"]))
        XCTAssertTrue(ReadOnlyBenchmark.isTestLaunch(["MoPanel", "--smoke-test-invalid"]))
        XCTAssertFalse(ReadOnlyBenchmark.isTestLaunch(["MoPanel"]))
    }

    func testSourceProvenanceAndChecksumShapeAreRequired() throws {
        for badSource: [String: Any] in [["official_binaries_verified": false], ["tag": "V1.62.0-windows"], ["commit": "unknown"]] {
            try writeSource(badSource)
            XCTAssertThrowsError(try load())
        }
        try writeSource()
        let badChecksum = try prepare(overrides: ["cli_sha256": "not-a-sha256"])
        XCTAssertThrowsError(try load(environment: badChecksum))
    }

    func testManifestPathsCannotTraverseOrUseAnUnrelatedHome() throws {
        let environment = try prepare(overrides: ["home_path": root.path])
        XCTAssertThrowsError(try load(environment: environment))
        let traversal = try prepare(overrides: ["corpus_path": session.path + "/home/../corpus"])
        XCTAssertThrowsError(try load(environment: traversal))
        let wrongReport = try prepare(overrides: ["report_path": root.appendingPathComponent("report.json").path])
        XCTAssertThrowsError(try load(environment: wrongReport))
    }

    func testSymlinkEscapesAndNestedCorpusAreRejected() throws {
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        let corpus = session.appendingPathComponent("corpus", isDirectory: true)
        let link = corpus.appendingPathComponent("escape")
        try manager.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try load())
        try manager.removeItem(at: link)
        let nested = corpus.appendingPathComponent("nested", isDirectory: true)
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        XCTAssertThrowsError(try load())
        try manager.removeItem(at: nested)
        try manager.removeItem(at: corpus)
        try manager.createSymbolicLink(at: corpus, withDestinationURL: outside)
        XCTAssertThrowsError(try load())
    }

    func testAllMutationsAndUnrelatedReadOnlyCommandsAreDenied() throws {
        let config = try load("monitor")
        for command: MoleCommand in [.menu, .clean, .uninstall, .optimize, .purge, .installer, .slim, .touchid, .completion, .update, .remove] {
            XCTAssertThrowsError(try config.validate(MoleInvocation.make(command: command)), command.rawValue)
            if command.hasDryRun { XCTAssertThrowsError(try config.validate(MoleInvocation.make(command: command, options: [.dryRun]))) }
        }
        XCTAssertThrowsError(try config.validate(MoleInvocation.make(command: .history, options: [.json])))
        XCTAssertThrowsError(try config.validate(MoleInvocation.make(command: .uninstall, options: [.uninstallList])))
        XCTAssertThrowsError(try config.validate(MoleInvocation.make(command: .analyze, options: [.json])))
        for command in MoleCommand.allCases where ![.menu, .help, .version].contains(command) {
            XCTAssertNoThrow(try config.validate(MoleInvocation.make(command: command, options: [.help])))
        }
        XCTAssertNoThrow(try config.validate(MoleInvocation.make(command: .help)))
        XCTAssertNoThrow(try config.validate(MoleInvocation.make(command: .version)))
    }

    func testMonitoringUsesExactJSONArgumentsWithAlertsDisabled() throws {
        let config = try load("monitor")
        XCTAssertNoThrow(try config.validate(config.snapshot))
        XCTAssertNoThrow(try config.validate(config.watch))
        XCTAssertTrue(try config.snapshot.arguments.contains("--proc-cpu-alerts=false"))
        XCTAssertTrue(try config.watch.arguments.contains("--proc-cpu-alerts=false"))
        XCTAssertFalse(try config.watch.requiresPTY)
        XCTAssertThrowsError(try config.validate(MoleInvocation.make(command: .status)))
        XCTAssertThrowsError(try config.validate(MoleInvocation.make(command: .status, options: [.json])))
        XCTAssertThrowsError(try config.validate(MoleInvocation.make(command: .status, options: [.watch, .procCPUAlerts(true)])))
        let idle = try load("idle")
        XCTAssertThrowsError(try idle.validate(config.watch))
    }

    func testAnalyzeRequiresExactCorpusAndRejectsRootReplacement() throws {
        let config = try load()
        XCTAssertNoThrow(try config.validate(config.scan))
        XCTAssertThrowsError(try config.validate(MoleInvocation.make(command: .analyze, options: [.json, .analyzePath(session.path)])))
        XCTAssertThrowsError(try config.validate(MoleInvocation.make(command: .analyze, options: [.analyzePath(config.corpus.path)])))
        let replacement = root.appendingPathComponent("replacement", isDirectory: true)
        try manager.createDirectory(at: replacement, withIntermediateDirectories: true)
        try manager.removeItem(at: config.corpus)
        try manager.createSymbolicLink(at: config.corpus, withDestinationURL: replacement)
        XCTAssertThrowsError(try config.validate(config.scan))
    }

    func testStaleConflictingAndPreviouslyWrittenManifestSessionsFail() throws {
        for override: [String: Any] in [["created_at_epoch": now.timeIntervalSince1970 - 1801], ["mode": "idle"], ["schema_version": 2]] {
            let environment = try prepare(overrides: override)
            XCTAssertThrowsError(try load(environment: environment))
        }
        let environment = try prepare()
        try Data("previous output".utf8).write(to: session.appendingPathComponent("scan.json"))
        XCTAssertThrowsError(try load(environment: environment))
    }
}
