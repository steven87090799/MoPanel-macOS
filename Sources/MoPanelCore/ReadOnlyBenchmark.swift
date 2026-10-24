import Foundation

public enum ReadOnlyBenchmarkMode: String, Decodable, Sendable { case idle, monitor, scan }

/// An explicit CI-only workload. This does not alter normal CLI discovery and
/// never supplies a fallback executable when test configuration is incomplete.
public struct ReadOnlyBenchmark: Sendable {
    public let mode: ReadOnlyBenchmarkMode
    public let sessionRoot: URL
    public let cli: URL
    public let cliSHA256: String
    public let home: URL
    public let temporaryDirectory: URL
    public let corpus: URL
    public let report: URL
    public let sourceTag: String
    public let sourceCommit: String
    public let corpusFileCount: Int
    public let corpusLogicalBytes: UInt64

    private struct Manifest: Decodable {
        let schemaVersion: Int
        let mode: ReadOnlyBenchmarkMode
        let createdAtEpoch: Double
        let sessionRoot: String
        let cliPath: String
        let cliSha256: String
        let homePath: String
        let tmpPath: String
        let corpusPath: String
        let reportPath: String
    }
    private struct SourceRecord: Decodable {
        let tag: String
        let commit: String
        let officialBinariesVerified: Bool
    }

    public static func isTestLaunch(_ arguments: [String]) -> Bool {
        arguments.dropFirst().contains { $0.hasPrefix("--benchmark") || $0.hasPrefix("--smoke-test") }
    }
    public static func isRequested(_ arguments: [String]) -> Bool {
        arguments.dropFirst().contains { $0.hasPrefix("--benchmark-real") }
    }

    public static func load(arguments: [String], environment: [String: String], now: Date = Date()) throws -> ReadOnlyBenchmark {
        guard arguments.count == 3, arguments[1] == "--benchmark-real",
              let requestedMode = ReadOnlyBenchmarkMode(rawValue: arguments[2]),
              environment["CI"] == "true", environment["GITHUB_ACTIONS"] == "true" else {
            throw MoleError.invalidArgument("Real read-only benchmarks require one explicit mode in GitHub CI; mixed or incomplete test flags are rejected.")
        }
        let runner = try existingDirectory(required("RUNNER_TEMP", in: environment))
        let manifestURL = try absoluteURL(required("MOPANEL_BENCHMARK_MANIFEST", in: environment))
        let manifestPath = manifestURL.resolvingSymlinksInPath()
        guard contained(manifestPath, in: runner) else { throw invalid("Manifest must be inside RUNNER_TEMP.") }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let manifest = try decoder.decode(Manifest.self, from: boundedFile(manifestPath, maximum: 32 * 1024))
        guard manifest.schemaVersion == 1, manifest.mode == requestedMode,
              manifest.createdAtEpoch.isFinite,
              (-5...1800).contains(now.timeIntervalSince1970 - manifest.createdAtEpoch) else {
            throw invalid("Benchmark manifest is stale, incompatible, or belongs to another mode.")
        }
        let root = try existingDirectory(manifest.sessionRoot)
        guard contained(root, in: runner), root.lastPathComponent.hasPrefix("mopanel-real-benchmark-"),
              manifestPath == root.appendingPathComponent("manifest-\(requestedMode.rawValue).json") else {
            throw invalid("Use a fresh, dedicated benchmark session directory.")
        }
        let permissions = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        guard let permissions, permissions.intValue & 0o022 == 0 else { throw invalid("Benchmark session must not be writable by other users.") }
        let home = try existingDirectory(manifest.homePath)
        let temporary = try existingDirectory(manifest.tmpPath)
        let corpus = try existingDirectory(manifest.corpusPath)
        guard home == root.appendingPathComponent("home", isDirectory: true),
              temporary == root.appendingPathComponent("tmp", isDirectory: true),
              corpus == root.appendingPathComponent("corpus", isDirectory: true) else {
            throw invalid("HOME, temporary files, and corpus must remain in their dedicated session subdirectories.")
        }
        let report = try absoluteURL(manifest.reportPath).resolvingSymlinksInPath()
        let expectedReport = root.appendingPathComponent("\(requestedMode.rawValue).json")
        let environmentReport = try absoluteURL(required("MOPANEL_BENCHMARK_REPORT", in: environment)).resolvingSymlinksInPath()
        guard report == expectedReport, environmentReport == report,
              !FileManager.default.fileExists(atPath: report.path) else { throw invalid("Benchmark report must be a fresh file inside this session.") }
        let cli = try absoluteURL(manifest.cliPath)
        let explicitCLI = try absoluteURL(required("MOPANEL_AUDIT_CLI", in: environment))
        guard cli == explicitCLI, contained(cli, in: runner), FileManager.default.isExecutableFile(atPath: cli.path),
              contained(cli.resolvingSymlinksInPath(), in: runner) else { throw invalid("Benchmark CLI must exactly match the prepared CI executable.") }
        let layout = try MoleExecutableLayout.inspect(cli)
        guard contained(layout.launcher, in: runner), let resources = layout.resources,
              contained(resources, in: runner) else { throw invalid("Benchmark engine resources must belong to the CI preparation directory.") }
        let source = try decoder.decode(SourceRecord.self, from: boundedFile(resources.appendingPathComponent("MOPANEL_CI_SOURCE.json"), maximum: 4096))
        guard source.officialBinariesVerified, MoleVersion(string: source.tag)?.isStable == true,
              hex(source.commit, count: 40), hex(manifest.cliSha256, count: 64) else {
            throw invalid("Prepared official source/checksum provenance is missing or invalid.")
        }
        // A flat corpus prevents the official analyzer's subdirectory cache from
        // turning repeated measurements into cached-tree lookups. Inspect once,
        // before the measured phase; the GUI does not duplicate each CLI scan.
        let files = try FileManager.default.contentsOfDirectory(at: corpus, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard files.count <= 25_000, requestedMode != .scan || !files.isEmpty else { throw invalid("Use 1–25,000 regular files for a scan workload.") }
        var bytes: UInt64 = 0
        for file in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size >= 0 else { throw invalid("Corpus must be flat regular files without symlinks or subdirectories.") }
            let sum = bytes.addingReportingOverflow(UInt64(size))
            guard !sum.overflow else { throw invalid("Corpus byte count overflowed.") }
            bytes = sum.partialValue
        }
        return ReadOnlyBenchmark(mode: requestedMode, sessionRoot: root, cli: cli, cliSHA256: manifest.cliSha256.lowercased(),
            home: home, temporaryDirectory: temporary, corpus: corpus, report: report,
            sourceTag: source.tag, sourceCommit: source.commit, corpusFileCount: files.count, corpusLogicalBytes: bytes)
    }

    public var snapshot: MoleInvocation { get throws { try MoleInvocation.make(command: .status, options: [.json, .procCPUAlerts(false)]) } }
    public var watch: MoleInvocation { get throws { try MoleInvocation.make(command: .status, options: [.watch, .intervalSeconds(2), .procCPUAlerts(false), .procCPUThreshold(100), .procCPUWindowSeconds(300)]) } }
    public var scan: MoleInvocation { get throws { try MoleInvocation.make(command: .analyze, options: [.json, .analyzePath(corpus.path)]) } }

    public func validate(_ invocation: MoleInvocation) throws {
        // Permit exactly the read-only help forms, never a loose "contains help"
        // shortcut that could admit another operation or a positional argument.
        if invocation.command == .help, invocation.arguments == ["--help"] { return }
        if invocation.command == .version, invocation.arguments == ["--version"] { return }
        if ![.menu, .help, .version].contains(invocation.command),
           invocation.arguments == [invocation.command.rawValue, "--help"] { return }
        guard !invocation.requiresPTY, !invocation.isDestructive else { throw Self.invalid("Interactive and mutating operations are forbidden in real benchmark mode.") }
        if mode == .monitor {
            let snapshot = try self.snapshot, watch = try self.watch
            if invocation == snapshot || invocation == watch { return }
        }
        if mode == .scan, invocation == (try scan) {
            // Recheck a root that could have been replaced while a child exited.
            guard try Self.existingDirectory(corpus.path).path == corpus.path else { throw Self.invalid("Corpus root changed during the benchmark.") }
            return
        }
        throw Self.invalid("This command or scan target is outside the benchmark's exact read-only allowlist.")
    }

    public func childEnvironment(from base: [String: String]) -> [String: String] {
        var result = base
        // Only this owned child receives the isolated home; the app and shell
        // process environment are never changed. ManagedProcess clears XDG and
        // other inherited hooks, so cache/config defaults stay beneath this home.
        result["HOME"] = home.path
        result["TMPDIR"] = temporaryDirectory.path + "/"
        return result
    }

    private static func required(_ key: String, in environment: [String: String]) throws -> String {
        guard let value = environment[key], !value.isEmpty else { throw invalid("Missing required benchmark environment: \(key).") }
        return value
    }
    private static func absoluteURL(_ path: String) throws -> URL {
        try SafePath.validateAbsolute(path)
        guard !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw invalid("Benchmark paths must not contain traversal components.") }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
    private static func existingDirectory(_ path: String) throws -> URL {
        let url = try absoluteURL(path).resolvingSymlinksInPath()
        guard try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory else { throw invalid("Required benchmark directory is missing.") }
        return URL(fileURLWithPath: url.path, isDirectory: true)
    }
    private static func contained(_ child: URL, in root: URL) -> Bool {
        let prefix = root.standardizedFileURL.path
        return child.standardizedFileURL.path.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/")
    }
    private static func boundedFile(_ url: URL, maximum: Int) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= maximum else { throw invalid("Benchmark metadata is missing, oversized, or not a regular file.") }
        let data = try Data(contentsOf: url)
        guard data.count <= maximum else { throw invalid("Benchmark metadata changed during validation.") }
        return data
    }
    private static func hex(_ value: String, count: Int) -> Bool {
        value.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
    private static func invalid(_ message: String) -> MoleError { .invalidArgument(message) }
}
