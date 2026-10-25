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
    let blockedReason: String?
    let device: Int32
    let inode: UInt64
    let modified: timespec
    let directory: Bool
    let identity: ReviewFileIdentity?
    var associatedApp: String? = nil
    var expectedBundleID: String? = nil
    var selectable: Bool { blockedReason == nil }
}

struct ReviewMoveReceipt: Identifiable {
    let original: URL
    let trash: URL
    var id: String { original.path }
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
    @Published var sourceDate: Date?
    @Published var needsRescan = false
    var onBusyChanged: ((Bool) -> Void)?
    var allowsChanges = false
    private var cancelRequested = false
    private var preparedApps = Set<String>()
    private var preparedAppModels: [InstalledApp] = []
    @Published private(set) var appsNeedingQuit = Set<String>()
    private var preparationID = UUID()
    private var cleanupPolicyFingerprint: String?
    private var cleanupPreviewFingerprint: String?
    var canExecute: Bool { allowsChanges && !needsRescan && !preparing }
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
    var categories: [String] { Array(Set(files.map(\.category))).sorted() }

    func recommend() { selected = Set(files.filter { $0.selectable && $0.recommended }.map(\.id)) }
    func set(_ ids: [String], selected value: Bool) {
        for id in ids where files.contains(where: { $0.id == id && $0.selectable }) {
            if value { selected.insert(id) } else { selected.remove(id) }
        }
    }

    func loadCleanupPreview() async {
        guard !busy, !preparing else { return }
        preparing = true; confirming = false
        defer { preparing = false }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/mole/clean-list.txt")
        do {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid(), info.st_size <= 2_000_000 else { files = []; needsRescan = true; return }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 2_000_001) ?? Data()
            let items = try CleanupPreviewDocument.parse(String(decoding: data, as: UTF8.self))
            let policy = try Self.cleanupPolicy()
            let previewFingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if cleanupPreviewFingerprint == previewFingerprint, cleanupPolicyFingerprint == policy.fingerprint, !needsRescan { return }
            cleanupPreviewFingerprint = previewFingerprint; cleanupPolicyFingerprint = policy.fingerprint
            errors = []; selected = []
            needsRescan = policy.modified.map { $0 > Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9) } ?? false
            let loaded = await Task.detached(priority: .utility) {
                items.map { item in Self.describe(URL(fileURLWithPath: item.path), category: Self.categoryName(item.category), size: item.size,
                                                  purpose: nil, defaultRecommended: nil, extraBlock: item.includedInParent ? "容量已包含在上層項目；請選取上層項目" : nil) }
            }.value
            files = loaded
            sourceDate = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            recommend()
            message = files.isEmpty ? "掃描完成，沒有可列出的清理項目。" : "掃描完成，請確認要移到垃圾桶的項目。"
            if needsRescan { message = "保護清單比掃描結果新，請先重新掃描。" }
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
        files = loaded; sourceDate = Date(); recommend(); errors = []; message = ""
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
        confirming = false; busy = true; onBusyChanged?(true); cancelRequested = false; progress = 0; errors = []; receipts = []
        defer { busy = false; onBusyChanged?(false) }
        // Never move both a directory and its descendant independently.
        let ordered = chosen.sorted { $0.url.path.count < $1.url.path.count }
        var plan: [ReviewFile] = []
        for file in ordered where !plan.contains(where: { file.id.hasPrefix($0.id + "/") }) { plan.append(file) }
        var completed = Set<String>()
        for (index, file) in plan.enumerated() {
            if cancelRequested { break }
            if let fingerprint = cleanupPolicyFingerprint, (try? Self.cleanupPolicy().fingerprint) != fingerprint {
                needsRescan = true; errors.append("保護清單已變更，停止其餘項目。請重新掃描。"); break
            }
            message = "正在移至垃圾桶：" + file.title
            if let app = file.associatedApp,
               (!completed.contains(app) || FileManager.default.fileExists(atPath: app)),
               Self.bundleIdentifier(at: app) != file.expectedBundleID {
                errors.append(file.title + "：App 識別已變更，請重新掃描。"); continue
            }
            if let app = file.associatedApp, NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.path == app }) {
                errors.append(file.title + "：App 已在執行，請先結束後重試。"); continue
            }
            guard Self.stillMatches(file) else { errors.append(file.title + "：檔案已變更、路徑不安全或權限不足，已略過。"); continue }
            let requested = file.url
            let result: (URL?, Error?) = await withCheckedContinuation { continuation in
                NSWorkspace.shared.recycle([requested]) { mapping, error in
                    let destination = mapping.first { $0.key.standardizedFileURL == requested.standardizedFileURL }?.value
                    continuation.resume(returning: (destination, error))
                }
            }
            if let failure = result.1 { errors.append(file.title + "：" + failure.localizedDescription) }
            else if let destination = result.0 {
                completed.insert(file.id); removedPaths.insert(file.id)
                receipts.append(ReviewMoveReceipt(original: requested, trash: destination))
            } else { errors.append(file.title + "：系統未確認此項目已移到垃圾桶。") }
            progress = Double(index + 1) / Double(max(plan.count, 1))
        }
        files.removeAll { file in completed.contains(file.id) || completed.contains(where: { file.id.hasPrefix($0 + "/") }) }
        selected.formIntersection(Set(files.map(\.id)))
        message = cancelRequested ? "已停止；完成的項目仍可到垃圾桶復原。" : "完成，已移動 \(completed.count) 個項目。可在垃圾桶復原。"
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

    nonisolated private static func describe(_ url: URL, category: String, size: String?, purpose: String?, defaultRecommended: Bool?, extraBlock: String?) -> ReviewFile {
        var info = stat(); let exists = lstat(url.path, &info) == 0
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let kind = CleanupItemKind.classify(url.path, home: home)
        let recommended = defaultRecommended ?? kind.recommended
        var block = extraBlock
        if !ReviewPathPolicy.permits(url.path, home: home) {
            block = kind == .trash ? "已在垃圾桶中，請到 Finder 確認後清空。"
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
        let displaySize = size ?? (block != nil ? "未讀取大小" : directory ? directorySize(url) : ByteCountFormatter.string(fromByteCount: max(0, info.st_size), countStyle: .binary))
        return ReviewFile(url: url, category: category, title: url.lastPathComponent, size: displaySize,
            purpose: purpose ?? kind.explanation,
            recommended: recommended, blockedReason: block, device: info.st_dev, inode: info.st_ino,
            modified: info.st_mtimespec, directory: directory, identity: identity)
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
        if name.contains("system") { return "系統資料" }
        if name.contains("user") { return "App 快取與紀錄" }
        if name.contains("app") { return "App 專用快取" }
        if name.contains("trash") { return "垃圾桶" }
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
    @State private var expanded = Set<String>()
    @State private var expandedFiles = Set<String>()
    private func t(_ zh: String, _ en: String) -> String { language == "en" ? en : zh }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsActions {
            HStack {
                Text(t("選擇要移除的項目", "Choose Items to Remove")).font(.title3.bold())
                Spacer()
                Button(t("建議項目", "Recommended")) { controller.recommend() }.disabled(controller.busy || controller.preparing)
                Button(t("全選", "Select All")) { controller.set(controller.files.map(\.id), selected: true) }.disabled(controller.busy || controller.preparing)
                Button(t("全不選", "Select None")) { controller.selected = [] }.disabled(controller.busy || controller.preparing)
            }
            if controller.preparing { ProgressView(t("正在整理相關檔案…", "Reading related files…")) }
            if let date = controller.sourceDate { Text(t("掃描時間：", "Scanned: ") + date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(showsCategories ? (categoryFilter.map { [$0] } ?? controller.categories) : [], id: \.self) { category in
                let items = controller.files.filter { $0.category == category }
                let eligible = items.filter(\.selectable).map(\.id)
                HStack {
                    Toggle("", isOn: Binding(get: { !eligible.isEmpty && eligible.allSatisfy { controller.selected.contains($0) } }, set: { controller.set(eligible, selected: $0) })).labelsHidden().accessibilityLabel(controller.categoryTitles[category] ?? category).disabled(eligible.isEmpty)
                    DisclosureGroup(isExpanded: Binding(get: { expanded.contains(category) }, set: { if $0 { expanded.insert(category) } else { expanded.remove(category) } })) {
                        LazyVStack(spacing: 12) {
                            ForEach(items) { file in
                                HStack(alignment: .top, spacing: 10) {
                                    Toggle("", isOn: Binding(get: { controller.selected.contains(file.id) }, set: { controller.set([file.id], selected: $0) })).labelsHidden().accessibilityLabel(file.title).disabled(!file.selectable)
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack {
                                            Text(file.title).font(.callout.weight(.medium)); Spacer(); Text(file.size).font(.caption.monospacedDigit())
                                            Button {
                                                if expandedFiles.contains(file.id) { expandedFiles.remove(file.id) } else { expandedFiles.insert(file.id) }
                                            } label: { Image(systemName: "info.circle") }.buttonStyle(.plain).help(t("詳細資訊", "Details"))
                                                .accessibilityLabel(t("查看 ", "Details for ") + file.title)
                                        }
                                        Text(file.purpose).font(.caption).foregroundStyle(.secondary)
                                        Text(!file.selectable ? t("需要另外處理", "Needs another action") : file.recommended ? t("建議清理", "Recommended") : t("建議保留", "Recommended to keep"))
                                            .font(.caption.weight(.medium)).foregroundStyle(!file.selectable ? Color.orange : file.recommended ? MoPanelTheme.positive : .red)
                                        if expandedFiles.contains(file.id) {
                                            Text(file.url.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                            if let reason = file.blockedReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                                            Button(t("在 Finder 查看內容", "Inspect in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }.font(.caption)
                                        }
                                    }
                                }.padding(.vertical, 4)
                            }
                        }.padding(.top, 12)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(categoryFilter != nil ? t("相關檔案", "Related Files") : controller.categoryTitles[category] ?? category).font(.headline)
                                Spacer()
                                Text(controller.sizeSummary(items)).font(.callout).monospacedDigit()
                            }
                            Text("\(items.filter { controller.selected.contains($0.id) }.count) / \(items.count) " + t("項已選", "selected")).font(.caption).foregroundStyle(.secondary)
                            if categoryFilter == nil { Text(language == "en" ? "Expand to review individual items and recommendations." : controller.categoryPurpose(items)).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }.padding(16).moPanelGlass(cornerRadius: 16).disabled(controller.busy || controller.preparing)
            }
            if showsActions {
            if !controller.message.isEmpty { Text(controller.message).font(.callout) }
            ForEach(controller.errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
            if controller.busy {
                ProgressView(value: controller.progress)
                Button(t("停止", "Stop")) { controller.cancel() }
            } else if controller.confirming {
                Text(t("將選取項目移至垃圾桶，可復原。未勾選項目會保留。", "Move selected items to Trash; unchecked items stay in place.")).font(.callout)
                HStack { Button(t("取消", "Cancel")) { controller.confirming = false }; Spacer(); Button(t("確認移至垃圾桶", "Confirm Move to Trash")) { Task { await controller.execute() } }.buttonStyle(.borderedProminent).disabled(operationInProgress || !controller.canExecute || controller.chosen.isEmpty) }
            } else {
                HStack { Text(controller.selectionSummary); Spacer(); Button(t("移至垃圾桶…", "Move to Trash…")) { controller.confirming = true }.buttonStyle(.borderedProminent).disabled(controller.chosen.isEmpty || operationInProgress || !controller.canExecute) }
            }
            if !controller.receipts.isEmpty {
                DisclosureGroup(t("已移除的項目", "Removed Items") + " · \(controller.receipts.count)") {
                    ForEach(Array(controller.receipts.prefix(100))) { receipt in
                        HStack {
                            Text(receipt.original.lastPathComponent).font(.caption).textSelection(.enabled)
                            Spacer()
                            Button(t("在垃圾桶中顯示", "Show in Trash")) { NSWorkspace.shared.activateFileViewerSelecting([receipt.trash]) }.font(.caption)
                        }
                    }
                }
            }
            DisclosureGroup(t("詳細執行方式", "Execution Details")) { Text(t("macOS 原生移至垃圾桶：NSWorkspace.recycle。執行前會重新確認每個路徑與檔案身分，不使用 rm、不取得管理員權限，也不永久刪除。", "macOS NSWorkspace.recycle; paths and file identities are rechecked before each move. No rm, administrator access or permanent deletion.")).font(.caption).foregroundStyle(.secondary) }
            }
        }.onAppear { if let categoryFilter { expanded.insert(categoryFilter) } }
    }
}
