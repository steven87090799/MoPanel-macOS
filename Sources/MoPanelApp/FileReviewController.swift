import AppKit
import SwiftUI
import Combine
import Darwin
import CryptoKit
import MoPanelCore

struct ReviewFile: Identifiable {
    var id: String { url.path }
    let url: URL
    let category: String
    let title: String
    let size: String
    let purpose: String
    let recommended: Bool
    var blockedReason: String?
    let device: Int32
    let inode: UInt64
    let modified: timespec
    let directory: Bool
    let identity: ReviewFileIdentity?
    var existsAtScan = true
    var associatedApp: String? = nil
    var expectedBundleID: String? = nil
    var selectable: Bool { blockedReason == nil }
}

struct ReviewMoveReceipt: Identifiable {
    let original: URL
    let trash: URL
    var id: String { original.path }
}

struct ReviewMoveFailure: Identifiable {
    let url: URL
    let summary: String
    let detail: String
    var id: String { url.path }
}

@MainActor final class FileReviewController: ObservableObject {
    @Published var files: [ReviewFile] = []
    @Published var categoryTitles: [String: String] = [:]
    @Published private(set) var removedPaths = Set<String>()
    @Published var selected = Set<String>()
    @Published var preparing = false
    @Published var busy = false
    @Published var progress: Double = 0
    @Published var message = ""
    @Published var confirming = false
    @Published var errors: [String] = []
    @Published private(set) var receipts: [ReviewMoveReceipt] = []
    @Published private(set) var failures: [ReviewMoveFailure] = []
    @Published private(set) var lastRun: ReviewRunOutcome?
    @Published var sourceDate: Date?
    @Published var needsRescan = false
    @Published private(set) var cleanupScanInProgress = false
    var onBusyChanged: ((Bool) -> Void)?
    var allowsChanges = false
    private var cancelRequested = false
    private var preparedApps = Set<String>()
    private var preparedAppModels: [InstalledApp] = []
    @Published private(set) var appsNeedingQuit = Set<String>()
    private var preparationID = UUID()
    private var cleanupPolicyFingerprint: String?
    private var cleanupPreviewFingerprint: String?
    private var cleanupScanStartedAt: Date?
    var canExecute: Bool { allowsChanges && !needsRescan && !preparing && !cleanupScanInProgress }
    var selectionSummary: String { "\(chosen.count) 項 · " + sizeSummary(chosen) }
    func sizeSummary(_ items: [ReviewFile]) -> String {
        var bytes: Int64 = 0, lowerBound = false, known = 0
        for file in items {
            guard let size = ReviewSizeEstimate.parse(file.size) else { lowerBound = true; continue }
            known += 1
            let sum = bytes.addingReportingOverflow(size.bytes)
            if sum.overflow { lowerBound = true } else { bytes = sum.partialValue }
            lowerBound = lowerBound || size.lowerBound
        }
        if known == 0 && !items.isEmpty { return "大小待確認" }
        return (lowerBound ? "至少 " : "約 ") + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }
    func categoryPurpose(_ items: [ReviewFile]) -> String {
        if items.allSatisfy({ $0.recommended }) { return "快取、紀錄或可重建內容，已預選建議項目。" }
        if items.allSatisfy({ !$0.selectable }) { return "需要另外處理；展開查看原因與處理方式。" }
        return "包含需確認用途的資料，建議保留；展開後可逐項選擇。"
    }
    var chosen: [ReviewFile] { files.filter { selected.contains($0.id) && $0.selectable } }
    var isCleanup: Bool { categoryTitles.isEmpty }
    func group(_ file: ReviewFile) -> String { isCleanup && !file.selectable ? "手動管理" : file.category }
    var categories: [String] {
        let order = ["App 快取與紀錄", "開發工具", "解除安裝殘留", "App 資料（需確認）", "系統資料", "垃圾桶", "手動管理"]
        return Set(files.map { group($0) }).sorted {
            let a = order.firstIndex(of: $0) ?? 5, b = order.firstIndex(of: $1) ?? 5
            return a == b ? $0.localizedStandardCompare($1) == .orderedAscending : a < b
        }
    }
    func items(in category: String) -> [ReviewFile] { files.filter { group($0) == category } }
    var selectableFiles: [ReviewFile] { files.filter(\.selectable) }
    var selectedSize: String { sizeSummary(chosen) }
    var totalSize: String { sizeSummary(selectableFiles) }
    var inventorySize: String {
        let roots = CleanupPreviewDocument.capacityRoots(files.map(\.id))
        return sizeSummary(files.filter { roots.contains($0.id) })
    }
    var retainedFiles: [ReviewFile] { files.filter { !$0.selectable } }
    func categoryExplanation(_ category: String) -> String {
        switch category {
        case "App 快取與紀錄": return "App 與瀏覽器的暫存、舊紀錄；清理後會按需重建。"
        case "開發工具": return "套件與建置快取；清理後首次下載或建置可能較慢。"
        case "解除安裝殘留": return "已移除 App 留下的內容，請確認是否仍需保留。"
        case "App 資料（需確認）": return "可能包含設定、登入資訊或個人內容，預設保留。"
        case "垃圾桶": return "已移至垃圾桶的檔案；請到 Finder 確認後再清空。"
        case "手動管理": return "受保護、無法讀取或不適合直接移除；不參與本次清理。"
        default: return "展開查看項目、用途與保留原因。"
        }
    }

    func recommend() { selected = Set(files.filter { $0.selectable && $0.recommended }.map(\.id)) }
    func set(_ ids: [String], selected value: Bool) {
        for id in ids where files.contains(where: { $0.id == id && $0.selectable }) {
            if value { selected.insert(id) } else { selected.remove(id) }
        }
    }

    @discardableResult func beginCleanupScan() -> Bool {
        guard !busy, !preparing, !cleanupScanInProgress else { return false }
        cleanupScanInProgress = true
        cleanupScanStartedAt = Date()
        files = []; selected = []; sourceDate = nil
        errors = []; failures = []; receipts = []; lastRun = nil
        message = ""; progress = 0; confirming = false; needsRescan = false
        categoryTitles = [:]; preparedApps = []; preparedAppModels = []
        cleanupPreviewFingerprint = nil; cleanupPolicyFingerprint = nil
        return true
    }

    func finishCleanupScan(error: String? = nil) {
        cleanupScanInProgress = false
        if let error { errors = [error]; message = "掃描未完成，請重新掃描。"; needsRescan = true }
    }

    func loadCleanupPreview(previewURL: URL? = nil) async {
        guard !busy, !preparing else { return }
        preparing = true; confirming = false
        defer { preparing = false }
        let url = previewURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/mole/clean-list.txt")
        do {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid(), info.st_size <= 2_000_000 else {
                files = []; selected = []; sourceDate = nil; needsRescan = true
                errors = ["未能讀取這次掃描的清單，請重新掃描。"]
                return
            }
            let previewDate = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
            if let started = cleanupScanStartedAt, previewDate < started {
                files = []; selected = []; sourceDate = nil; needsRescan = true
                errors = ["Mole 尚未產生這次掃描的新清單；未顯示舊結果，請重新掃描。"]
                return
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 2_000_001) ?? Data()
            let items = try CleanupPreviewDocument.parse(String(decoding: data, as: UTF8.self))
            let policy = try Self.cleanupPolicy()
            let previewFingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if cleanupPreviewFingerprint == previewFingerprint, cleanupPolicyFingerprint == policy.fingerprint, !needsRescan { return }
            cleanupPreviewFingerprint = previewFingerprint; cleanupPolicyFingerprint = policy.fingerprint
            errors = []; selected = []; failures = []; lastRun = nil; receipts = []
            needsRescan = policy.modified.map { $0 > Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9) } ?? false
            let loaded = await Task.detached(priority: .utility) {
                let activePaths = Self.runningExecutablePaths()
                return items.map { item in Self.describe(URL(fileURLWithPath: item.path), category: Self.categoryName(item.category), size: item.size,
                                                  purpose: nil, defaultRecommended: nil, extraBlock: item.includedInParent ? "容量已包含在上層項目；請選取上層項目" : nil, activePaths: activePaths) }
            }.value
            files = loaded.filter(\.existsAtScan)
            let staleItems = loaded.count - files.count
            needsRescan = needsRescan || staleItems > 0
            sourceDate = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            recommend()
            message = files.isEmpty ? "掃描完成，沒有可列出的清理項目。" : "掃描完成，請確認要移到垃圾桶的項目。"
            if needsRescan {
                selected = []
                message = staleItems > 0 ? "上次掃描後已有 \(staleItems) 項變更或移除，請重新掃描；不會重複列出已移除的檔案。" : "保護清單比掃描結果新，請先重新掃描。"
            }
        } catch { files = []; selected = []; needsRescan = true; errors = [error.localizedDescription] }
    }

    func prepareApps(_ apps: [InstalledApp], force: Bool = false) async {
        guard !busy else { return }
        let ids = Set(apps.map(\.path))
        guard force || ids != preparedApps else { return }
        preparedApps = ids
        preparedAppModels = apps
        let token = UUID(); preparationID = token
        cleanupPolicyFingerprint = nil; needsRescan = false
        preparing = true; files = []; selected = []; confirming = false
        defer { if preparationID == token { preparing = false } }
        categoryTitles = Dictionary(apps.map { ($0.path, $0.name) }, uniquingKeysWith: { first, _ in first })
        let duplicateIDs = Set(Dictionary(grouping: apps, by: \.bundleID).filter { $0.value.count > 1 }.keys)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path })
        appsNeedingQuit = Set(apps.map(\.path)).intersection(running)
        let loaded = await Task.detached(priority: .utility) { () -> [ReviewFile] in
            var output: [ReviewFile] = []
            for app in apps {
                let identityMatches = !app.bundleID.isEmpty && Self.bundleIdentifier(at: app.path) == app.bundleID
                let block = !identityMatches ? "App 識別已變更或無法確認，請重新掃描" : app.source.lowercased().contains("cask") || app.source.lowercased().contains("brew") ? "這個 App 由 Homebrew 管理；請從下方「完整卸載」處理，以免留下套件紀錄。" : running.contains(app.path) ? "App 正在執行，請先結束後重新選取" : nil
                var appFile = Self.describe(URL(fileURLWithPath: app.path), category: app.path, size: app.size,
                    purpose: "App 本體；移除後可重新安裝。", defaultRecommended: true, extraBlock: block)
                appFile.associatedApp = app.path; appFile.expectedBundleID = app.bundleID
                output.append(appFile)
                let bid = app.bundleID
                guard !duplicateIDs.contains(bid), !bid.isEmpty, bid.utf8.count < 240, bid.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }), !bid.hasPrefix("com.apple.") else { continue }
                for (path, purpose, recommended) in [
                    ("Library/Caches/" + bid, "App 快取；之後使用時會重新建立。", true),
                    ("Library/Logs/" + bid, "診斷紀錄；刪除後無法查看舊的問題紀錄。", true),
                    ("Library/Preferences/" + bid + ".plist", "偏好設定；移除後會恢復預設。建議保留。", false),
                    ("Library/Application Support/" + bid, "可能包含個人資料、下載內容與授權。建議保留。", false),
                    ("Library/Containers/" + bid, "App 沙盒，可能包含文件與登入資料。建議保留。", false),
                    ("Library/Application Scripts/" + bid, "App 自動化腳本，可能含自行建立的內容。建議保留。", false),
                    ("Library/Saved Application State/" + bid + ".savedState", "上次視窗狀態；不包含 App 本體。", true)
                ] {
                    let url = home.appendingPathComponent(path)
                    if FileManager.default.fileExists(atPath: url.path) {
                        var related = Self.describe(url, category: app.path, size: nil, purpose: purpose,
                                                    defaultRecommended: recommended, extraBlock: block)
                        related.associatedApp = app.path; related.expectedBundleID = app.bundleID
                        output.append(related)
                    }
                }
            }
            return output
        }.value
        guard preparationID == token else { return }
        files = loaded; sourceDate = Date(); recommend(); errors = []; message = ""; failures = []; lastRun = nil
    }

    func requestQuit(_ path: String) async {
        guard allowsChanges, !busy, !preparing, let expected = preparedAppModels.first(where: { $0.path == path }),
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == path }),
              app.bundleIdentifier == expected.bundleID, path != Bundle.main.bundlePath else { return }
        busy = true; onBusyChanged?(true); cancelRequested = false
        message = "正在要求結束 " + expected.name + "；如有未儲存內容，請在 App 中確認。"
        let accepted = app.terminate()
        let deadline = Date().addingTimeInterval(10)
        while accepted && !app.isTerminated && Date() < deadline && !cancelRequested {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
        }
        busy = false; onBusyChanged?(false)
        if app.isTerminated { await prepareApps(preparedAppModels, force: true) }
        else { message = "App 尚未結束，請完成 App 的儲存或關閉對話框後重試。" }
    }

    func reconcileInventory() {
        removedPaths = removedPaths.filter { !FileManager.default.fileExists(atPath: $0) }
    }

    func execute() async {
        guard canExecute, confirming, !busy, !chosen.isEmpty else { return }
        if let fingerprint = cleanupPolicyFingerprint, (try? Self.cleanupPolicy().fingerprint) != fingerprint {
            needsRescan = true; confirming = false; message = "保護清單已變更，請重新掃描。"; return
        }
        confirming = false; busy = true; onBusyChanged?(true); cancelRequested = false; progress = 0; errors = []; receipts = []; failures = []; lastRun = nil
        defer { busy = false; onBusyChanged?(false) }
        // Never move both a directory and its descendant independently.
        let ordered = chosen.sorted { $0.url.path.count < $1.url.path.count }
        var plan: [ReviewFile] = []
        for file in ordered where !plan.contains(where: { file.id.hasPrefix($0.id + "/") }) { plan.append(file) }
        var completed = Set<String>()
        var failedCount = 0
        func fail(_ file: ReviewFile, _ summary: String, detail: String = "") {
            failedCount += 1
            errors.append(file.title + "：" + summary)
            failures.append(ReviewMoveFailure(url: file.url, summary: summary, detail: detail))
            if let index = files.firstIndex(where: { $0.id == file.id }) { files[index].blockedReason = summary }
            selected.remove(file.id)
        }
        for (index, file) in plan.enumerated() {
            if cancelRequested { break }
            defer { progress = Double(index + 1) / Double(max(plan.count, 1)) }
            if let fingerprint = cleanupPolicyFingerprint, (try? Self.cleanupPolicy().fingerprint) != fingerprint {
                needsRescan = true; errors.append("保護清單已變更，停止其餘項目。請重新掃描。"); break
            }
            message = "正在移至垃圾桶：" + file.title
            if let app = file.associatedApp,
               (!completed.contains(app) || FileManager.default.fileExists(atPath: app)),
               Self.bundleIdentifier(at: app) != file.expectedBundleID {
                fail(file, "App 識別已變更，請重新掃描。"); continue
            }
            if let app = file.associatedApp, NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.path == app }) {
                fail(file, "App 已在執行，請先結束後重試。"); continue
            }
            guard Self.stillMatches(file) else { fail(file, "檔案狀態或存取權限已變更，已保留原處；請重新掃描。"); continue }
            let requested = file.url
            let result: (URL?, Error?) = await withCheckedContinuation { continuation in
                NSWorkspace.shared.recycle([requested]) { mapping, error in
                    let destination = mapping.first { $0.key.standardizedFileURL == requested.standardizedFileURL }?.value
                    continuation.resume(returning: (destination, error))
                }
            }
            if let failure = result.1 {
                let summary = ReviewAccessIssue.isPermissionError(failure)
                    ? "macOS 未允許移動此項目，已保留原處；不影響其他項目的清理。"
                    : "未能移至垃圾桶，檔案仍保留原處。"
                fail(file, summary, detail: failure.localizedDescription)
            }
            else if let destination = result.0 {
                completed.insert(file.id); removedPaths.insert(file.id)
                receipts.append(ReviewMoveReceipt(original: requested, trash: destination))
            } else { fail(file, "系統未確認此項目已移到垃圾桶，請到 Finder 檢查。") }
        }
        files.removeAll { file in completed.contains(file.id) || completed.contains(where: { file.id.hasPrefix($0 + "/") }) }
        selected.formIntersection(Set(files.map(\.id)))
        lastRun = ReviewRunOutcome(requested: plan.count, moved: completed.count, failed: failedCount, cancelled: cancelRequested)
        if failedCount > 0 { cleanupPreviewFingerprint = nil }
        if isCleanup, lastRun?.hasUnresolvedItems == false {
            // Reset the review, not the unchecked files on disk. A fresh scan
            // is the only way to display another cleanup plan.
            files = []; selected = []; sourceDate = nil
            cleanupPreviewFingerprint = nil; cleanupPolicyFingerprint = nil
        }
        message = cancelRequested ? "已停止；已移動 \(completed.count) 項，其餘保留原處。"
            : failedCount > 0 ? "已清理 \(completed.count) 項，\(failedCount) 項未處理；已移動的項目可從垃圾桶還原。"
            : lastRun?.hasUnresolvedItems == true ? "已清理 \(completed.count) 項，其餘項目尚未完成；請重新掃描。"
            : "已清理 \(completed.count) 項，可從垃圾桶還原。"
    }
    func cancel() { cancelRequested = true }

    nonisolated private static func bundleIdentifier(at path: String) -> String? {
        let url = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= 1_048_576,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1_048_577), data.count <= 1_048_576,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["CFBundleIdentifier"] as? String
    }

    nonisolated private static func cleanupPolicy() throws -> (fingerprint: String, modified: Date?) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/mole/whitelist")
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return ("absent", nil) }
            throw MoleError.invalidArgument("Unable to verify the Mole protection list.")
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size <= 262144 else { throw MoleError.invalidArgument("Unsafe Mole protection list.") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 262145) ?? Data()
        guard data.count <= 262144 else { throw MoleError.invalidArgument("Protection list exceeds its limit.") }
        return (SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9))
    }

    nonisolated private static func describe(_ url: URL, category: String, size: String?, purpose: String?, defaultRecommended: Bool?, extraBlock: String?, activePaths: [String]? = nil) -> ReviewFile {
        var info = stat(); let exists = lstat(url.path, &info) == 0
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let kind = CleanupItemKind.classify(url.path, home: home)
        let recommended = defaultRecommended ?? kind.recommended
        var block = extraBlock
        if !ReviewPathPolicy.permits(url.path, home: home) {
            block = kind == .pythonCache ? "編譯快取的原始碼、檔案類型或路徑尚未全部通過驗證，先保留。" : kind == .trash ? "已在垃圾桶中，請到 Finder 確認後清空。"
                : url.path.hasPrefix("/Library/") || url.path.hasPrefix("/System/") ? "系統資料，需要管理員授權；可用下方「完整清理」重新檢查與處理。"
                : "這個位置尚未確認可安全清理，先保留；可在 Finder 查看內容。"
        }
        if !exists { block = "檔案已不存在" }
        if exists && info.st_mode & S_IFMT != S_IFDIR && info.st_mode & S_IFMT != S_IFREG { block = "特殊檔案或連結，僅供查看" }
        if exists && info.st_uid != getuid() { block = "不屬於目前使用者，僅供查看" }
        if url.path.hasPrefix(Bundle.main.bundlePath) || url.path.hasPrefix(home + "/.codex") { block = "目前使用中的程式或工作資料，僅供查看" }
        if url.resolvingSymlinksInPath().standardizedFileURL.path != url.standardizedFileURL.path { block = "路徑包含連結，僅供查看" }
        let directory = exists && info.st_mode & S_IFMT == S_IFDIR
        let identity = try? ReviewFileIdentity.capture(url, home: home)
        if identity == nil, block == nil { block = "路徑、檔案身分或權限尚未通過驗證" }
        if block == nil, kind.needsIdleApplication {
            if let paths = activePaths ?? runningExecutablePaths() {
                if CleanupItemKind.activeCacheOwner(path: url.path, executablePaths: paths) {
                    block = "對應 App 或更新器正在執行，請結束後重新掃描，再清理可重建的快取。"
                }
            } else { block = "目前無法確認 App 是否仍在使用這些快取，先保留。" }
        }
        let accessIssue = exists && block == nil ? ReviewAccessIssue.inspect(url) : nil
        if let accessIssue { block = accessIssue.explanation }
        let displaySize = accessIssue != nil ? "大小未能讀取" : size ?? (block != nil ? "未讀取大小" : directory ? directorySize(url) : ByteCountFormatter.string(fromByteCount: max(0, info.st_size), countStyle: .binary))
        return ReviewFile(url: url, category: category, title: url.lastPathComponent, size: displaySize,
            purpose: purpose ?? kind.explanation,
            recommended: recommended, blockedReason: block, device: info.st_dev, inode: info.st_ino,
            modified: info.st_mtimespec, directory: directory, identity: identity, existsAtScan: exists)
    }
    nonisolated private static func runningExecutablePaths() -> [String]? {
        let capacity = min(max(Int(proc_listallpids(nil, 0)) + 128, 256), 16384)
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0, count < capacity else { return nil }
        return pids.prefix(Int(count)).compactMap { pid in
            var bytes = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
            return String(cString: bytes)
        }
    }
    nonisolated private static func directorySize(_ url: URL) -> String {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey]
        var partial = false
        guard let iterator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), errorHandler: { _, _ in partial = true; return false }) else { return "大小未知" }
        let deadline = Date().addingTimeInterval(0.35)
        var bytes: Int64 = 0, count = 0
        for case let child as URL in iterator {
            count += 1
            if count > 20_000 || Date() > deadline { partial = true; break }
            if let data = try? child.resourceValues(forKeys: keys), data.isSymbolicLink != true, data.isRegularFile == true { bytes += Int64(data.fileAllocatedSize ?? 0) }
        }
        return (partial ? "至少 " : "") + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }
    nonisolated private static func stillMatches(_ file: ReviewFile) -> Bool {
        let fresh = describe(file.url, category: file.category, size: file.size, purpose: file.purpose, defaultRecommended: file.recommended, extraBlock: nil)
        return fresh.selectable && file.identity?.stillMatches(file.url, home: FileManager.default.homeDirectoryForCurrentUser.path) == true
    }
    nonisolated private static func categoryName(_ value: String) -> String {
        let name = value.lowercased()
        if name.contains("developer") { return "開發工具" }
        if name.contains("trash") { return "垃圾桶" }
        if name.contains("orphan") || name.contains("remnant") { return "解除安裝殘留" }
        if name.contains("support") { return "App 資料（需確認）" }
        if name.contains("system") { return "系統資料" }
        if name.contains("user") || name.contains("app") || name.contains("browser") { return "App 快取與紀錄" }
        return value
    }
}

struct FileReviewView: View {
    @ObservedObject var controller: FileReviewController
    var language: String
    var operationInProgress = false
    var categoryFilter: String? = nil
    var showsActions = true
    var showsCategories = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = Set<String>()
    @State private var expandedFiles = Set<String>()
    private func t(_ zh: String, _ en: String) -> String { language == "en" ? en : zh }
    private var categories: [String] { categoryFilter.map { [$0] } ?? controller.categories }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsActions {
                VStack(alignment: .leading, spacing: 6) {
                    Text(controller.lastRun == nil ? t("準備開始清理", "Ready to Clean") : t("清理結果", "Cleanup Results")).font(.title2.bold())
                    Text(t("本次預覽列出 ", "Listed in this preview: ") + controller.inventorySize + " · \(controller.files.count) " + t("項", "items"))
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    Text(t("已選清理 ", "Selected to clean: ") + controller.selectedSize + t(" · 可自行勾選 ", " · Selectable: ") + controller.totalSize)
                        .font(.callout).monospacedDigit()
                    if !controller.retainedFiles.isEmpty {
                        Text(t("保留／另外處理 ", "Kept / managed separately: ") + controller.sizeSummary(controller.retainedFiles)
                             + " · \(controller.retainedFiles.count) " + t("項；展開「手動管理」查看原因。", "items; expand Manual Management for reasons."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(t("Mole 提供掃描候選 · MoPanel 判斷預選，可自行取消", "Candidates from Mole · Preselection by MoPanel; uncheck any item"))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.bottom, 6)
                FileReviewResultView(controller: controller, language: language)
                if controller.preparing { ProgressView(t("正在整理掃描結果…", "Preparing scan results…")) }
            }
            ForEach(showsCategories ? categories : [], id: \.self) { category in
                let items = categoryFilter != nil ? controller.files.filter { $0.category == category } : controller.items(in: category)
                let eligible = Set(items.filter(\.selectable).map(\.id))
                let selected = items.filter { $0.selectable && controller.selected.contains($0.id) }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        ReviewSelectionBox(state: ReviewSelectionState.resolve(eligible: eligible, selected: controller.selected),
                            label: controller.categoryTitles[category] ?? category,
                            identifier: "mopanel.review.category." + category) {
                            controller.set(Array(eligible), selected: !eligible.isSubset(of: controller.selected))
                        }.disabled(eligible.isEmpty || controller.busy || controller.preparing)
                        Button {
                            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                                if expanded.contains(category) { expanded.remove(category) } else { expanded.insert(category) }
                            }
                        } label: {
                            HStack(spacing: 14) {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 8) {
                                        Text(categoryFilter != nil ? t("清除", "Remove") : controller.categoryTitles[category] ?? category).font(.headline)
                                        Text(t("已選 ", "Selected ") + "\(selected.count)/\(items.count)").font(.caption).foregroundStyle(.secondary)
                                    }
                                    if categoryFilter == nil {
                                        Text(language == "en" ? (eligible.isEmpty ? "Kept in place; expand for the reason." : "Expand to select individual items and review their purpose.") : controller.categoryExplanation(category))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 10)
                                Text(controller.sizeSummary(selected) + " / " + controller.sizeSummary(items))
                                    .font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(MoPanelTheme.accent)
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                    .rotationEffect(.degrees(expanded.contains(category) ? 90 : 0)).foregroundStyle(.secondary)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel((controller.categoryTitles[category] ?? category) + t("，展開或收合明細", ", expand or collapse details"))
                    }.padding(16)
                    if expanded.contains(category) {
                        LazyVStack(spacing: 0) {
                            ForEach(items) { file in
                                Divider().opacity(0.4)
                                fileRow(file)
                            }
                        }.padding(.leading, categoryFilter == nil ? 28 : 8).padding(.trailing, 14).padding(.bottom, 8)
                    }
                }.moPanelGlass(cornerRadius: 16)
            }
            if showsActions {
                DisclosureGroup(t("更多資訊與執行方式", "More Information and Execution Method")) {
                    if let date = controller.sourceDate { Text(t("掃描時間：", "Scanned: ") + date.formatted(date: .abbreviated, time: .shortened)).font(.caption) }
                    Text(t("這裡列出已安裝 Mole CLI 本次預覽提供的項目，並非整台 Mac 的暫存總量。Mole 圖形版可能另外計入垃圾桶、開發產物與保留項目；已在垃圾桶的檔案不能再移至垃圾桶，須由 Finder 另行管理。", "This lists candidates supplied by the installed Mole CLI preview, not all cache storage on this Mac. Mole's GUI may also count Trash, development artifacts and retained data. Files already in Trash are managed separately in Finder."))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(t("掃描指令：mo clean --dry-run。勾選後使用 macOS 原生移至垃圾桶（NSWorkspace.recycle），可從垃圾桶還原。執行前重新確認檔案身分與存取權限；未勾選及手動管理項目不會移動。", "Scan: mo clean --dry-run. Selected files use macOS NSWorkspace.recycle and can be restored from Trash. File identity and access are checked again; unchecked and manual items stay in place."))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }.padding(.top, 6)
            }
        }.onAppear { if let categoryFilter { expanded.insert(categoryFilter) } }
    }
    private func fileRow(_ file: ReviewFile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                ReviewSelectionBox(state: controller.selected.contains(file.id) ? .all : .none, label: file.title, identifier: "mopanel.review.item." + file.id) {
                    controller.set([file.id], selected: !controller.selected.contains(file.id))
                }.disabled(!file.selectable || controller.busy || controller.preparing)
                VStack(alignment: .leading, spacing: 4) {
                    Text(file.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(file.url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path + "/", with: "~/"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(file.size).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                Button { if expandedFiles.contains(file.id) { expandedFiles.remove(file.id) } else { expandedFiles.insert(file.id) } } label: {
                    Image(systemName: file.selectable ? "info.circle" : "lock.shield")
                }.buttonStyle(.plain).foregroundStyle(file.selectable ? Color.secondary : .orange)
                    .help(t("用途與保留原因", "Purpose and reason to keep")).accessibilityLabel(t("查看 ", "Details for ") + file.title)
                Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: { Image(systemName: "folder") }
                    .buttonStyle(.plain).help(t("在 Finder 顯示", "Show in Finder")).disabled(!controller.allowsChanges)
                    .accessibilityLabel(t("在 Finder 顯示 ", "Show in Finder: ") + file.title)
            }
            if expandedFiles.contains(file.id) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(file.purpose).font(.caption).foregroundStyle(.secondary)
                    Text(t("勾選建議來源：MoPanel 本機規則（非 Mole 推薦標記）", "Recommendation source: MoPanel local rules, not a Mole recommendation flag")).font(.caption2).foregroundStyle(.secondary)
                    Text(file.selectable ? (file.recommended ? t("建議清理 · 可重新建立的暫存或舊紀錄", "Recommended · Rebuildable cache or old logs") : t("建議保留 · 請先確認是否仍需使用", "Recommended to keep · Review before selecting")) : t("已保留 · 不參與本次清理", "Kept · Excluded from this cleanup"))
                        .font(.caption.weight(.medium)).foregroundStyle(!file.selectable ? .orange : file.recommended ? MoPanelTheme.positive : .red)
                    if let reason = file.blockedReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                    Text(file.url.path).font(.caption.monospaced()).textSelection(.enabled)
                }.padding(.leading, 32)
            }
        }.padding(.vertical, 12)
            .contextMenu {
                Button(t("本次保留", "Keep This Time")) { controller.set([file.id], selected: false) }.disabled(controller.busy || controller.preparing)
                Button(t("複製路徑", "Copy Path")) {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(file.url.path, forType: .string)
                }.disabled(!controller.allowsChanges)
            }
    }
}

/// A native checkbox retains macOS' mixed-selection appearance and keyboard
/// accessibility instead of presenting a partially selected group as empty.
private struct ReviewSelectionBox: NSViewRepresentable {
    let state: ReviewSelectionState
    let label: String
    let identifier: String
    let action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.change))
        button.allowsMixedState = true
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.state = state == .all ? .on : state == .mixed ? .mixed : .off
        button.isEnabled = context.environment.isEnabled
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(identifier)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? { CGSize(width: 22, height: 24) }
    final class Coordinator: NSObject {
        var action: (() -> Void)?
        @objc func change() { action?() }
    }
}

struct FileReviewActionBar: View {
    @ObservedObject var controller: FileReviewController
    let language: String
    var operationInProgress = false
    var uninstall = false
    private func t(_ zh: String, _ en: String) -> String { language == "en" ? en : zh }
    var body: some View {
        VStack(spacing: 10) {
            if controller.busy { ProgressView(value: controller.progress).tint(MoPanelTheme.accent) }
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(controller.busy ? controller.message : t("已選 ", "Selected ") + "\(controller.chosen.count) " + t("項", "items")).font(.callout.weight(.medium)).lineLimit(1)
                    if !controller.busy {
                        HStack(spacing: 12) {
                            Button(t("全選", "All")) { controller.set(controller.files.map(\.id), selected: true) }
                            Button(t("全不選", "None")) { controller.selected = [] }
                            Button(t("建議", "Recommended")) { controller.recommend() }
                        }.buttonStyle(.borderless).font(.caption).disabled(controller.preparing || operationInProgress)
                    }
                }
                Spacer()
                if controller.busy { Button(t("停止", "Stop")) { controller.cancel() } }
                else {
                    VStack(alignment: .trailing, spacing: 4) {
                        NativeActionButton(t(uninstall ? "移除" : "清理", uninstall ? "Remove" : "Clean") + " · " + controller.selectedSize,
                                           identifier: uninstall ? "mopanel.uninstall.execute" : "mopanel.cleanup.execute", systemImage: "trash", appearance: .prominent) {
                            controller.confirming = true
                            Task { await controller.execute() }
                        }.controlSize(.large).disabled(controller.chosen.isEmpty || operationInProgress || !controller.canExecute)
                        Text(t("移至垃圾桶，可還原", "Moves to Trash; restorable")).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }.padding(16).moPanelGlass(cornerRadius: 18).padding(.horizontal, 20).padding(.vertical, 12)
    }
}

struct FileReviewResultView: View {
    @ObservedObject var controller: FileReviewController
    let language: String
    @State private var failuresExpanded = true
    private func t(_ zh: String, _ en: String) -> String { language == "en" ? en : zh }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let run = controller.lastRun {
                HStack(spacing: 20) {
                    Label(t("已移至垃圾桶", "Moved to Trash") + " \(run.moved)", systemImage: "checkmark.circle.fill").foregroundStyle(MoPanelTheme.positive)
                    if run.failed > 0 { Label(t("未處理", "Not moved") + " \(run.failed)", systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
                    if run.unprocessed > 0 { Text(t("尚未處理", "Unprocessed") + " \(run.unprocessed)").foregroundStyle(.secondary) }
                    Spacer()
                }.font(.callout.weight(.semibold))
                Text(run.cancelled ? t("已停止；未處理的檔案保留原處。", "Stopped; unprocessed files remain in place.") : t("移動成功的項目可從垃圾桶還原。其餘項目保留原處。", "Restore moved items from Trash. All other items remain in place.")).font(.caption).foregroundStyle(.secondary)
            } else if !controller.message.isEmpty && !controller.busy { Text(controller.message).font(.callout).foregroundStyle(.secondary) }
            if !controller.failures.isEmpty {
                DisclosureGroup(t("未處理的項目", "Items Not Moved") + " · \(controller.failures.count)", isExpanded: $failuresExpanded) {
                    ForEach(controller.failures) { failure in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(failure.url.lastPathComponent).font(.callout.weight(.semibold))
                            Text(failure.summary).font(.caption).foregroundStyle(.secondary)
                            DisclosureGroup(t("詳細資訊", "Details")) {
                                Text(failure.url.path).font(.caption.monospaced()).textSelection(.enabled)
                                if !failure.detail.isEmpty { Text(failure.detail).font(.caption).textSelection(.enabled) }
                                Text(t("不會自動更改權限或強制刪除。需要重試時，先檢查 Finder 權限，再重新掃描。", "No permission changes or forced deletion. Check access in Finder and scan again before retrying.")).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 5)
                    }
                }.tint(.orange)
            }
            ForEach(controller.errors.filter { error in
                !controller.failures.contains { error == $0.url.lastPathComponent + "：" + $0.summary }
            }, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            if !controller.receipts.isEmpty {
                DisclosureGroup(t("已移除的項目", "Removed Items") + " · \(controller.receipts.count)") {
                    ForEach(Array(controller.receipts.prefix(100))) { receipt in
                        HStack {
                            Text(receipt.original.lastPathComponent).font(.caption).lineLimit(1)
                            Spacer()
                            Button(t("在垃圾桶顯示", "Show in Trash")) { NSWorkspace.shared.activateFileViewerSelecting([receipt.trash]) }.font(.caption).disabled(!controller.allowsChanges)
                        }
                    }
                    if controller.receipts.count > 100 { Text(t("先顯示前 100 項；完整內容可在垃圾桶查看。", "Showing the first 100 items; inspect Trash for the full list.")).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
}
