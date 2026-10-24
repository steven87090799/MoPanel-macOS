import Foundation

/// Read-only launcher layout discovery. No script is sourced or evaluated.
public struct MoleExecutableLayout: Sendable {
    public let invoked: URL
    public let resolved: URL
    public let launcher: URL
    public let resources: URL?

    public static func candidates(custom: String, home: URL, pathEnvironment: String) throws -> [URL] {
        if !custom.isEmpty {
            let path: String
            if custom.hasPrefix("~/") { path = home.appendingPathComponent(String(custom.dropFirst(2))).path }
            else { path = custom }
            try SafePath.validateAbsolute(path)
            // An explicit selection must never silently fall through to another engine.
            return [URL(fileURLWithPath: path)]
        }
        var paths = ["/opt/homebrew/bin/mo", "/usr/local/bin/mo", home.appendingPathComponent(".local/bin/mo").path]
        paths += pathEnvironment.split(separator: ":").compactMap {
            let path = String($0)
            guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
            return URL(fileURLWithPath: path).appendingPathComponent("mo").path
        }
        var seen = Set<String>()
        return paths.compactMap { seen.insert($0).inserted ? URL(fileURLWithPath: $0) : nil }
    }

    public static func inspect(_ executable: URL) throws -> MoleExecutableLayout {
        try SafePath.validateAbsolute(executable.path)
        let invoked = executable.standardizedFileURL
        let resolved = invoked.resolvingSymlinksInPath()
        let text = try launcherText(resolved)
        var launcher = resolved
        // The official lightweight alias uses the invoked directory, even when
        // the alias itself was reached through a symbolic link.
        if text.contains(#"exec "$SCRIPT_DIR/mole" "$@""#) {
            let adjacent = invoked.deletingLastPathComponent().appendingPathComponent("mole")
            guard FileManager.default.isExecutableFile(atPath: adjacent.path) else {
                throw MoleError.incompatible("The mo alias has no executable adjacent mole launcher.")
            }
            launcher = adjacent.resolvingSymlinksInPath()
        }
        let mainText = launcher == resolved ? text : try launcherText(launcher)
        let pinned = pinnedResourcePath(in: mainText).map { URL(fileURLWithPath: $0) }
        let candidates: [URL]
        if let pinned {
            // A relocated official install must not accidentally pick up another
            // installation's default ~/.config/mole receipt.
            candidates = [pinned]
        } else {
            candidates = [launcher.deletingLastPathComponent(),
                          launcher.deletingLastPathComponent().appendingPathComponent("libexec"),
                          launcher.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("libexec")]
        }
        let resources = candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("lib/core/common.sh").path)
        }?.resolvingSymlinksInPath()
        return MoleExecutableLayout(invoked: invoked, resolved: resolved, launcher: launcher, resources: resources)
    }

    public static func launcherText(_ url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, (1...(2 * 1024 * 1024)).contains(size.intValue) else {
            throw MoleError.incompatible("The Mole launcher is not a regular, bounded shell file.")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 2 * 1024 * 1024, let text = String(data: data, encoding: .utf8), text.hasPrefix("#!") else {
            throw MoleError.incompatible("The Mole launcher is not a recognized UTF-8 executable script.")
        }
        return text
    }

    public static func installationChannel(in receipt: String) -> String? {
        guard receipt.utf8.count <= 4096 else { return nil }
        let assignments = receipt.components(separatedBy: .newlines).filter { $0.hasPrefix("CHANNEL=") }
        guard assignments.count == 1 else { return nil }
        let channel = String(assignments[0].dropFirst("CHANNEL=".count))
        return ["stable", "nightly", "dev"].contains(channel) ? channel : nil
    }

    /// Parses only a literal shell word from official installer `printf %q` output.
    /// Supports escaped spaces and ANSI-C octal UTF-8; refuses substitutions.
    public static func pinnedResourcePath(in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines).filter { $0.hasPrefix("SCRIPT_DIR=") }
        guard lines.count == 1,
              let path = literalWord(String(lines[0].dropFirst("SCRIPT_DIR=".count))),
              path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        return path
    }

    private static func literalWord(_ value: String) -> String? {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty else { return nil }
        var out: [UInt8] = [], index = 0
        if bytes.count >= 3, bytes[0] == 36, bytes[1] == 39, bytes.last == 39 {
            index = 2
            while index < bytes.count - 1 {
                let byte = bytes[index]; index += 1
                if byte == 39 { return nil }
                if byte != 92 { out.append(byte); continue }
                guard index < bytes.count - 1 else { return nil }
                let escape = bytes[index]; index += 1
                if (48...55).contains(escape) {
                    var octal = Int(escape - 48), count = 1
                    while count < 3, index < bytes.count - 1, (48...55).contains(bytes[index]) {
                        octal = octal * 8 + Int(bytes[index] - 48); index += 1; count += 1
                    }
                    guard octal <= 255 else { return nil }; out.append(UInt8(octal))
                } else {
                    let escapes: [UInt8: UInt8] = [92: 92, 39: 39, 34: 34, 110: 10, 114: 13, 116: 9]
                    guard let decoded = escapes[escape] else { return nil }; out.append(decoded)
                }
            }
        } else if bytes.count >= 2, bytes.first == 39, bytes.last == 39 {
            let inner = bytes.dropFirst().dropLast()
            guard !inner.contains(39) else { return nil }; out = Array(inner)
        } else {
            let quoted = bytes.first == 34 && bytes.last == 34
            index = quoted ? 1 : 0
            let end = quoted ? bytes.count - 1 : bytes.count
            while index < end {
                let byte = bytes[index]; index += 1
                if byte == 92 {
                    guard index < end else { return nil }
                    let escaped = bytes[index]; index += 1
                    if quoted, ![36, 96, 34, 92].contains(escaped) { out.append(92) }
                    out.append(escaped)
                } else {
                    guard byte != 36, byte != 96, byte != 34, byte != 39 else { return nil }
                    if !quoted, byte <= 32 || [59, 38, 124, 60, 62, 40, 41, 42, 63, 91, 93, 123, 125, 126].contains(byte) { return nil }
                    out.append(byte)
                }
            }
        }
        return String(bytes: out, encoding: .utf8)
    }
}
