// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Combine
import CryptoKit
import Foundation
import Security
import MoPanelCore
import MoPanelProcess

struct LocalUpdateApp: Identifiable, Sendable {
    enum Source: Sendable, Equatable { case appStoreReceipt, sparkle, manual }
    let url: URL
    let name: String
    let version: String?
    let bundleIdentifier: String?
    let source: Source
    let publisherFeed: URL?
    let feedWasWithheld: Bool
    var id: String { url.path }
}

struct AppUpdatePreview: Identifiable {
    let id = UUID()
    let plan: BrewUpdatePlan
    let output: String
    let createdAt: Date
    let executableFingerprint: String
}

private struct InstalledHomebrew {
    let layout: BrewExecutableLayout
    let version: String
    let fingerprint: String
    let capabilities: BrewUpdateCapabilities
}

/// An optional MoPanel native service. It does not extend, patch, or impersonate
/// Mole CLI. Construction does no scanning, networking, or process execution.
@MainActor final class AppUpdatesController: ObservableObject {
    /// App root supplies the other controllers' synchronous operation gate.
    /// The callback must exclude this controller to avoid a self-lock.
    var externalOperationInProgress: (() -> Bool)?
    @Published var language: String
    @Published private(set) var isBusy = false
    @Published private(set) var activity = ""
    @Published private(set) var items: [BrewUpdateItem] = []
    @Published private(set) var localApps: [LocalUpdateApp] = []
    @Published private(set) var localInventoryLoaded = false
    @Published private(set) var localInventoryNote = ""
    @Published private(set) var homebrewPath: String?
    @Published private(set) var homebrewVersion: String?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var canUpgrade = false
    @Published private(set) var canRefreshMetadata = false
    @Published private(set) var lastOutcome = ""
    @Published var errorMessage: String?
    @Published var pendingPreview: AppUpdatePreview?
    @Published var showOperation = false
    @Published private(set) var operationSession: ManagedProcess?
    @Published private(set) var operationTitle = ""
    @Published private(set) var cancellationRequested = false

    let actionsAllowed: Bool
    private let helperURL: URL?
    private var homebrew: InstalledHomebrew?
    private var selectedHomebrew: URL?
    private var captureSession: ManagedProcess?
    private var localScan: Task<([LocalUpdateApp], [String]), Error>?
    private var mutationRunning = false
    private var shuttingDown = false
    private var terminationObserver: NSObjectProtocol?

    init(language: String = "zh-Hant", helperURL: URL? = nil) {
        self.language = language; self.helperURL = helperURL
        actionsAllowed = !ReadOnlyBenchmark.isTestLaunch(ProcessInfo.processInfo.arguments)
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                      object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    func t(_ zh: String, _ en: String) -> String { language == "en" ? en : zh }

    func chooseHomebrew() {
        guard !isBusy, actionsAllowed else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = t("選擇現有 Homebrew 安裝的 bin/brew。不會下載或安裝 Homebrew。", "Choose bin/brew from an existing Homebrew installation. Nothing will be downloaded or installed.")
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let layout = try BrewExecutableLayout.inspect(url)
                selectedHomebrew = url; homebrew = nil
                homebrewPath = layout.executable.path; homebrewVersion = nil
                invalidateSnapshot()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    /// Explicitly reads Homebrew's installed metadata. Auto-update and analytics
    /// are disabled. Missing API cache may still be fetched by Homebrew itself.
    func checkHomebrew() async {
        guard begin(t("正在檢查 Homebrew 更新…", "Checking Homebrew updates…")) else { return }
        defer { endRead() }
        do {
            let brew = try await detectHomebrew()
            let snapshot = try await readSnapshot(brew)
            try checkCancellation()
            items = snapshot.items; lastChecked = Date()
            lastOutcome = t("已依目前 Homebrew 中繼資料完成檢查；這不是所有 App 的最新版本清單。", "Checked the current Homebrew metadata. This is not a latest-version inventory for every app.")
        } catch { finish(error) }
    }

    func scanLocalApplications() async {
        guard begin(t("讀取本機 App 更新來源…", "Reading local app update sources…")) else { return }
        defer { localScan = nil; endRead() }
        let scan = Task.detached(priority: .utility) { try Self.readLocalApplications() }
        localScan = scan
        do {
            let (apps, issues) = try await scan.value
            try checkCancellation()
            localApps = apps; localInventoryLoaded = true
            localInventoryNote = issues.isEmpty ? "" : t("部分位置無法讀取或超過掃描上限：", "Some locations could not be read or reached the scan bound: ") + issues.joined(separator: "; ")
        } catch { finish(error) }
    }

    func prepareUpdate(_ item: BrewUpdateItem) async {
        guard begin(t("正在產生官方 Homebrew 預覽…", "Preparing the official Homebrew preview…")) else { return }
        defer { endRead() }
        do {
            let selectedPlan = try BrewUpdatePlan(item: item)
            let brew = try await currentHomebrew(requireUpgrade: true)
            let snapshot = try await readSnapshot(brew)
            try selectedPlan.revalidate(in: snapshot)
            try requireApplicationsClosed(selectedPlan)
            let preview = try await capture(.preview(selectedPlan.identity), brew: brew, timeout: 180, limit: 1024 * 1024)
            try checkCancellation()
            let output = TerminalText.plain(preview.stdoutText + "\n" + preview.stderrText).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty else { throw failure("Homebrew 未提供 Dry Run 輸出，已停止更新。", "Homebrew returned no dry-run output. The update is blocked.") }
            items = snapshot.items; lastChecked = Date()
            pendingPreview = AppUpdatePreview(plan: selectedPlan,
                                             output: output,
                                             createdAt: Date(), executableFingerprint: brew.fingerprint)
        } catch { finish(error) }
    }

    /// The sheet supplies the exact reviewed object. Expiration, metadata drift,
    /// executable replacement, or a newly running app all invalidate consent.
    func confirmUpdate(_ preview: AppUpdatePreview) async {
        guard pendingPreview?.id == preview.id else { return }
        pendingPreview = nil
        guard begin(t("重新驗證已確認的更新…", "Revalidating the confirmed update…")) else { return }
        defer { mutationRunning = false; isBusy = false; activity = ""; captureSession = nil }
        do {
            guard (0...300).contains(Date().timeIntervalSince(preview.createdAt)) else {
                throw failure("預覽已超過 5 分鐘，請重新檢查並確認。", "This preview is older than five minutes. Review a new preview.")
            }
            let brew = try await currentHomebrew(requireUpgrade: true)
            guard brew.fingerprint == preview.executableFingerprint else {
                throw failure("Homebrew 已變更，請重新檢查。", "Homebrew changed. Check again before updating.")
            }
            let fresh = try await readSnapshot(brew)
            try preview.plan.revalidate(in: fresh)
            try requireApplicationsClosed(preview.plan)
            try checkCancellation()
            let result = try await perform(.upgrade(preview.plan.identity), brew: brew,
                                           title: t("Homebrew 更新：", "Homebrew update: ") + preview.plan.title)
            if result.succeeded {
                // A zero exit status is not presented as a verified app version.
                activity = t("更新後重新讀取版本…", "Reading versions after the update…")
                let verified = try await readSnapshot(brew)
                items = verified.items; lastChecked = Date()
                let installed = verified.items.first { $0.installed.identity == preview.plan.identity }?.installed.installed
                if installed == preview.plan.availableVersion {
                    lastOutcome = t("Homebrew 已完成，安裝版本已驗證：", "Homebrew completed; installed version verified: ") + preview.plan.availableVersion
                } else {
                    lastOutcome = t("Homebrew 回傳成功，但安裝版本尚未符合預覽；請查看原始輸出並重新檢查。", "Homebrew returned success, but the installed version does not match the preview. Review the output and check again.")
                }
            } else { describeOperationResult(result) }
        } catch { finish(error) }
    }

    /// Called only by the explicit metadata confirmation dialog. `brew update`
    /// updates Homebrew itself and taps; the UI states that effect before consent.
    func refreshMetadataAfterConfirmation() async {
        guard begin(t("更新 Homebrew 與索引…", "Updating Homebrew and metadata…")) else { return }
        defer { mutationRunning = false; isBusy = false; activity = ""; captureSession = nil }
        do {
            let brew = try await currentHomebrew(requireUpgrade: false)
            guard brew.capabilities.canRefresh else { throw failure("未驗證 brew update 介面。", "The brew update contract has not been verified.") }
            let result = try await perform(.refreshMetadata, brew: brew, title: t("更新 Homebrew 與索引", "Update Homebrew and Metadata"))
            // Even an interrupted metadata update may replace the executable.
            homebrew = nil; homebrewVersion = nil; invalidateSnapshot()
            if result.succeeded {
                lastOutcome = t("Homebrew 與索引更新完成。請按「檢查更新」重新驗證介面並讀取版本。", "Homebrew and metadata update completed. Check updates again to revalidate the interface and read versions.")
            } else { describeOperationResult(result) }
        } catch { finish(error) }
    }

    func cancelReadOnly() {
        guard !mutationRunning else { return }
        cancellationRequested = true; captureSession?.cancel(); localScan?.cancel()
    }
    func requestCancellation() {
        cancellationRequested = true; captureSession?.cancel(); localScan?.cancel(); operationSession?.cancel()
        if mutationRunning { lastOutcome = t("已要求取消；可能需要等待 Homebrew 安裝或回復結束。已完成的變更不保證復原。", "Cancellation requested; Homebrew may need to finish installation or rollback. Completed changes are not guaranteed to be undone.") }
    }
    func shutdown() {
        shuttingDown = true; requestCancellation()
    }

    func reveal(_ path: String) {
        guard actionsAllowed, !shuttingDown else { return }
        guard path.hasPrefix("/"), !path.utf8.contains(0), FileManager.default.fileExists(atPath: path) else {
            errorMessage = t("這個路徑已無法存取，請重新讀取清單。", "This path is no longer accessible. Refresh the inventory."); return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openApp(_ app: LocalUpdateApp) {
        guard actionsAllowed, !isBusy, !shuttingDown, externalOperationInProgress?() != true else { return }
        guard let bundle = Bundle(url: app.url), bundle.bundleIdentifier == app.bundleIdentifier else {
            errorMessage = t("App 已移動或識別資訊已變更，請重新讀取清單。", "The app moved or its identity changed. Refresh the inventory."); return
        }
        openApplication(app.url)
    }

    func openAppStore() {
        guard actionsAllowed, !isBusy, !shuttingDown, externalOperationInProgress?() != true else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.AppStore") else {
            errorMessage = t("找不到 App Store。", "App Store could not be found."); return
        }
        openApplication(url)
    }

    private func openApplication(_ url: URL) {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            if let error { Task { @MainActor [weak self] in self?.errorMessage = error.localizedDescription } }
        }
    }

    private func begin(_ title: String) -> Bool {
        guard actionsAllowed, !shuttingDown else {
            errorMessage = t("自動化測試模式禁止執行真實 App 更新服務。", "Real App Updates services are disabled in automated test mode."); return false
        }
        guard !isBusy else { return false }
        guard externalOperationInProgress?() != true else {
            errorMessage = t("請先等待目前的 Mole 或系統作業結束。", "Wait for the current Mole or system operation to finish."); return false
        }
        isBusy = true; activity = title; cancellationRequested = false; errorMessage = nil
        return true
    }
    private func endRead() { isBusy = false; activity = ""; captureSession = nil }
    private func checkCancellation() throws {
        if cancellationRequested || shuttingDown || Task.isCancelled { throw CancellationError() }
    }
    private func finish(_ error: Error) {
        if error is CancellationError || cancellationRequested {
            lastOutcome = t("作業已取消；已完成的變更不會自動復原。", "Operation cancelled. Completed changes are not automatically undone.")
        } else { errorMessage = error.localizedDescription }
    }
    private func failure(_ zh: String, _ en: String) -> NSError {
        NSError(domain: "MoPanel.AppUpdates", code: 1, userInfo: [NSLocalizedDescriptionKey: t(zh, en)])
    }
    private func invalidateSnapshot() {
        items = []; lastChecked = nil; pendingPreview = nil; canUpgrade = false; canRefreshMetadata = false
    }

    private var environment: [String: String] {
        ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1", "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK": "1"]
    }

    private func detectHomebrew() async throws -> InstalledHomebrew {
        let candidates = selectedHomebrew.map { [$0] }
            ?? BrewExecutableLayout.candidates(pathEnvironment: ProcessInfo.processInfo.environment["PATH"] ?? "")
        var problems: [String] = []
        for candidate in candidates {
            try checkCancellation()
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            do {
                let layout = try BrewExecutableLayout.inspect(candidate)
                let fingerprint = try Self.fingerprint(layout.executable)
                let version = try await captureDirect(.version, executable: layout.executable, timeout: 30)
                guard version.stdoutText.hasPrefix("Homebrew ") else { throw failure("執行檔未回報 Homebrew 版本。", "The executable did not report a Homebrew version.") }
                var helps: [BrewHelpCommand: String] = [:]
                for command in [BrewHelpCommand.info, .outdated, .upgrade, .update] {
                    helps[command] = try await captureDirect(.help(command), executable: layout.executable, timeout: 45).stdoutText
                }
                let capabilities = BrewUpdateCapabilities(infoHelp: helps[.info] ?? "", outdatedHelp: helps[.outdated] ?? "", upgradeHelp: helps[.upgrade] ?? "", updateHelp: helps[.update] ?? "")
                guard capabilities.canRead else { throw failure("Homebrew JSON v2 介面不相容，已停止更新功能。", "The Homebrew JSON v2 contract is incompatible. Updates are blocked.") }
                let brew = InstalledHomebrew(layout: layout, version: String(version.stdoutText.split(separator: "\n").first ?? "Homebrew"), fingerprint: fingerprint, capabilities: capabilities)
                homebrew = brew; homebrewPath = layout.executable.path; homebrewVersion = brew.version
                canUpgrade = capabilities.canUpgrade; canRefreshMetadata = capabilities.canRefresh
                return brew
            } catch is CancellationError { throw CancellationError() }
            catch { problems.append(candidate.path + ": " + error.localizedDescription) }
        }
        homebrew = nil; invalidateSnapshot()
        throw failure("找不到相容的現有 Homebrew。可選擇已安裝的 bin/brew。", "No compatible installed Homebrew was found. You can choose an existing bin/brew.")
            .adding(details: problems.joined(separator: "\n"))
    }

    private func currentHomebrew(requireUpgrade: Bool) async throws -> InstalledHomebrew {
        let brew: InstalledHomebrew
        if let current = homebrew { brew = current } else { brew = try await detectHomebrew() }
        guard try BrewExecutableLayout.inspect(brew.layout.executable) == brew.layout,
              try Self.fingerprint(brew.layout.executable) == brew.fingerprint else {
            homebrew = nil; invalidateSnapshot()
            throw failure("Homebrew 執行檔已變更，請重新檢查。", "The Homebrew executable changed. Check updates again.")
        }
        guard !requireUpgrade || brew.capabilities.canUpgrade else {
            throw failure("目前 Homebrew 缺少已驗證的 --no-quit／--require-sha／Dry Run 介面，僅提供唯讀資訊。", "This Homebrew lacks the verified --no-quit, --require-sha or dry-run interface. Only read-only information is available.")
        }
        if requireUpgrade {
            let help = try await capture(.help(.upgrade), brew: brew, timeout: 45).stdoutText
            guard Set(["--cask", "--dry-run", "--no-quit", "--require-sha"]).isSubset(of: TerminalText.optionNames(help)) else {
                canUpgrade = false
                throw failure("Homebrew 更新介面已變更，請重新檢查。", "The Homebrew upgrade contract changed. Check again.")
            }
        }
        return brew
    }

    private func readSnapshot(_ brew: InstalledHomebrew) async throws -> BrewUpdateSnapshot {
        let info = try await capture(.installedInfo, brew: brew)
        let outdated = try await capture(.outdated, brew: brew)
        let infoData = info.stdout, outdatedData = outdated.stdout
        let snapshot = try await Task.detached(priority: .utility) {
            try BrewUpdateSnapshot.decode(info: infoData, outdated: outdatedData)
        }.value
        try checkCancellation()
        return snapshot
    }
    private func capture(_ command: BrewUpdateCommand, brew: InstalledHomebrew, timeout: TimeInterval = 180, limit: Int = 16 * 1024 * 1024) async throws -> ProcessResult {
        try await captureDirect(command, executable: brew.layout.executable, timeout: timeout, limit: limit)
    }
    private func captureDirect(_ command: BrewUpdateCommand, executable: URL, timeout: TimeInterval, limit: Int = 16 * 1024 * 1024) async throws -> ProcessResult {
        try checkCancellation()
        guard !command.requiresConfirmation else { throw failure("變更指令只能從確認後的互動流程執行。", "Mutating commands require the confirmed interactive flow.") }
        let session = ManagedProcess(helperURL: helperURL)
        captureSession = session
        try session.start(request: ProcessRequest(executable: executable, arguments: command.arguments, environment: environment, timeout: timeout, outputLimit: limit))
        let result = await session.wait()
        captureSession = nil
        try checkCancellation()
        guard result.succeeded else {
            // Do not export raw stderr, URLs, environment, credentials or tokens.
            let reason = result.timedOut ? t("逾時", "timed out") : result.outputTruncated ? t("輸出超過上限", "output exceeded the bound") : "exit \(result.exitCode)"
            throw failure("Homebrew 指令失敗：", "Homebrew command failed: ")
                .adding(details: command.arguments.prefix(2).joined(separator: " ") + " (" + reason + ")")
        }
        return result
    }

    private func perform(_ command: BrewUpdateCommand, brew: InstalledHomebrew, title: String) async throws -> ProcessResult {
        try checkCancellation()
        guard command.requiresConfirmation else { throw failure("無效的變更指令。", "Invalid mutation command.") }
        let session = ManagedProcess(helperURL: helperURL)
        mutationRunning = true; operationSession = session; operationTitle = title; lastOutcome = ""
        activity = title; showOperation = true
        // No raw transcript is retained/exported, and password keystrokes are
        // never copied to a log. Keep Homebrew's native prompts and rollback.
        try session.start(request: ProcessRequest(executable: brew.layout.executable, arguments: command.arguments,
                                                  environment: environment, timeout: 0, retainsOutput: false,
                                                  cooperativeCancellation: true), interactive: true)
        let result = await session.wait()
        mutationRunning = false
        return result
    }

    private func requireApplicationsClosed(_ plan: BrewUpdatePlan) throws {
        let paths = Set(plan.applicationPaths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        guard !paths.isEmpty, !paths.contains(Bundle.main.bundleURL.resolvingSymlinksInPath().path) else {
            throw failure("更新目標無法安全確認，或包含目前執行中的 MoPanel。", "The update target cannot be established safely, or includes the running MoPanel app.")
        }
        let running = NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.resolvingSymlinksInPath().path }
        guard paths.isDisjoint(with: running) else {
            throw failure("請先儲存工作並自行關閉這個 App，再重新預覽。MoPanel 不會替你強制結束 App。", "Save your work and close this app before previewing again. MoPanel will not force-quit it.")
        }
    }
    private func describeOperationResult(_ result: ProcessResult) {
        if result.cancelled || cancellationRequested {
            lastOutcome = t("Homebrew 作業已取消；已完成變更可能保留。請重新檢查版本與 App 狀態。", "Homebrew was cancelled; completed changes may remain. Recheck the version and app state.")
        } else {
            lastOutcome = t("Homebrew 未成功完成，結束代碼：", "Homebrew did not complete successfully. Exit code: ") + String(result.exitCode)
        }
    }

    nonisolated private static func fingerprint(_ executable: URL) throws -> String {
        let data = try Data(contentsOf: executable, options: .mappedIfSafe)
        guard data.count <= 2_097_152 else { throw MoleError.invalidOutput("Homebrew launcher exceeds the size bound.") }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func readLocalApplications() throws -> ([LocalUpdateApp], [String]) {
        let fm = FileManager.default
        let roots = [URL(fileURLWithPath: "/Applications", isDirectory: true), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
        var queue = roots.map { ($0, 0) }, apps: [LocalUpdateApp] = [], issues: [String] = []
        var seen = Set<String>(), visited = 0
        while !queue.isEmpty {
            try Task.checkCancellation()
            let (folder, depth) = queue.removeFirst()
            guard fm.fileExists(atPath: folder.path) else { continue }
            guard let children = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
                issues.append(folder.path); continue
            }
            for child in children {
                try Task.checkCancellation()
                visited += 1
                guard visited <= 20_000, apps.count < 5_000 else { issues.append("Inventory limit"); return (apps, issues) }
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isDirectory == true else { continue }
                if child.pathExtension.lowercased() != "app" {
                    if depth < 2, values.isSymbolicLink != true { queue.append((child, depth + 1)) }
                    continue
                }
                let url = child.resolvingSymlinksInPath()
                guard seen.insert(url.path).inserted else { continue }
                let plistURL = url.appendingPathComponent("Contents/Info.plist")
                let resolvedPlist = plistURL.resolvingSymlinksInPath()
                guard resolvedPlist.path.hasPrefix(url.path + "/"),
                      let attributes = try? fm.attributesOfItem(atPath: plistURL.path),
                      attributes[.type] as? FileAttributeType == .typeRegular,
                      let size = attributes[.size] as? NSNumber,
                      size.intValue <= 1024 * 1024, let data = try? Data(contentsOf: plistURL), data.count <= 1024 * 1024,
                      let info = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else {
                    issues.append(child.lastPathComponent); continue
                }
                func text(_ key: String) -> String? {
                    guard let value = info[key] as? String, !value.isEmpty, value.utf8.count <= 32768 else { return nil }
                    return value
                }
                let receipt = fm.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path)
                let rawFeed = text("SUFeedURL")
                let feed = rawFeed.flatMap { PublisherFeedPolicy.displayableURL($0, signatureValid: validSignature(url)) }
                let source: LocalUpdateApp.Source = receipt ? .appStoreReceipt : rawFeed == nil ? .manual : .sparkle
                apps.append(LocalUpdateApp(url: url, name: text("CFBundleDisplayName") ?? text("CFBundleName") ?? child.deletingPathExtension().lastPathComponent,
                                           version: text("CFBundleShortVersionString") ?? text("CFBundleVersion"), bundleIdentifier: text("CFBundleIdentifier"),
                                           source: source, publisherFeed: feed, feedWasWithheld: rawFeed != nil && feed == nil))
            }
        }
        return (apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, issues)
    }

    nonisolated private static func validSignature(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(rawValue: 0), &code) == errSecSuccess, let code else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), nil) == errSecSuccess
    }
}

private extension NSError {
    func adding(details: String) -> NSError {
        guard !details.isEmpty else { return self }
        return NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: localizedDescription + "\n" + details])
    }
}
