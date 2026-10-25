import Foundation
import CryptoKit
import MoPanelCore
import MoPanelProcess

enum CLIProbe {
    static var environment: [String: String] {
        let original = ProcessInfo.processInfo.environment
        var safe: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_CTYPE"] {
            if let value = original[key] { safe[key] = value }
        }
        let local = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
        safe["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + local
        safe["TERM"] = "xterm-256color"
        safe["COLORTERM"] = "truecolor"
        safe["SHELL"] = "/bin/zsh"
        return safe
    }

    static func candidates(custom: String) throws -> [URL] {
        try MoleExecutableLayout.candidates(custom: custom, home: FileManager.default.homeDirectoryForCurrentUser,
                                            pathEnvironment: ProcessInfo.processInfo.environment["PATH"] ?? "")
    }

    static func fingerprint(_ executable: URL) throws -> String {
        let layout = try MoleExecutableLayout.inspect(executable)
        var digest = SHA256()
        digest.update(data: Data(layout.invoked.path.utf8))
        var files = [layout.resolved, layout.launcher]
        if let resources = layout.resources {
            digest.update(data: Data(resources.path.utf8))
            for directory in ["bin", "lib"] {
                let root = resources.appendingPathComponent(directory)
                guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
                    throw MoleError.incompatible("Unable to inspect the installed Mole resource directory.")
                }
                for case let file as URL in enumerator {
                    guard files.count < 2048 else { throw MoleError.incompatible("Unexpectedly large Mole resource layout.") }
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    if values.isRegularFile == true || values.isSymbolicLink == true { files.append(file) }
                }
            }
            let receipt = resources.appendingPathComponent("install_channel")
            if FileManager.default.fileExists(atPath: receipt.path) { files.append(receipt) }
        }
        for file in Set(files).sorted(by: { $0.path < $1.path }) {
            let resolved = file.resolvingSymlinksInPath()
            let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw MoleError.incompatible("An engine resource is no longer a regular file.")
            }
            digest.update(data: Data((file.path + "\n" + resolved.path + "\n").utf8))
            for key in [FileAttributeKey.systemFileNumber, .size, .modificationDate, .creationDate, .posixPermissions] {
                digest.update(data: Data(String(describing: attributes[key]).utf8))
            }
            // Hash scripts and receipts; metadata bounds the larger official Go
            // helpers without rereading tens of megabytes on every button press.
            let isScript = file == layout.launcher || file == layout.resolved || file.pathExtension == "sh" || file.lastPathComponent == "install_channel"
            if isScript {
                guard let size = attributes[.size] as? NSNumber, size.intValue <= 2 * 1024 * 1024 else {
                    throw MoleError.incompatible("An engine script exceeded the bounded inspection size.")
                }
                let data = try Data(contentsOf: resolved, options: .mappedIfSafe)
                guard data.count <= 2 * 1024 * 1024 else { throw MoleError.incompatible("Engine changed during inspection.") }
                digest.update(data: data)
            }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @MainActor static func detect(custom: String, fixture: URL? = nil) async throws -> CLIInstallation? {
        let paths = try fixture.map { [$0] } ?? candidates(custom: custom)
        if fixture == nil, !custom.isEmpty,
           let path = paths.first, !FileManager.default.isExecutableFile(atPath: path.path) {
            throw MoleError.incompatible("The selected Mole path is missing or not executable. Choose a valid path or clear the custom setting.")
        }
        var failures: [String] = []
        for url in paths where FileManager.default.isExecutableFile(atPath: url.path) {
            do { return try await inspect(url, fixture: fixture != nil) }
            catch {
                failures.append("\(url.path): \(error.localizedDescription)")
                if !custom.isEmpty { throw error }
            }
        }
        if !failures.isEmpty { throw MoleError.incompatible(failures.joined(separator: "\n")) }
        return nil
    }

    static func verifyBenchmarkLauncher(_ benchmark: ReadOnlyBenchmark) throws {
        let resolved = benchmark.cli.resolvingSymlinksInPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 2 * 1024 * 1024 else {
            throw MoleError.incompatible("Prepared benchmark launcher is missing or changed.")
        }
        let data = try Data(contentsOf: resolved, options: .mappedIfSafe)
        guard data.count <= 2 * 1024 * 1024,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == benchmark.cliSHA256 else {
            throw MoleError.incompatible("Prepared benchmark launcher checksum changed; no CLI probe was executed.")
        }
    }

    @MainActor static func inspect(_ url: URL, fixture: Bool, childEnvironment: [String: String]? = nil, workingDirectory: URL? = nil) async throws -> CLIInstallation {
        let processEnvironment = childEnvironment ?? environment
        let layout = try MoleExecutableLayout.inspect(url)
        let resolved = layout.resolved
        let signature = try fingerprint(url)
        // Never source a candidate or evaluate assignments from it.
        let probe = try await ProcessRunner.capture(ProcessRequest(executable: url, arguments: ["--version"], environment: processEnvironment, workingDirectory: workingDirectory, timeout: 15))
        guard probe.succeeded else {
            throw MoleError.incompatible("--version failed. " + String(decoding: probe.stderr, as: UTF8.self))
        }
        let output = String(decoding: probe.stdout, as: UTF8.self)
        guard let parsedVersion = MoleVersion.parseVersionOutput(output) else {
            throw MoleError.incompatible("The executable did not identify itself as Mole with a semantic version.")
        }
        let version = parsedVersion.description
        var help: [MoleCommand: String] = [:]
        var incompatible: [MoleCommand: String] = [:]
        for command in MoleCommand.allCases where command != .menu && command != .version {
            try Task.checkCancellation()
            let arguments = command == .help ? ["--help"] : [command.rawValue, "--help"]
            let result = try await ProcessRunner.capture(ProcessRequest(executable: url, arguments: arguments, environment: processEnvironment, workingDirectory: workingDirectory, timeout: 15))
            let text = String(decoding: result.stdout + result.stderr, as: UTF8.self)
            help[command] = text
            let missing = command.requiredHelpFlags.subtracting(TerminalText.optionNames(text))
            if !result.succeeded || !missing.isEmpty {
                incompatible[command] = "CLI help contract changed: " + missing.sorted().joined(separator: ", ")
            }
        }
        guard let main = help[.help], ["clean", "uninstall", "analyze", "status", "Mole"].allSatisfy({ main.localizedCaseInsensitiveContains($0) }) else {
            throw MoleError.incompatible("The executable's help is not a recognized Mole interface.")
        }
        if Int(version.split(separator: ".").first ?? "0") != 1 {
            for command in MoleCommand.allCases where command != .help && command != .version {
                incompatible[command] = "Unverified major CLI interface; update MoPanel before using this command."
            }
        }
        if !incompatible.isEmpty { incompatible[.menu] = "A command contract failed. The unrestricted main menu is disabled until compatibility is restored." }
        let resources = layout.resources
        let receiptChannel = resources.flatMap { root -> String? in
            let file = root.appendingPathComponent("install_channel")
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let bytes = attributes[.size] as? NSNumber, bytes.intValue <= 4096,
                  let receipt = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            return MoleExecutableLayout.installationChannel(in: receipt)
        }
        let source: InstallSource
        if fixture { source = .fixture }
        else if layout.launcher.path.contains("/Cellar/mole/") || output.contains("Install: Homebrew") { source = .homebrew }
        else if layout.launcher.path.hasPrefix("/nix/store/") || resources?.path.hasPrefix("/nix/store/") == true || output.contains("Install: Nix") { source = .nix }
        else if receiptChannel != nil { source = .script }
        else { source = .custom }
        guard try fingerprint(url) == signature else { throw MoleError.incompatible("CLI changed during compatibility checks. Retry detection.") }
        return CLIInstallation(executable: url, resolved: resolved, version: version, versionOutput: output,
                               source: source, resourceLocation: resources?.path, fingerprint: signature,
                               help: help, incompatible: incompatible,
                               compatibility: MoleCompatibility.assess(versionOutput: output, mainHelp: help[.help] ?? "", helps: help, installationChannel: receiptChannel))
    }

}
