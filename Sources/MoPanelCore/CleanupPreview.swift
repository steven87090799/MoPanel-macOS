import Foundation

public struct CleanupPreviewItem: Identifiable, Sendable {
    public let path: String
    public let category: String
    public let size: String
    public let includedInParent: Bool
    public var id: String { path }
}

/// Display adapter for Mole's clean-list.txt. It is not a deletion instruction.
public enum CleanupPreviewDocument {
    public static func parse(_ text: String) throws -> [CleanupPreviewItem] {
        guard text.utf8.count <= 2_000_000, text.hasPrefix("# Mole Cleanup Preview - "),
              text.contains("\n# Summary\n"), text.contains("\n# Items: "), text.contains("\n# Categories: ") else {
            throw MoleError.invalidOutput("Unrecognized or oversized cleanup preview.")
        }
        var category = "Other", seen = Set<String>(), result: [CleanupPreviewItem] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("=== "), line.hasSuffix(" ===") { category = String(line.dropFirst(4).dropLast(4)); continue }
            guard line.hasPrefix("/"), let delimiter = line.range(of: "  # ", options: .backwards) else { continue }
            let path = String(line[..<delimiter.lowerBound])
            try SafePath.validateAbsolute(path)
            guard seen.insert(path).inserted else { continue }
            let metadata = String(line[delimiter.upperBound...])
            result.append(CleanupPreviewItem(path: path, category: category, size: String(metadata.split(separator: ",").first ?? ""), includedInParent: metadata.contains("counted under ")))
            guard result.count <= 20_000 else { throw MoleError.invalidOutput("Too many preview entries.") }
        }
        return result
    }
}

public enum ReviewPathPolicy {
    public static func permits(_ path: String, home: String) -> Bool {
        guard (try? SafePath.validateAbsolute(path)) != nil,
              URL(fileURLWithPath: path).standardizedFileURL.path == path,
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }),
              !path.contains("//") else { return false }
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        let personal = ["Mail", "Messages", "Keychains", "CloudStorage", "Mobile Documents", "Accounts", "Calendars", "Safari"]
        if personal.contains(where: { path == home + "/Library/" + $0 || path.hasPrefix(home + "/Library/" + $0 + "/") }) { return false }
        let userRoots = ["Library/Caches", "Library/Logs", "Library/Containers", "Library/Group Containers",
                         "Library/Application Support", "Library/Preferences", "Library/Application Scripts",
                         "Library/Saved Application State", ".cache"]
        if userRoots.contains(where: { path.hasPrefix(home + "/" + $0 + "/") }) { return true }
        let appRoots = ["/Applications/", home + "/Applications/"]
        return appRoots.contains { root in path.hasPrefix(root) && path.dropFirst(root.count).hasSuffix(".app") && !path.dropFirst(root.count).contains("/") }
    }
}
