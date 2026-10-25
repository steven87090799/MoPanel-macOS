import Foundation

public struct AIToolCacheLocation: Equatable, Sendable {
    public let tool: String
    public let relativePath: String
}

/// Fixed rebuildable leaves only. Tool profiles, conversations and models are
/// deliberately absent; this is not permission to delete an AI tool's root.
public enum AIToolCachePolicy {
    public static let locations: [AIToolCacheLocation] = {
        var values: [AIToolCacheLocation] = []
        for tool in ["Claude", "Cursor", "Windsurf", "Qoder"] {
            for leaf in ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache"] {
                values.append(.init(tool: tool, relativePath: "Library/Application Support/\(tool)/\(leaf)"))
            }
        }
        for profile in ["Default", "Default/Partitions/codex-browser-app", "codex-browser-app"] {
            for leaf in ["Cache", "Code Cache"] {
                values.append(.init(tool: "Codex", relativePath: "Library/Caches/Codex/\(profile)/\(leaf)"))
            }
        }
        values.append(.init(tool: "OpenCode", relativePath: ".cache/opencode"))
        return values
    }()

    public static func location(for path: String, home: String) -> AIToolCacheLocation? {
        guard URL(fileURLWithPath: path).standardizedFileURL.path == path else { return nil }
        return locations.first { location in
            let root = home + "/" + location.relativePath
            return path == root || path.hasPrefix(root + "/")
        }
    }

    public static func ownerIsActive(path: String, home: String, executables: [String]) -> Bool {
        guard let tool = location(for: path, home: home)?.tool.lowercased() else { return false }
        return executables.contains { executable in
            let value = executable.lowercased()
            if tool == "codex" {
                return value.contains("/chatgpt.app/") || value.contains("/codex.app/") ||
                    URL(fileURLWithPath: value).lastPathComponent == "codex"
            }
            return value.contains("/\(tool).app/") || URL(fileURLWithPath: value).lastPathComponent == tool
        }
    }
}
