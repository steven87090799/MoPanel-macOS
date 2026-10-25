// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Combine
import Darwin
import ServiceManagement
import UniformTypeIdentifiers
import MoPanelCore
import MoPanelProcess

struct StartupRow: Identifiable {
    var id: String { item.id }
    let item: StartupInventoryItem
    var override: StartupOverride?
    var loadState: StartupLoadState
    var duplicateLabel: Bool
}

struct StartupSmokeReport: Codable {
    let inventoryCount: Int
    let enableVerifiedWithMock: Bool
    let disableVerifiedWithMock: Bool
    let cancelledReviewDidNotMutate: Bool
    let unknownFormatDidNotMutate: Bool
    let mutationArguments: [[String]]
    let realLaunchctlMutations: Int
    let persistentJobsCreated: Int
    let errors: [String]
}

private struct StartupCommandResult {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
}

@MainActor final class StartupController: ObservableObject {
    @Published private(set) var rows: [StartupRow] = []
    @Published private(set) var warnings: [String] = []
    @Published private(set) var hasLoaded = false
    @Published private(set) var isBusy = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusMessage = ""
    @Published private(set) var backgroundItems: [BackgroundStartupItem] = []
    @Published private(set) var backgroundReadAt: Date?
    @Published private(set) var backgroundIsImported = false
    @Published private(set) var backgroundReadError: String?
    @Published var pendingPlan: StartupCommandPlan?
    @Published var errorMessage: String?
    var language: String
    var externalOperationInProgress: (() -> Bool)?

    private let folders: [StartupFolder]
    private let userID: UInt32
    private var activeProcess: ManagedProcess?
    private var inventoryTask: Task<StartupInventory, Never>?
    private var cancelled = false
    private var mockRunner: (([String]) async throws -> StartupCommandResult)?

    init(language: String = "zh-Hant") {
        self.language = language
        folders = StartupFolder.standard(home: FileManager.default.homeDirectoryForCurrentUser)
        userID = getuid()
    }

    private init(language: String, folders: [StartupFolder], userID: UInt32,
                 mockRunner: @escaping ([String]) async throws -> StartupCommandResult) {
        self.language = language; self.folders = folders; self.userID = userID; self.mockRunner = mockRunner
    }

    private func t(_ zh: String, _ en: String) -> String { language == "en" ? en : zh }
    private var testLaunchBlocked: Bool {
        mockRunner == nil && ReadOnlyBenchmark.isTestLaunch(ProcessInfo.processInfo.arguments)
    }

    private func begin(_ description: String) -> Bool {
        guard !testLaunchBlocked else {
            errorMessage = t("測試與效能量測模式不會讀取或變更真實啟動項目。", "Test and benchmark launches do not inspect or change real startup items.")
            return false
        }
        guard !isBusy else { return false }
        guard externalOperationInProgress?() != true else {
            errorMessage = t("其他作業仍在執行，請完成或停止後再試。", "Another operation is active. Finish or stop it first.")
            return false
        }
        isBusy = true; cancelled = false; progress = 0; statusMessage = description; errorMessage = nil
        return true
    }

    private func finish() { isBusy = false; inventoryTask = nil; activeProcess = nil }
    private func checkCancellation() throws { if cancelled || Task.isCancelled { throw CancellationError() } }

    func cancel() {
        cancelled = true; pendingPlan = nil
        inventoryTask?.cancel(); activeProcess?.cancel()
    }

    func cleanupForQuit() { cancel() }

    func refresh() async {
        guard begin(t("讀取啟動項目中繼資料…", "Reading startup metadata…")) else { return }
        defer { finish() }
        pendingPlan = nil
        do {
            let inventory = await readInventory()
            try checkCancellation()
            warnings = inventory.warnings
            if inventory.truncated { warnings.append(t("已達掃描安全上限，清單可能不完整。", "The bounded inventory limit was reached; the list may be incomplete.")) }
            rows = inventory.items.map { .init(item: $0, override: nil, loadState: .unknown("Not queried"), duplicateLabel: false) }
            markDuplicateLabels()
            hasLoaded = true
            if mockRunner == nil { await readBackgroundItems() }
            try checkCancellation()
            var maps: [String: [String: StartupOverride]] = [:]
            for domain in Set(rows.map { domain(for: $0.item.scope) }).sorted() {
                do { maps[domain] = try await readOverrides(domain: domain) }
                catch is CancellationError { throw CancellationError() }
                catch { warnings.append(t("無法確認啟動覆寫狀態：", "Could not verify startup overrides: ") + domain + " · " + error.localizedDescription) }
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            // Own-user agents first; no background polling continues after this
            // bounded read. Any other row can be inspected explicitly on demand.
            let indices = rows.indices.sorted { rows[$0].item.scope == .userAgent && rows[$1].item.scope != .userAgent }
            for (offset, index) in indices.enumerated() {
                try checkCancellation()
                progress = Double(offset) / Double(max(1, indices.count))
                guard let snapshot = rows[index].item.snapshot, let label = snapshot.label,
                      StartupCommandPlan.isSafeLabel(label), let map = maps[domain(for: snapshot.scope)] else { continue }
                rows[index].override = map[label] ?? .absent
                if offset >= 160 || ContinuousClock.now >= deadline {
                    rows[index].loadState = .unknown(t("本次狀態查詢已達上限；可單獨重新檢查。", "Refresh query limit reached; inspect this row separately."))
                    continue
                }
                do { rows[index].loadState = try await readLoadState(snapshot) }
                catch is CancellationError { throw CancellationError() }
                catch { rows[index].loadState = .unknown(error.localizedDescription) }
            }
            progress = 1
            statusMessage = backgroundReadAt != nil
                ? t("已讀取登入項目、背景 App 與服務。點右側詳細資訊可查看來源與設定。", "Login items, background apps and services loaded. Use Details to inspect their source and settings.")
                : t("已讀取 ", "Read ") + String(rows.count) + t(" 個背景服務；登入項目與背景 App 尚未完成讀取。", " background services; login items and background apps have not been read.")
        } catch is CancellationError {
            statusMessage = t("已取消；已顯示的項目可能只是部分結果。", "Cancelled; displayed rows may be partial results.")
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshBackgroundItems() async {
        guard begin(t("讀取完整登入與背景清單…", "Reading login and background items…")) else { return }
        defer { finish() }
        await readBackgroundItems()
    }

    private func readBackgroundItems() async {
        guard !testLaunchBlocked, mockRunner == nil else { return }
        let process = ManagedProcess()
        activeProcess = process
        defer { activeProcess = nil }
        do {
            try process.start(request: .init(executable: URL(fileURLWithPath: "/usr/bin/sfltool"), arguments: ["dumpbtm"],
                environment: ["LC_ALL": "C", "LANG": "C"], timeout: 8, outputLimit: 2 * 1024 * 1024))
            let result = await process.wait()
            try checkCancellation()
            guard result.exitCode == 0, !result.timedOut, !result.outputTruncated else { throw StartupContractError.unverifiableState }
            let items = try BackgroundStartupParser.parse(String(decoding: result.stdout, as: UTF8.self), userID: userID)
            backgroundItems = items; backgroundReadAt = Date(); backgroundIsImported = false; backgroundReadError = nil
        } catch {
            backgroundReadError = (backgroundReadAt != nil ? t("目前保留上次清單。", "Keeping the previous report. ") : "") + t("macOS 尚未提供完整清單。目前仍可查看背景服務；登入項目與背景 App 可在系統設定查看，或從更多選項匯入系統清單。", "macOS has not provided the complete list. Background services remain available. View login and background apps in System Settings, or import a system report under More Options.")
        }
    }

    func importBackgroundItems() {
        guard !testLaunchBlocked, !isBusy, externalOperationInProgress?() != true else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = t("選擇 macOS sfltool dumpbtm 產生的清單；只讀取，不會變更設定。", "Choose a report produced by macOS sfltool dumpbtm. It is read only; no settings are changed.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey])
            guard values.isRegularFile == true, let size = values.fileSize, size <= 2 * 1024 * 1024 else { throw StartupContractError.invalidOutput }
            let items = try BackgroundStartupParser.parse(String(contentsOf: url, encoding: .utf8), userID: userID)
            backgroundItems = items; backgroundReadAt = values.contentModificationDate ?? Date(); backgroundIsImported = true; backgroundReadError = nil
            statusMessage = t("已匯入系統清單；啟用狀態以清單產生時間為準。", "System report imported. Its enabled states reflect the report's creation time.")
        } catch { errorMessage = t("無法讀取這份系統清單，請確認是 sfltool dumpbtm 的完整輸出。", "This report could not be read. Use complete sfltool dumpbtm output.") }
    }

    func backgroundItem(matching row: StartupRow) -> BackgroundStartupItem? {
        let candidates = backgroundItems.filter { $0.matchesPlist(url: row.item.url, label: row.item.snapshot?.label, scope: row.item.scope) }
        return candidates.first { $0.url?.standardizedFileURL == row.item.url.standardizedFileURL } ?? (candidates.count == 1 ? candidates[0] : nil)
    }

    func plistRow(matching item: BackgroundStartupItem) -> StartupRow? {
        let candidates = rows.filter { item.matchesPlist(url: $0.item.url, label: $0.item.snapshot?.label, scope: $0.item.scope) }
        return candidates.first { $0.item.url.standardizedFileURL == item.url?.standardizedFileURL } ?? (candidates.count == 1 ? candidates[0] : nil)
    }

    func inspectState(id: String) async {
        guard begin(t("重新檢查項目…", "Rechecking item…")) else { return }
        defer { finish() }
        do {
            guard let index = rows.firstIndex(where: { $0.id == id }), let previous = rows[index].item.snapshot else { throw StartupContractError.unsafeTarget }
            let fresh = try await revalidate(previous)
            let map = try await readOverrides(domain: domain(for: fresh.scope))
            let state = try await readLoadState(fresh)
            rows[index].override = fresh.label.flatMap { map[$0] } ?? .absent
            rows[index].loadState = state
            statusMessage = t("已讀回此項目的目前狀態。", "Current state was read back for this item.")
        } catch {
            invalidateRow(id, reason: error.localizedDescription)
            if error is CancellationError { statusMessage = t("已取消。", "Cancelled.") }
            else { errorMessage = error.localizedDescription }
        }
    }

    func canReview(_ row: StartupRow) -> Bool {
        !testLaunchBlocked && row.item.snapshot?.canManageMetadata == true && !row.duplicateLabel && row.override != nil && row.loadState.isVerified && userID > 0
    }

    /// Produces a fresh, concrete plan. This method executes only read commands.
    func prepareChange(id: String, enable: Bool) async {
        guard begin(t("檢查變更範圍…", "Reviewing change scope…")) else { return }
        defer { finish() }
        pendingPlan = nil
        do {
            guard let row = rows.first(where: { $0.id == id }), canReview(row), let expected = row.item.snapshot else { throw StartupContractError.unverifiableState }
            let snapshot = try await revalidate(expected)
            let state = try await freshState(snapshot)
            pendingPlan = try StartupCommandPlan(snapshot: snapshot, enable: enable, previousOverride: state.override,
                                                loadState: state.loaded, userID: userID, duplicateLabel: row.duplicateLabel)
            statusMessage = t("請確認此項目及即將執行的動作。", "Review this item and the actions before confirming.")
        } catch {
            invalidateRow(id, reason: error.localizedDescription)
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }

    /// Only an explicit confirmation in the view calls this method. Every argv
    /// comes from StartupCommandPlan, never from output or an arbitrary field.
    func applyPendingChange() async {
        guard let plan = pendingPlan, begin(t("套用已確認的啟動設定…", "Applying confirmed startup setting…")) else { return }
        pendingPlan = nil
        defer { finish() }
        var completed = 0
        do {
            guard userID == getuid(), geteuid() == getuid(), userID > 0 else { throw StartupContractError.unsafeTarget }
            let inventory = await readInventory()
            try checkCancellation()
            // Unreadable metadata could hide a duplicate label in this GUI
            // domain. Do not infer uniqueness from an incomplete inventory.
            guard !inventory.truncated, inventory.warnings.isEmpty,
                  !inventory.items.contains(where: { $0.scope != .systemDaemon && $0.snapshot == nil }),
                  let target = inventory.items.first(where: { $0.id == plan.snapshot.url.path })?.snapshot,
                  target == plan.snapshot else { throw StartupInspectionError.changed }
            let sameLabel = inventory.items.compactMap(\.snapshot).filter {
                $0.scope != .systemDaemon && $0.label == target.label
            }
            guard sameLabel.count == 1 else { throw StartupContractError.unsafeTarget }
            let fresh = try await freshState(target)
            guard plan.matchesFreshState(override: fresh.override, loadState: fresh.loaded) else { throw StartupInspectionError.changed }
            for (step, arguments) in plan.commands.enumerated() {
                try checkCancellation()
                _ = try await revalidate(plan.snapshot)
                if step > 0 {
                    let preceding = try await freshState(plan.snapshot)
                    guard preceding.override == (plan.enable ? .enabled : .disabled),
                          plan.matchesFreshState(override: plan.previousOverride, loadState: preceding.loaded) else {
                        throw StartupInspectionError.changed
                    }
                }
                let result = try await execute(arguments, mutation: true)
                guard result.exitCode == 0 else {
                    throw NSError(domain: "MoPanel.Startup", code: Int(result.exitCode), userInfo: [NSLocalizedDescriptionKey:
                        t("launchctl 未完成步驟 ", "launchctl did not complete step ") + (arguments.first ?? "") + " (\(result.exitCode)). " + boundedError(result.stderr)])
                }
                completed += 1; progress = Double(completed) / Double(plan.commands.count)
            }
            let final = try await freshState(plan.snapshot)
            let desired: StartupOverride = plan.enable ? .enabled : .disabled
            guard final.override == desired, final.loaded.isLoaded == plan.enable else { throw StartupContractError.unverifiableState }
            if case .loaded(let service) = final.loaded {
                guard service.path == plan.snapshot.url.path, service.program == plan.snapshot.executable else { throw StartupContractError.mismatchedService }
            }
            if let index = rows.firstIndex(where: { $0.id == plan.snapshot.url.path }) {
                rows[index].override = final.override; rows[index].loadState = final.loaded
            }
            statusMessage = plan.enable
                ? t("已讀回：啟動覆寫為啟用，項目已載入。是否執行取決於該項目的觸發條件。", "Verified: enabled override and service loaded. Execution depends on the job's triggers.")
                : t("已讀回：啟動覆寫為停用，項目未載入。", "Verified: disabled override and service not loaded.")
        } catch {
            let detail = t("已完成 ", "Completed ") + String(completed) + t(" 個步驟。設定可能已部分變更；請重新整理確認，MoPanel 不會擅自還原或強制結束服務。", " steps. Settings may have changed partially; refresh to verify. MoPanel does not silently roll back or force-kill services.")
            statusMessage = detail
            invalidateRow(plan.snapshot.url.path, reason: detail)
            if !(error is CancellationError) { errorMessage = error.localizedDescription + "\n" + detail }
        }
    }

    func reveal(_ row: StartupRow) {
        guard !testLaunchBlocked else { return }
        NSWorkspace.shared.activateFileViewerSelecting([row.item.url])
    }
    func openLoginItemsSettings() {
        guard !testLaunchBlocked else { return }
        SMAppService.openSystemSettingsLoginItems()
        statusMessage = t("已要求開啟系統設定。由你在「登入項目與延伸功能」管理；MoPanel 不會把開啟頁面當成已變更設定。", "Requested System Settings. Manage Login Items & Extensions there; opening the pane is not reported as a completed change.")
    }

    private func markDuplicateLabels() {
        let counts = Dictionary(grouping: rows.filter { $0.item.scope != .systemDaemon && $0.item.snapshot?.label != nil }, by: { $0.item.snapshot!.label! }).mapValues(\.count)
        for index in rows.indices { rows[index].duplicateLabel = (rows[index].item.snapshot?.label.flatMap { counts[$0] } ?? 0) > 1 }
    }

    private func invalidateRow(_ id: String, reason: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].override = nil; rows[index].loadState = .unknown(reason)
    }

    private func domain(for scope: StartupScope) -> String { scope == .systemDaemon ? "system" : "gui/\(userID)" }

    private func readInventory() async -> StartupInventory {
        let roots = folders, uid = userID
        let task = Task.detached(priority: .utility) { StartupInventoryReader.inventory(folders: roots, userID: uid) }
        inventoryTask = task
        let result = await task.value
        inventoryTask = nil
        return result
    }

    private func revalidate(_ snapshot: StartupPlistSnapshot) async throws -> StartupPlistSnapshot {
        let uid = userID
        let value = try await Task.detached(priority: .utility) { try StartupInventoryReader.revalidate(snapshot, userID: uid) }.value
        try checkCancellation(); return value
    }

    private func readOverrides(domain: String) async throws -> [String: StartupOverride] {
        let result = try await execute(["print-disabled", domain])
        guard result.exitCode == 0, result.stderr.isEmpty else { throw StartupContractError.invalidOutput }
        return try LaunchctlOutputParser.disabledOverrides(result.stdout)
    }

    private func readLoadState(_ snapshot: StartupPlistSnapshot) async throws -> StartupLoadState {
        guard let label = snapshot.label, StartupCommandPlan.isSafeLabel(label) else { throw StartupContractError.unsafeTarget }
        let domain = domain(for: snapshot.scope)
        let result = try await execute(["print", domain + "/" + label])
        return try LaunchctlOutputParser.service(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode, domain: domain, label: label)
    }

    private func freshState(_ snapshot: StartupPlistSnapshot) async throws -> (override: StartupOverride, loaded: StartupLoadState) {
        let map = try await readOverrides(domain: domain(for: snapshot.scope))
        let loaded = try await readLoadState(snapshot)
        return (snapshot.label.flatMap { map[$0] } ?? .absent, loaded)
    }

    private func execute(_ arguments: [String], mutation: Bool = false) async throws -> StartupCommandResult {
        guard !testLaunchBlocked else { throw StartupContractError.unsafeTarget }
        try checkCancellation()
        if let mockRunner { return try await mockRunner(arguments) }
        let process = ManagedProcess()
        activeProcess = process
        defer { activeProcess = nil }
        try process.start(request: .init(executable: URL(fileURLWithPath: "/bin/launchctl"), arguments: arguments,
                                        environment: ["LC_ALL": "C", "LANG": "C"], timeout: mutation ? 20 : 3,
                                        outputLimit: arguments.first == "print-disabled" ? 256 * 1_024 : 128 * 1_024))
        let result = await process.wait()
        try checkCancellation()
        guard !result.timedOut, !result.outputTruncated, !result.cancelled else { throw StartupContractError.unverifiableState }
        return .init(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
    }

    private func boundedError(_ data: Data) -> String {
        // launchctl print output may contain environment secrets. It is never
        // logged or shown. Mutation stderr is bounded and stripped of controls.
        String(decoding: data.prefix(1_024), as: UTF8.self).unicodeScalars.filter { $0.value >= 32 && $0.value != 127 }.map(String.init).joined()
    }

    /// Safe UI/adapter smoke: only temporary metadata and an in-memory launchctl
    /// substitute. No live service, override, login item or daemon is changed.
    static func runSafeSmokeTest() async -> StartupSmokeReport {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MoPanelStartupSmoke-" + UUID().uuidString)
        var errors: [String] = []
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? manager.removeItem(at: folder) }
            let uid = getuid()
            guard uid > 0 else { throw StartupContractError.unsafeTarget }
            let label = "org.mopanel.fixture.startup"
            let url = folder.appendingPathComponent(label + ".plist")
            let data = try PropertyListSerialization.data(fromPropertyList: ["Label": label, "ProgramArguments": ["/usr/bin/true"], "RunAtLoad": false], format: .xml, options: 0)
            try data.write(to: url); try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let state = StartupMockState(label: label, path: url.path, uid: uid)
            let controller = StartupController(language: "en", folders: [.init(url: folder, scope: .userAgent)], userID: uid) { arguments in state.run(arguments) }
            await controller.refresh()
            let inventoryCount = controller.rows.count
            await controller.prepareChange(id: url.path, enable: true)
            if controller.pendingPlan == nil { errors.append(controller.errorMessage ?? "No enable plan") }
            await controller.applyPendingChange()
            let enabled = state.loaded && state.override == .enabled && controller.rows.first?.loadState.isLoaded == true
            await controller.prepareChange(id: url.path, enable: false)
            await controller.applyPendingChange()
            let disabled = !state.loaded && state.override == .disabled && controller.rows.first?.loadState == .notLoaded
            await controller.prepareChange(id: url.path, enable: true)
            let count = state.mutations.count
            controller.cancel()
            await controller.applyPendingChange()
            let cancelledSafely = state.mutations.count == count
            state.invalidFormat = true
            await controller.refresh()
            await controller.prepareChange(id: url.path, enable: true)
            await controller.applyPendingChange()
            let unknownSafe = controller.pendingPlan == nil && state.mutations.count == count
            controller.cleanupForQuit()
            if !enabled { errors.append("Mock enable read-back failed") }
            if !disabled { errors.append("Mock disable read-back failed") }
            if !cancelledSafely { errors.append("Cancelled review mutated state") }
            if !unknownSafe { errors.append("Unknown format permitted mutation") }
            return .init(inventoryCount: inventoryCount, enableVerifiedWithMock: enabled, disableVerifiedWithMock: disabled,
                         cancelledReviewDidNotMutate: cancelledSafely, unknownFormatDidNotMutate: unknownSafe,
                         mutationArguments: state.mutations, realLaunchctlMutations: 0, persistentJobsCreated: 0, errors: errors)
        } catch { errors.append(error.localizedDescription) }
        return .init(inventoryCount: 0, enableVerifiedWithMock: false, disableVerifiedWithMock: false,
                     cancelledReviewDidNotMutate: false, unknownFormatDidNotMutate: false, mutationArguments: [],
                     realLaunchctlMutations: 0, persistentJobsCreated: 0, errors: errors)
    }
}

@MainActor private final class StartupMockState {
    let label: String, path: String
    let uid: UInt32
    var loaded = false
    var override = StartupOverride.absent
    var invalidFormat = false
    var mutations: [[String]] = []
    init(label: String, path: String, uid: UInt32) { self.label = label; self.path = path; self.uid = uid }
    func run(_ args: [String]) -> StartupCommandResult {
        func result(_ stdout: String = "", _ stderr: String = "", _ code: Int32 = 0) -> StartupCommandResult { .init(stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), exitCode: code) }
        let target = "gui/\(uid)/\(label)"
        if args == ["print-disabled", "gui/\(uid)"] {
            if invalidFormat { return result("unexpected future format") }
            return result("disabled services = {\n" + (override == .absent ? "" : "\t\"\(label)\" => \(override == .disabled ? "true" : "false")\n") + "}\n")
        }
        if args == ["print", target] {
            if !loaded { return result("", "Could not find service \"\(label)\" in domain for user gui: \(uid)\n", 113) }
            return result("\(target) = {\n\tpath = \(path)\n\tprogram = /usr/bin/true\n\tstate = not running\n}\n")
        }
        if args == ["enable", target] { override = .enabled }
        else if args == ["disable", target] { override = .disabled }
        else if args == ["bootstrap", "gui/\(uid)", path] { loaded = true }
        else if args == ["bootout", target] { loaded = false }
        else { return result("", "Unexpected fixture arguments", 64) }
        mutations.append(args); return result()
    }
}
