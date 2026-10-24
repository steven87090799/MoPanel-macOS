import SwiftUI
import AppKit
import MoPanelCore
import MoPanelProcess

@MainActor final class AppModel: ObservableObject {
    @Published var section: AppSection = .dashboard {
        didSet {
            if isTestLaunch { if section != .dashboard { stopMonitoring() } }
            else { updateMonitoringDemand() }
        }
    }
    @Published var language: String { didSet { if !isTestLaunch { UserDefaults.standard.set(language, forKey: "language") } } }
    @Published var appearance: String { didSet { if !isTestLaunch { UserDefaults.standard.set(appearance, forKey: "appearance") } } }
    @Published var customPath: String { didSet { if !isTestLaunch { UserDefaults.standard.set(customPath, forKey: "cliPath") } } }
    @Published var monitoringInterval = 2 { didSet { if oldValue != monitoringInterval { monitoringPreferencesChanged() } } }
    @Published var menuBarMonitoringInterval = 5 { didSet { if oldValue != menuBarMonitoringInterval { monitoringPreferencesChanged() } } }
    @Published var menuBarEnabled = false {
        didSet {
            if !isTestLaunch { UserDefaults.standard.set(menuBarEnabled, forKey: "menuBarEnabled"); updateMonitoringDemand() }
        }
    }
    @Published private(set) var monitoringPaused = false
    @Published var processAlertsEnabled = true { didSet { if oldValue != processAlertsEnabled { monitoringPreferencesChanged() } } }
    @Published var processCPUThreshold = 100.0 { didSet { if oldValue != processCPUThreshold { monitoringPreferencesChanged() } } }
    @Published var processCPUWindow = 300 { didSet { if oldValue != processCPUWindow { monitoringPreferencesChanged() } } }
    @Published private(set) var systemSleeping = false
    @Published private(set) var lowPowerMode = false
    @Published var installation: CLIInstallation?
    @Published var release: ReleaseInfo?
    @Published var releaseError: String?
    @Published var isDetecting = false
    @Published var busy: String?
    @Published private(set) var activeScanCommand: MoleCommand?
    @Published var error: String?
    @Published var status: StatusSnapshot?
    @Published var trends: [TrendSample] = []
    @Published var monitoring = false
    @Published var monitorWarnings = ""
    @Published var selectedNetwork = "" {
        didSet { if !isTestLaunch, oldValue != selectedNetwork { UserDefaults.standard.set(selectedNetwork, forKey: "selectedNetwork") } }
    }
    @Published var apps: [InstalledApp] = []
    @Published var analysis: AnalyzeSnapshot?
    @Published var history: HistorySnapshot?
    @Published var rawResult = ""
    @Published var activities: [ActivityEntry] = []
    @Published var pending: PendingOperation?
    @Published var showOperation = false
    @Published var operationTitle = ""
    @Published var operationCommand = ""
    @Published var operationDetailsExpanded = false
    @Published private(set) var operationKind: MoleCommand?
    @Published var operationSession = ManagedProcess()
    @Published var operationResult: ProcessResult?
    @Published var operationIsInteractive = true
    @Published var operationWasPreview = false
    @Published var windowActive = true { didSet { if !isTestLaunch { updateMonitoringDemand() } } }
    @Published var homebrewConfirmation = false
    /// Queried synchronously by action guards, so a native operation cannot race
    /// the next SwiftUI redraw. The app root excludes this model from callbacks.
    var nativeOperationInProgress: (() -> Bool)?
    private var scanSession: ManagedProcess?
    private var watchSession: ManagedProcess?
    private var operationTask: Task<Void, Never>?
    private var scanCancellationRequested = false
    private var monitorRestartRequested = false
    private var runningWatchOptions: MonitoringWatchOptions?
    private let workspaceCenter = NSWorkspace.shared.notificationCenter
    private var workspaceObservers: [NSObjectProtocol] = []
    private var powerObserver: NSObjectProtocol?
    private var shuttingDown = false
    private var validatedFingerprint: String?
    private var watchFramer = NDJSONFramer()
    private var invalidJSON = Set<MoleCommand>()
    let fixtureMode: Bool
    let isTestLaunch: Bool
    let readOnlyBenchmarkRequested: Bool
    let benchmarkConfiguration: ReadOnlyBenchmark?
    let testLaunchError: String?
    private let fixtureURL: URL?

    init() {
        language = UserDefaults.standard.string(forKey: "language") ?? "zh-Hant"
        appearance = UserDefaults.standard.string(forKey: "appearance") ?? "system"
        customPath = UserDefaults.standard.string(forKey: "cliPath") ?? ""
        let arguments = ProcessInfo.processInfo.arguments
        fixtureMode = arguments.contains("--smoke-test") || arguments.contains("--benchmark")
        isTestLaunch = ReadOnlyBenchmark.isTestLaunch(arguments)
        readOnlyBenchmarkRequested = ReadOnlyBenchmark.isRequested(arguments)
        var benchmark: ReadOnlyBenchmark?
        var launchError: String?
        if readOnlyBenchmarkRequested {
            do { benchmark = try ReadOnlyBenchmark.load(arguments: arguments, environment: ProcessInfo.processInfo.environment) }
            catch { launchError = error.localizedDescription }
        } else if isTestLaunch {
            let flags = Array(arguments.dropFirst())
            let validSmoke = flags == ["--smoke-test"]
            let validFixtureBenchmark = flags.count == 2 && flags[0] == "--benchmark" && ["idle", "monitor", "scan"].contains(flags[1])
            if !validSmoke && !validFixtureBenchmark { launchError = "Invalid or mixed test-launch flags; no real CLI will be selected." }
        }
        benchmarkConfiguration = benchmark
        testLaunchError = launchError
        fixtureURL = fixtureMode ? AppResources.bundle?.url(forResource: "mock-mo", withExtension: "sh", subdirectory: "Fixtures") : nil
        menuBarEnabled = !isTestLaunch && UserDefaults.standard.bool(forKey: "menuBarEnabled")
        if !isTestLaunch {
            let saved = MonitoringPreferences(defaults: .standard)
            monitoringInterval = saved.interval
            menuBarMonitoringInterval = saved.menuBarInterval
            processAlertsEnabled = saved.processAlerts
            processCPUThreshold = saved.processCPUThreshold
            processCPUWindow = saved.processCPUWindow
            selectedNetwork = UserDefaults.standard.string(forKey: "selectedNetwork") ?? ""
            lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            installMonitoringObservers()
        }
    }

    deinit {
        for observer in workspaceObservers { workspaceCenter.removeObserver(observer) }
        if let powerObserver { NotificationCenter.default.removeObserver(powerObserver) }
    }

    private var monitoringPreferences: MonitoringPreferences {
        MonitoringPreferences(interval: monitoringInterval, menuBarInterval: menuBarMonitoringInterval,
                              processAlerts: processAlertsEnabled, processCPUThreshold: processCPUThreshold,
                              processCPUWindow: processCPUWindow)
    }

    private var requestedWatchOptions: MonitoringWatchOptions {
        monitoringPreferences.watchOptions(dashboardVisible: section == .dashboard && windowActive, lowPowerMode: lowPowerMode)
    }

    private func monitoringPreferencesChanged() {
        guard !isTestLaunch else { return }
        monitoringPreferences.save(to: .standard)
        updateMonitoringDemand()
    }

    private func installMonitoringObservers() {
        workspaceObservers.append(workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.systemSleeping = true
                self?.updateMonitoringDemand()
            }
        })
        workspaceObservers.append(workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.systemSleeping = false
                self?.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
                self?.updateMonitoringDemand()
            }
        })
        powerObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
                self?.updateMonitoringDemand()
            }
        }
    }

    func t(_ zh: String, _ en: String) -> String { language == "en" ? en : zh }
    var colorScheme: ColorScheme? { appearance == "dark" ? .dark : appearance == "light" ? .light : nil }
    var unavailable: String { t("不支援或尚未提供", "Unsupported or unavailable") }
    var scanActivityTitle: String {
        switch activeScanCommand {
        case .analyze: return t("正在分析磁碟", "Analyzing disk")
        case .uninstall: return t("正在讀取 App 清單", "Reading app inventory")
        case .status: return t("正在取得系統狀態", "Reading system status")
        case .history: return t("正在讀取操作歷史", "Reading operation history")
        default: return t("正在準備作業", "Preparing operation")
        }
    }
    var canStart: Bool { installation != nil && !isDetecting && !hasRunningOperation && !shuttingDown }
    var moleOperationInProgress: Bool { busy != nil || scanSession?.running == true || operationSession.running || operationTask != nil }
    var hasRunningOperation: Bool { moleOperationInProgress || nativeOperationInProgress?() == true }
    var monitoringNeeded: Bool {
        MonitoringDemand.isNeeded(dashboardSelected: section == .dashboard, windowActive: windowActive,
                                  menuBarEnabled: menuBarEnabled, paused: monitoringPaused, shuttingDown: shuttingDown,
                                  systemSleeping: systemSleeping)
    }
    private var processEnvironment: [String: String] { benchmarkConfiguration?.childEnvironment(from: CLIProbe.environment) ?? CLIProbe.environment }
    var canRecoverStable: Bool {
        installation?.source == .script && installation?.resourceLocation != nil &&
        installation?.incompatible[.update] == nil && installation?.compatibility.stableScriptRecoveryAvailable == true
    }

    func detect() async {
        guard !isDetecting, !hasRunningOperation, !shuttingDown else { return }
        isDetecting = true
        error = nil
        defer {
            isDetecting = false
            if !isTestLaunch, installation != nil, monitoringNeeded { startMonitoring() }
        }
        do {
            // A test launch must never fall through to a real installed engine.
            if let testLaunchError { throw MoleError.incompatible(testLaunchError) }
            if fixtureMode, fixtureURL == nil { throw MoleError.incompatible("Bundled test fixture is missing; no real CLI will be probed.") }
            await stopMonitoringAndWait()
            try Task.checkCancellation()
            guard !shuttingDown else { throw CancellationError() }
            let detected: CLIInstallation?
            if readOnlyBenchmarkRequested {
                guard let benchmark = benchmarkConfiguration else { throw MoleError.incompatible("Read-only benchmark configuration is missing; no fallback CLI is permitted.") }
                try CLIProbe.verifyBenchmarkLauncher(benchmark)
                let inspected = try await CLIProbe.inspect(benchmark.cli, fixture: false, childEnvironment: processEnvironment, workingDirectory: benchmark.home)
                guard inspected.version == MoleVersion(string: benchmark.sourceTag)?.description else { throw MoleError.incompatible("Benchmark CLI version does not match its verified CI source record.") }
                detected = inspected
            } else {
                detected = try await CLIProbe.detect(custom: fixtureMode ? "" : customPath, fixture: fixtureURL)
            }
            try Task.checkCancellation()
            guard !shuttingDown else { throw CancellationError() }
            if detected?.fingerprint != validatedFingerprint {
                invalidJSON.removeAll()
                status = nil; trends.removeAll(); apps.removeAll(); analysis = nil; history = nil
            }
            installation = detected
            validatedFingerprint = detected?.fingerprint
            pending = nil
        } catch { installation = nil; self.error = error.localizedDescription }
        if !isTestLaunch, !shuttingDown, !Task.isCancelled { await checkRelease() }
    }

    func checkRelease() async {
        guard !isTestLaunch else { return }
        do { release = try await CLIProbe.latestRelease(); releaseError = nil }
        catch { releaseError = error.localizedDescription }
    }

    private func validatedInstallation(for invocation: MoleInvocation) throws -> CLIInstallation {
        if let testLaunchError { throw MoleError.incompatible(testLaunchError) }
        if readOnlyBenchmarkRequested {
            guard let benchmark = benchmarkConfiguration else { throw MoleError.incompatible("Read-only benchmark configuration is missing.") }
            try benchmark.validate(invocation)
            guard installation?.executable.path == benchmark.cli.path else { throw MoleError.incompatible("Benchmark executable changed; no fallback is permitted.") }
        }
        guard let cli = installation else { throw MoleError.incompatible(t("尚未找到 Mole CLI。", "Mole CLI is not installed.")) }
        guard try CLIProbe.fingerprint(cli.executable) == cli.fingerprint else {
            throw MoleError.incompatible(t("Mole 已更新或路徑已變更。請重新偵測後再操作。", "Mole has changed. Re-detect its version and capabilities before continuing."))
        }
        let updateSource: StableUpdateSource = cli.source == .script ? .officialScript : cli.source == .homebrew ? .homebrew : .unverified
        try cli.compatibility.validate(invocation, updateSource: updateSource)
        if let reason = cli.incompatible[invocation.command], !invocation.arguments.contains("--help") { throw MoleError.incompatible(reason) }
        if invocation.isDestructive, cli.source != .fixture, cli.resourceLocation == nil {
            throw MoleError.incompatible(t("無法確認這個啟動程式使用的 Mole 資源。請選取實際的官方 mo／mole 執行檔後重新偵測。", "Mole's resource location could not be verified. Select the actual official mo/mole launcher and re-detect before changing files or settings."))
        }
        if invocation.isDestructive && (invalidJSON.contains(invocation.command) || (invocation.command == .menu && !invalidJSON.isEmpty)) {
            throw MoleError.incompatible(t("這個指令的 JSON 格式不相容，相關變更操作已暫停。", "JSON compatibility failed; changes through this command are blocked."))
        }
        if invocation.arguments.contains("--nightly"), cli.source != .script {
            throw MoleError.incompatible(t("Nightly 僅開放給已確認的官方指令碼安裝。", "Nightly updates require a verified official script installation."))
        }
        return cli
    }

    private func capture(_ invocation: MoleInvocation, timeout: TimeInterval = 300) async throws -> Data {
        guard !hasRunningOperation, !isDetecting, !shuttingDown else { throw MoleError.invalidArgument(t("請先完成或停止目前的作業。", "Finish or stop the current operation first.")) }
        let session = ManagedProcess()
        scanSession = session
        scanCancellationRequested = false
        busy = invocation.displayCommand
        activeScanCommand = invocation.command
        error = nil
        defer {
            if scanSession === session {
                scanSession = nil; busy = nil; activeScanCommand = nil
                if !isTestLaunch { updateMonitoringDemand() }
            }
        }
        await stopMonitoringAndWait()
        try Task.checkCancellation()
        guard !scanCancellationRequested, !shuttingDown else { throw MoleError.invalidOutput(t("作業已取消。", "Operation cancelled.")) }
        // The engine may have changed while the previous collector was exiting.
        let cli = try validatedInstallation(for: invocation)
        try session.start(request: ProcessRequest(executable: cli.executable, arguments: invocation.arguments, environment: processEnvironment, workingDirectory: benchmarkConfiguration?.home, timeout: readOnlyBenchmarkRequested ? min(timeout, 30) : timeout, outputLimit: 32 * 1024 * 1024))
        let result = await withTaskCancellationHandler(operation: { await session.wait() }, onCancel: { Task { @MainActor in session.cancel() } })
        rawResult = TerminalText.plain(result.stdoutText + "\n" + result.stderrText)
        if rawResult.utf8.count > 2 * 1024 * 1024 { rawResult = String(rawResult.suffix(500_000)) }
        record(invocation.displayCommand, result: result)
        guard !Task.isCancelled, !scanCancellationRequested, !shuttingDown else { throw MoleError.invalidOutput(t("作業已取消。", "Operation cancelled.")) }
        if result.outputTruncated { throw MoleError.invalidOutput(t("CLI 輸出超過安全記憶體上限，作業已停止；未使用不完整結果。", "CLI output exceeded the safe memory limit. The operation was stopped and incomplete results were discarded.")) }
        guard result.succeeded else { throw MoleError.invalidOutput(result.cancelled ? t("作業已取消。", "Operation cancelled.") : result.timedOut ? t("作業已逾時並停止。", "Operation timed out and was stopped.") : "Exit \(result.exitCode)\n" + result.stderrText) }
        return result.stdout
    }

    func loadApps() async {
        apps.removeAll()
        do {
            let data = try await capture(MoleInvocation.make(command: .uninstall, options: [.uninstallList]), timeout: 600)
            do { apps = try MoleJSON.decodeApps(data); invalidJSON.remove(.uninstall) }
            catch { invalidJSON.insert(.uninstall); throw error }
        } catch { self.error = error.localizedDescription }
    }

    func analyze(path: String?) async {
        analysis = nil
        do {
            let options: [MoleOption] = path.map { [.json, .analyzePath($0)] } ?? [.json]
            let data = try await capture(MoleInvocation.make(command: .analyze, options: options), timeout: 1800)
            do { analysis = try MoleJSON.decodeAnalyze(data); invalidJSON.remove(.analyze) }
            catch { invalidJSON.insert(.analyze); throw error }
        } catch { self.error = error.localizedDescription }
    }

    func loadHistory(limit: Int = 50) async {
        history = nil
        do {
            let data = try await capture(MoleInvocation.make(command: .history, options: [.json, .historyLimit(limit)]))
            do { history = try MoleJSON.decodeHistory(data); invalidJSON.remove(.history) }
            catch { invalidJSON.insert(.history); throw error }
        } catch { self.error = error.localizedDescription }
    }

    func takeSnapshot() async {
        status = nil
        do {
            let invocation: MoleInvocation
            if let benchmark = benchmarkConfiguration { invocation = try benchmark.snapshot }
            else { invocation = try MoleInvocation.make(command: .status, options: [.json]) }
            let data = try await capture(invocation)
            do { acceptStatus(try MoleJSON.decodeStatus(data)); invalidJSON.remove(.status) }
            catch { invalidJSON.insert(.status); throw error }
        } catch { self.error = error.localizedDescription }
    }

    func startMonitoring() {
        guard monitoringNeeded, !hasRunningOperation, !isDetecting, !shuttingDown else { return }
        let watchOptions = requestedWatchOptions
        if watchSession != nil {
            // Cancel is asynchronous. A new collector can begin only after the
            // guardian has reaped the old process and both pipes reached EOF.
            if !monitoring || runningWatchOptions != watchOptions {
                monitorRestartRequested = true
                monitoring = false
                watchSession?.cancel()
            }
            return
        }
        do {
            let invocation: MoleInvocation
            if let benchmark = benchmarkConfiguration { invocation = try benchmark.watch }
            else { invocation = try MoleInvocation.make(command: .status, options: [.watch, .intervalSeconds(watchOptions.interval), .procCPUAlerts(watchOptions.processAlerts), .procCPUThreshold(watchOptions.processCPUThreshold), .procCPUWindowSeconds(watchOptions.processCPUWindow)]) }
            let cli = try validatedInstallation(for: invocation)
            let session = ManagedProcess()
            watchSession = session
            runningWatchOptions = watchOptions
            watchFramer = NDJSONFramer()
            monitorWarnings = ""
            session.onOutput = { [weak self, weak session] bytes in
                guard let self, let session, self.watchSession === session, self.monitoring, !self.shuttingDown else { return }
                do {
                    for line in try self.watchFramer.append(bytes) {
                        self.acceptStatus(try MoleJSON.decodeStatus(line))
                        self.invalidJSON.remove(.status)
                    }
                } catch {
                    self.invalidJSON.insert(.status)
                    self.error = self.t("監控輸出格式不相容，已停止監控：", "Monitoring stopped because its output is incompatible: ") + error.localizedDescription
                    self.stopMonitoring()
                }
            }
            session.onError = { [weak self, weak session] bytes in
                guard let self, let session, self.watchSession === session else { return }
                self.monitorWarnings = String((self.monitorWarnings + TerminalText.plain(String(decoding: bytes, as: UTF8.self))).suffix(16_384))
            }
            session.onExit = { [weak self, weak session] result in
                guard let self, let session, self.watchSession === session else { return }
                self.watchSession = nil; self.runningWatchOptions = nil; self.monitoring = false
                if !result.cancelled, !self.shuttingDown {
                    do { try self.watchFramer.finish() }
                    catch { self.error = error.localizedDescription; self.invalidJSON.insert(.status) }
                    if result.exitCode != 0 { self.error = "Status exit \(result.exitCode): " + result.stderrText }
                }
                let restart = self.monitorRestartRequested
                self.monitorRestartRequested = false
                if restart { self.startMonitoring() }
            }
            try session.start(request: ProcessRequest(executable: cli.executable, arguments: invocation.arguments, environment: processEnvironment, workingDirectory: benchmarkConfiguration?.home, timeout: 0, retainsOutput: false))
            monitoring = true
        } catch { watchSession = nil; runningWatchOptions = nil; monitoring = false; self.error = error.localizedDescription }
    }

    func stopMonitoring() {
        monitorRestartRequested = false
        monitoring = false
        watchSession?.cancel()
    }

    func pauseMonitoring() { monitoringPaused = true; stopMonitoring() }
    func resumeMonitoring() { monitoringPaused = false; startMonitoring() }
    func updateMonitoringDemand() {
        if monitoringNeeded && !hasRunningOperation { startMonitoring() }
        else { stopMonitoring() }
    }

    private func stopMonitoringAndWait() async {
        let session = watchSession
        stopMonitoring()
        if let session { _ = await session.wait() }
    }

    private func acceptStatus(_ snapshot: StatusSnapshot) {
        status = snapshot
        if !snapshot.network.isEmpty, !snapshot.network.contains(where: { $0.name == selectedNetwork }) {
            let fallback = snapshot.network.first?.name ?? ""
            if selectedNetwork != fallback { selectedNetwork = fallback }
        }
        let network = snapshot.network.first { $0.name == selectedNetwork }
        trends.append(TrendSample(date: Date(), cpu: snapshot.cpu.logicalCPU > 0 ? snapshot.cpu.usage : nil,
                                  memory: snapshot.memory.total > 0 ? snapshot.memory.usedPercent : nil,
                                  diskRead: snapshot.diskIO?.readRate, diskWrite: snapshot.diskIO?.writeRate,
                                  down: network?.rxRateMbs, up: network?.txRateMbs,
                                  gpu: snapshot.gpu.compactMap(\.usage).first { $0.isFinite && (0...100).contains($0) }))
        if trends.count > 120 { trends.removeFirst(trends.count - 120) }
    }

    func request(_ command: MoleCommand, options: [MoleOption] = [], title: String? = nil) {
        do {
            guard !hasRunningOperation, !isDetecting, !shuttingDown else { throw MoleError.invalidArgument(t("請先停止目前作業。", "Stop the current operation first.")) }
            let invocation = try MoleInvocation.make(command: command, options: options)
            _ = try validatedInstallation(for: invocation)
            let name = title ?? command.rawValue.capitalized
            showOperation = false
            if invocation.isDestructive {
                pending = PendingOperation(invocation: invocation, title: name, details: riskDescription(invocation))
            } else { launch(invocation, title: name) }
        } catch { self.error = error.localizedDescription }
    }

    func confirmPending() {
        guard let pending else { return }
        self.pending = nil
        launch(pending.invocation, title: pending.title)
    }

    private func launch(_ invocation: MoleInvocation, title: String) {
        do {
            guard !hasRunningOperation, !isDetecting, !shuttingDown else { throw MoleError.invalidArgument(t("另一個作業仍在執行。", "Another operation is still running.")) }
            _ = try validatedInstallation(for: invocation)
            prepareOperation(command: invocation.displayCommand) { [weak self] in
                guard let self else { return }
                try self.startOperation(invocation, title: title)
            }
        } catch { self.error = error.localizedDescription; showOperation = false }
    }

    private func prepareOperation(command: String, start: @escaping @MainActor () throws -> Void) {
        // Reserve the operation slot before awaiting cancellation. Buttons and
        // keyboard shortcuts cannot queue another scan or mutation meanwhile.
        busy = command
        error = nil
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.busy = nil; self.operationTask = nil
                if !self.isTestLaunch { self.updateMonitoringDemand() }
            }
            await self.stopMonitoringAndWait()
            do {
                try Task.checkCancellation()
                guard !self.shuttingDown else { throw CancellationError() }
                try start()
            } catch {
                self.error = error is CancellationError ? self.t("作業已取消。", "Operation cancelled.") : error.localizedDescription
                self.showOperation = false
            }
        }
    }

    private func startOperation(_ invocation: MoleInvocation, title: String) throws {
        let cli = try validatedInstallation(for: invocation)
        let session = ManagedProcess()
        operationSession = session
        operationTitle = title
        operationCommand = invocation.displayCommand
        operationDetailsExpanded = false
        operationKind = invocation.command
        operationResult = nil
        operationWasPreview = invocation.isPreview
        operationIsInteractive = invocation.requiresPTY
        rawResult = ""
        if !invocation.requiresPTY {
            session.onOutput = { [weak self, weak session] bytes in
                guard let self, let session, self.operationSession === session else { return }
                self.rawResult = String((self.rawResult + TerminalText.plain(String(decoding: bytes, as: UTF8.self))).suffix(500_000))
            }
        }
        session.onExit = { [weak self, weak session] result in
            guard let self, let session, self.operationSession === session else { return }
            self.operationResult = result
            self.record(invocation.displayCommand, result: result)
            if !invocation.requiresPTY { self.rawResult = String(TerminalText.plain(result.stdoutText + "\n" + result.stderrText).suffix(500_000)) }
            // Mole's own main menu can also update or remove the CLI. Never
            // keep an installation snapshot from before an interactive menu.
            if invocation.command == .update || invocation.command == .remove || invocation.command == .menu {
                self.installation = nil
                Task { await self.detect() }
            } else if !self.isTestLaunch { self.updateMonitoringDemand() }
        }
        var environment = processEnvironment
        if invocation.command == .purge && invocation.arguments.contains("--paths") {
            let editor = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MoPanelEditor")
            guard FileManager.default.isExecutableFile(atPath: editor.path) else { throw MoleError.incompatible("MoPanelEditor is missing. Reinstall the complete app bundle.") }
            environment["EDITOR"] = editor.path
            environment["MOPANEL_LANGUAGE"] = language
        }
        try session.start(request: ProcessRequest(executable: cli.executable, arguments: invocation.arguments, environment: environment, workingDirectory: benchmarkConfiguration?.home, timeout: invocation.requiresPTY ? 7200 : 1800, cooperativeCancellation: invocation.command == .slim && !invocation.isPreview), interactive: invocation.requiresPTY)
        showOperation = true
    }

    func uninstall(selected: Set<String>, preview: Bool, withData: Bool, permanent: Bool, debug: Bool = false) async {
        let previous = apps.filter { selected.contains($0.id) }
        await loadApps()
        guard error == nil else { return }
        do {
            let names = try InstalledAppSelection.validatedNames(selected: previous, inventory: apps)
            var options: [MoleOption] = [.apps(names)]
            if preview { options.append(.dryRun) }
            if withData { options.append(.withData) }
            if permanent { options.append(.permanent) }
            if debug { options.append(.debug) }
            request(.uninstall, options: options, title: t("解除安裝選取的 App", "Uninstall selected apps"))
        } catch { self.error = error.localizedDescription }
    }

    private func record(_ command: String, result: ProcessResult) {
        let outcome = result.cancelled ? t("已取消；已完成的動作不會回復", "Cancelled; completed changes are not rolled back") : result.timedOut ? t("逾時", "Timed out") : "Exit \(result.exitCode)"
        activities.insert(ActivityEntry(command: command, outcome: outcome), at: 0)
        if activities.count > 200 { activities.removeLast(activities.count - 200) }
    }

    func cancelScan() {
        scanCancellationRequested = true
        operationTask?.cancel()
        scanSession?.cancel()
    }
    func shutdown() {
        shuttingDown = true
        pending = nil
        cancelScan()
        stopMonitoring()
        operationSession.cancel()
    }

    func finishTesting() async {
        guard isTestLaunch else { return }
        let children = [scanSession, watchSession, operationSession].compactMap { $0 }
        let preparing = operationTask
        shutdown()
        for child in children { _ = await child.wait() }
        if let preparing { await preparing.value }
    }

    func riskDescription(_ invocation: MoleInvocation) -> String {
        switch invocation.command {
        case .clean:
            if invocation.arguments.contains("--whitelist") { return t("開啟官方保護清單編輯器。變更會寫入 Mole 的白名單。", "Open Mole's protection editor. Changes are saved to Mole's whitelist.") }
            if invocation.arguments.contains("--external") { return t("將永久刪除指定外接磁碟上 Mole 允許清理的系統中繼資料。由 CLI 驗證磁碟與保護規則。", "Permanently delete eligible OS metadata on the selected external volume. Mole validates the volume and protection rules.") }
            return t("Mole Clean 會永久刪除快取、日誌等資料，預設也可能清空家目錄垃圾桶。請先預覽；要保留垃圾桶，請先在官方白名單勾選 Trash。取消只停止尚未完成的步驟，不能復原已刪除資料。", "Mole Clean permanently deletes eligible caches and logs and can empty your home Trash by default. Preview first. Protect Trash in Mole's whitelist if you want to keep it. Cancellation cannot restore completed deletions.")
        case .uninstall:
            return t("最後的 App 路徑及殘留資料以官方確認畫面為準。個人資料預設保留；選擇 --with-data 才會預選部分資料。Homebrew／供應商卸載程式可能有額外影響。", "Confirm the actual app paths and related files in Mole's final review. Personal data is retained unless --with-data was selected. Homebrew or vendor uninstallers can have additional effects.") + (invocation.arguments.contains("--permanent") ? t("\n已選擇永久刪除，不經垃圾桶。", "\nPERMANENT removal is enabled; files bypass Trash.") : "")
        case .optimize: return t("將依 Mole 的條件刷新快取、服務或維護資料庫；部分項目需要管理員授權。以官方執行結果區分已執行、未變更、略過、不可用與失敗。", "Mole may refresh caches and services or maintain databases. Some steps request administrator authorization. Its output reports applied, unchanged, skipped, unavailable and failed steps.")
        case .purge:
            return invocation.arguments.contains("--paths") ? t("開啟官方專案掃描路徑編輯器。只變更 Mole 的掃描設定。", "Open Mole's project search-path editor.") : t("將永久刪除官方選定的可重建專案產物。最近使用的產物、Git 追蹤資料及保護路徑由 Mole 判斷；務必檢查最後清單。", "Permanently remove selected rebuildable artifacts. Mole checks recent use, tracked files and protected paths. Review its final list.")
        case .installer: return t("將永久刪除官方清單中選取的 DMG、PKG、ISO、XIP 或 ZIP 安裝檔，無法從垃圾桶復原。", "Permanently delete the selected DMG, PKG, ISO, XIP or ZIP installers. They cannot be restored from Trash.")
        case .slim: return t("Mole 會在副本移除 Intel 程式碼，通過官方簽章及 Gatekeeper 檢查後才替換，原 App 放入垃圾桶。不是所有 Universal App 都適合處理。停止時會等待當前替換步驟安全結束；不會在替換途中強制終止。", "Mole thins a copy, validates its signature and Gatekeeper assessment, then replaces eligible apps and moves originals to Trash. Cancellation waits for a safe replacement boundary and never force-kills an app swap.")
        case .analyze: return t("開啟 Mole 的互動分析器。可在其中選取項目移至垃圾桶；刪除前仍需官方確認。這裡不會代替你選取任何檔案。", "Open Mole's interactive analyzer. Select items there to move to Trash with its own protection checks and confirmation.")
        case .remove: return t("這會移除 MoPanel 所依賴的 Mole CLI。MoPanel 本身保留，但需重新安裝 CLI 才能使用核心功能。請輸入 REMOVE 確認。", "This removes the Mole CLI that MoPanel depends on. Reinstall the CLI to use core functions again. Type REMOVE to confirm.")
        case .update:
            if canRecoverStable, !invocation.arguments.contains("--nightly") {
                return t("由官方腳本的更新流程將 Nightly／開發版切回最新穩定版，可能需要管理員權限。此例外只開放回穩定版；清理等變更功能仍停用，直到更新後重新驗證通過。", "Use Mole's official script updater to return from Nightly/development to the latest stable release. Administrator authorization may be required. This exception only permits stable recovery; cleanup and other changes remain blocked until the updated engine is revalidated.")
            }
            return t("將更新官方 CLI，可能需要管理員權限。完成後 MoPanel 會重新偵測版本與指令相容性。GUI 本身不會隨之更新。", "Update the official CLI. Administrator authorization may be required. MoPanel rechecks version and command compatibility afterward. This does not update the GUI.")
        case .touchid: return t("修改 sudo 的 Touch ID 設定，需要官方 CLI 透過 macOS 授權。MoPanel 不記錄鍵盤輸入或管理員密碼。", "Change Touch ID authentication for sudo through Mole's authorization flow. MoPanel does not record keystrokes or passwords.")
        case .completion: return t("官方 CLI 可能修改你的 shell 啟動設定以安裝補全。可先執行 Dry Run 查看變更。", "Mole may update shell startup configuration to install completions. Preview the changes first.")
        default: return t("開啟官方互動選單，可能包含檔案移除與系統設定操作。請確認官方畫面再繼續。", "Open the official interactive menu, which can perform file removal and system changes. Review its prompts before proceeding.")
        }
    }

    func chooseCLI() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.message = t("選取可信任的官方 mo 或 mole 執行檔。偵測會執行它的 --version 與 --help。", "Choose a trusted official mo or mole executable. Detection runs its --version and --help.")
        if panel.runModal() == .OK, let url = panel.url { customPath = url.path; Task { await detect() } }
    }

    func chooseFolder(_ completion: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { completion(url) }
    }

    func reveal(_ path: String) {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    var brewURL: URL? { ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) } }

    func installWithHomebrew() {
        guard !isTestLaunch, !hasRunningOperation, !isDetecting, !shuttingDown, let brewURL else { return }
        prepareOperation(command: "brew install mole") { [weak self] in
            guard let self else { return }
            try self.startHomebrewInstall(brewURL)
        }
    }

    private func startHomebrewInstall(_ brewURL: URL) throws {
        let session = ManagedProcess()
        operationSession = session; operationTitle = t("安裝官方 Mole CLI", "Install the official Mole CLI")
        operationCommand = brewURL.path + " install mole"; operationIsInteractive = true; operationWasPreview = false; operationResult = nil
        operationDetailsExpanded = false
        operationKind = nil
        rawResult = ""
        session.onExit = { [weak self, weak session] result in
            guard let self, let session, self.operationSession === session else { return }
            self.operationResult = result; self.record("brew install mole", result: result)
            Task { await self.detect() }
        }
        try session.start(request: ProcessRequest(executable: brewURL, arguments: ["install", "mole"], environment: CLIProbe.environment, timeout: 1800), interactive: true)
        showOperation = true
    }

    func exportActivity() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MoPanel-activity.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let log = activities.map { "\($0.date.ISO8601Format())  \($0.command)  \($0.outcome)" }.joined(separator: "\n")
        do { try log.write(to: url, atomically: true, encoding: .utf8) }
        catch { self.error = error.localizedDescription }
    }
}
