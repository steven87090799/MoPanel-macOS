import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Permit only a leaf project cache whose compiled files all retain ordinary,
/// same-user source files. No cache contents or Python code are executed.
public enum PythonCacheProof {
    public static func isCandidate(_ path: String, home: String) -> Bool {
        guard path.hasSuffix("/__pycache__"), !path.contains(".app/"),
              path.split(separator: "/").allSatisfy({ !$0.hasPrefix(".") }) else { return false }
        return ["Desktop", "Documents", "Downloads", "Developer", "Projects"].contains { path.hasPrefix(home + "/" + $0 + "/") }
    }
    public static func isRebuildable(_ path: String, home: String) -> Bool {
        guard isCandidate(path, home: home), (try? SafePath.validateAbsolute(path)) != nil else { return false }
        let directory = URL(fileURLWithPath: path)
        guard directory.resolvingSymlinksInPath().standardizedFileURL.path == path,
              ordinary(directory, kind: mode_t(S_IFDIR)),
              let children = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
              children.count <= 1000 else { return false }
        return children.allSatisfy { child in
            guard child.pathExtension == "pyc", let marker = child.lastPathComponent.range(of: ".cpython-"),
                  ordinary(child, kind: mode_t(S_IFREG)) else { return false }
            let stem = String(child.lastPathComponent[..<marker.lowerBound])
            guard !stem.isEmpty else { return false }
            return ordinary(directory.deletingLastPathComponent().appendingPathComponent(stem + ".py"), kind: mode_t(S_IFREG))
        }
    }
    private static func ordinary(_ url: URL, kind: mode_t) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_uid == getuid() && info.st_mode & mode_t(S_IFMT) == kind
    }
}
