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
        // Package stores contain downloaded, rebuildable cache data, never the
        // complete tool configuration directory (for example ~/.npmrc).
        let cacheRoots = [".npm/_cacache", ".npm/_logs", ".gradle/caches", "Library/Developer/Xcode/DerivedData", "Library/Developer/CoreSimulator/Caches"]
        if cacheRoots.contains(where: { path.hasPrefix(home + "/" + $0 + "/") }) { return true }
        let appRoots = ["/Applications/", home + "/Applications/"]
        return appRoots.contains { root in path.hasPrefix(root) && path.dropFirst(root.count).hasSuffix(".app") && !path.dropFirst(root.count).contains("/") }
    }
}

public enum CleanupItemKind: Equatable, Sendable {
    case appCache, logs, packageCache, buildCache, trash, unknown
    public static func classify(_ path: String, home: String) -> Self {
        func inside(_ suffix: String) -> Bool { path == home + "/" + suffix || path.hasPrefix(home + "/" + suffix + "/") }
        if inside(".Trash") { return .trash }
        if inside(".npm/_cacache") || inside(".gradle/caches") { return .packageCache }
        if inside("Library/Developer/Xcode/DerivedData") || inside("Library/Developer/CoreSimulator/Caches") { return .buildCache }
        if inside("Library/Logs") || inside(".npm/_logs") { return .logs }
        if inside("Library/Caches") || inside(".cache") { return .appCache }
        return .unknown
    }
    public var recommended: Bool { self == .appCache || self == .logs }
    public var explanation: String {
        switch self {
        case .appCache: return "App 暫存資料；清理後，下次使用可能需要重新載入。"
        case .logs: return "診斷與執行紀錄；清理後無法再查看這些舊紀錄。"
        case .packageCache: return "開發工具下載的套件快取；清理後會在需要時重新下載，不會移除專案原始碼。"
        case .buildCache: return "可重新產生的編譯與模擬器快取；下一次建置可能較慢。"
        case .trash: return "已放入垃圾桶的檔案；請確認不需要後，再由 Finder 清空。"
        case .unknown: return "用途尚未確認，建議先保留；可展開詳細資訊查看位置。"
        }
    }
}
