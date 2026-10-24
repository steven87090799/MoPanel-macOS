// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI
import Combine
import Darwin
import IOKit.pwr_mgt
import IOKit.ps
import UniformTypeIdentifiers
import MoPanelCore

struct EjectableVolume: Identifiable, Equatable, Sendable {
    let id: String
    let url: URL
    let name: String
    let totalBytes: Int64?
    let availableBytes: Int64?
}

struct SystemDoctorEntry: Identifiable, Codable, Sendable {
    let id: String
    let title: String
    let value: String
    let source: String
    let state: String
}

struct SystemDoctorReport: Codable, Sendable {
    let generatedAt: Date
    let implementation: String
    let entries: [SystemDoctorEntry]
    var plainText: String {
        let date = ISO8601DateFormatter().string(from: generatedAt)
        return (["MoPanel Doctor — \(implementation)", date, ""] + entries.map {
            "\($0.title): \($0.value)\n  [\($0.state)] \($0.source)"
        }).joined(separator: "\n") + "\n"
    }
}

struct SystemToolsSmokeReport: Codable, Sendable {
    let platform: String
    let assertionCreated: Bool
    let assertionReadableBeforeRelease: Bool
    let assertionReleaseCode: Int32?
    let assertionAbsentAfterRelease: Bool
    let screenCount: Int
    let overlayWindowsCreated: Int
    let overlayWindowsClosed: Int
    let overlayWasPresented: Bool
    let inputWasIntercepted: Bool
    let ejectWasCalled: Bool
    let doctorEntryCount: Int
    let errors: [String]
}

/// Only explicitly requested native tools live here. There is no login item,
/// daemon, shell command, scan engine, persistent power policy or input tap.
@MainActor final class SystemToolsController: ObservableObject {
    @Published private(set) var keepAwakeDecision: KeepAwakeDecision = .stopped
    @Published private(set) var keepAwakeEndsAt: Date?
    @Published private(set) var keepAwakeMode: KeepAwakeMode = .displayAndSystem
    @Published private(set) var powerReading = SystemPowerReading(source: .unknown, batteryPercent: nil)
    @Published private(set) var keepAwakeMessage = ""
    @Published private(set) var isCleaningScreen = false
    @Published private(set) var volumes: [EjectableVolume] = []
    @Published private(set) var volumesLoaded = false
    @Published private(set) var isRefreshingVolumes = false
    @Published private(set) var ejectingVolumeID: String?
    @Published private(set) var volumeMessage = ""
    @Published private(set) var doctorReport: SystemDoctorReport?
    @Published private(set) var isGeneratingDoctor = false
    @Published var errorMessage: String?

    var language: String
    /// The host may protect the installed CLI's resource directory too.
    var additionalProtectedPaths: [String] = []
    var externalOperationInProgress: (() -> Bool)?
    private var session: KeepAwakeSession?
    private var assertion: NativePowerAssertion?
    private var expirationTimer: Timer?
    private var powerSource: CFRunLoopSource?
    private var powerObservers: [NSObjectProtocol] = []
    private var cleanObservers: [NSObjectProtocol] = []
    private var cleaningWindows: [ScreenCleaningWindow] = []
    private var cleaningTimer: Timer?
    private let clockOrigin = ContinuousClock.now

    init(language: String = "zh-Hant") { self.language = language }

    var hasKeepAwakeSession: Bool { session != nil || assertion != nil }
    var userToolActionsAllowed: Bool { !ReadOnlyBenchmark.isTestLaunch(ProcessInfo.processInfo.arguments) }
    var keepsScreenAwake: Bool { keepAwakeDecision == .active && keepAwakeMode == .displayAndSystem }
    var assertionIsActive: Bool { assertion?.isActive == true }
    private func t(_ zh: String, _ en: String) -> String { language == "en" ? en : zh }
    private var monotonicNow: TimeInterval {
        let elapsed = clockOrigin.duration(to: ContinuousClock.now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    func startKeepAwake(mode: KeepAwakeMode, duration: KeepAwakeDuration) {
        guard userToolActionsAllowed else {
            errorMessage = t("測試模式不會啟動一般保持喚醒工作階段。", "Test mode does not start normal Keep Awake sessions.")
            return
        }
        stopKeepAwake()
        guard assertion == nil else { return } // A failed release must be retried first.
        keepAwakeMode = mode
        session = KeepAwakeSession(mode: mode, duration: duration, now: monotonicNow)
        keepAwakeEndsAt = duration.seconds.map { Date().addingTimeInterval($0) }
        guard installPowerObservation() else {
            session = nil; keepAwakeEndsAt = nil
            errorMessage = t("無法監聽電源變動，未啟用保持喚醒。", "Power-change monitoring is unavailable; Keep Awake was not enabled.")
            return
        }
        if let seconds = duration.seconds {
            let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcileKeepAwake() }
            }
            expirationTimer = timer; RunLoop.main.add(timer, forMode: .common)
        }
        reconcileKeepAwake()
    }

    func stopKeepAwake() {
        session?.stop(); session = nil
        expirationTimer?.invalidate(); expirationTimer = nil
        removePowerObservation()
        keepAwakeEndsAt = nil
        releaseAssertion()
        keepAwakeDecision = assertion == nil ? .stopped : .active
        keepAwakeMessage = assertion == nil
            ? t("已停止；依系統原本的睡眠設定運作。", "Stopped; normal system sleep settings apply.")
            : t("電源要求尚未確認釋放，請重試停止或結束 MoPanel。", "Power assertion release is not confirmed. Retry Stop or quit MoPanel.")
    }

    /// Explicit app lifecycle hook. NSWorkspace sleep notification uses this
    /// same path; a user-requested sleep is never vetoed or silently restarted.
    func cleanupForQuit() {
        stopKeepAwake()
        stopCleanScreen()
    }

    fileprivate func reconcileKeepAwake() {
        guard var current = session else { return }
        powerReading = SystemToolsMetadata.powerReading()
        let next = current.evaluate(at: monotonicNow, power: powerReading)
        session = current
        if next == .expired || next == .stopped {
            stopKeepAwake()
            if assertion == nil {
                keepAwakeDecision = next
                keepAwakeMessage = t("保持喚醒已結束。", "Keep Awake has ended.")
            }
            return
        }
        if next == .active, assertion == nil {
            do {
                assertion = try NativePowerAssertion(mode: current.mode, timeout: current.remaining(at: monotonicNow))
            } catch {
                stopKeepAwake()
                errorMessage = t("無法建立電源要求：", "Could not create power assertion: ") + error.localizedDescription
                return
            }
        } else if next != .active {
            releaseAssertion()
            if assertion != nil {
                keepAwakeDecision = .active
                keepAwakeMessage = t("電源要求尚未確認釋放，請重試停止或結束 MoPanel。", "Power assertion release is not confirmed. Retry Stop or quit MoPanel.")
                return
            }
        }
        keepAwakeDecision = next
        switch next {
        case .active:
            keepAwakeMessage = t("已要求 macOS 避免閒置睡眠。手動睡眠、關蓋與系統保護仍由 macOS 決定。", "macOS was asked to prevent idle sleep. Manual sleep, lid closure and system protections remain under macOS control.")
        case .pausedLowBattery:
            keepAwakeMessage = t("電量達 20% 或以下，已釋放電源要求。接上電源後可在原期限內自動繼續。", "At 20% battery or below, power assertions are released. Connecting power resumes within the original time limit.")
        case .pausedUnknownPower:
            keepAwakeMessage = t("無法確認電源或電量，保持喚醒已暫停。", "Power source or charge could not be confirmed; Keep Awake is paused.")
        case .expired, .stopped: break
        }
    }

    private func releaseAssertion() {
        guard let assertion else { return }
        let code = assertion.release()
        if code == kIOReturnSuccess || code == kIOReturnNotFound {
            self.assertion = nil
        } else {
            errorMessage = t("釋放電源要求失敗，請重試停止或結束 MoPanel。錯誤碼：", "Power assertion release failed. Retry Stop or quit MoPanel. Code: ") + String(code)
        }
    }

    private func installPowerObservation() -> Bool {
        removePowerObservation()
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            // Registered only on the main run loop below.
            MainActor.assumeIsolated {
                Unmanaged<SystemToolsController>.fromOpaque(context).takeUnretainedValue().reconcileKeepAwake()
            }
        }, context)?.takeRetainedValue() else { return false }
        powerSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        let center = NSWorkspace.shared.notificationCenter
        powerObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stopKeepAwake()
                self?.keepAwakeMessage = self?.t("Mac 正在睡眠，已結束保持喚醒；喚醒後請自行重新啟動。", "The Mac is sleeping. Keep Awake ended; start a new session after waking.") ?? ""
                self?.stopCleanScreen()
            }
        })
        return true
    }

    private func removePowerObservation() {
        if let source = powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source); powerSource = nil
        }
        let center = NSWorkspace.shared.notificationCenter
        for token in powerObservers { center.removeObserver(token) }
        powerObservers.removeAll()
    }

    // MARK: Clean Screen (no system-wide input lock)

    func startCleanScreen(light: Bool = false) {
        guard userToolActionsAllowed else {
            errorMessage = t("測試模式不會顯示清潔螢幕遮罩。", "Test mode does not present Clean Screen overlays.")
            return
        }
        stopCleanScreen()
        guard !NSScreen.screens.isEmpty else {
            errorMessage = t("找不到可用螢幕。", "No display is available."); return
        }
        cleaningWindows = makeCleaningWindows(light: light)
        isCleaningScreen = true
        NSApp.activate()
        for window in cleaningWindows { window.orderFrontRegardless() }
        cleaningWindows.first?.makeKeyAndOrderFront(nil)
        let timer = Timer(timeInterval: 300, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopCleanScreen() }
        }
        cleaningTimer = timer; RunLoop.main.add(timer, forMode: .common)
        for name in [NSApplication.didResignActiveNotification, NSApplication.didChangeScreenParametersNotification] {
            cleanObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopCleanScreen() }
            })
        }
        cleanObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopCleanScreen() }
        })
    }

    func stopCleanScreen() {
        cleaningTimer?.invalidate(); cleaningTimer = nil
        // Tokens may belong to either center. Removing an unknown token is safe.
        for token in cleanObservers {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        cleanObservers.removeAll()
        for window in cleaningWindows { window.orderOut(nil); window.close() }
        cleaningWindows.removeAll()
        isCleaningScreen = false
    }

    private func makeCleaningWindows(light: Bool) -> [ScreenCleaningWindow] {
        NSScreen.screens.map { screen in
            let window = ScreenCleaningWindow(contentRect: screen.frame, styleMask: .borderless,
                                              backing: .buffered, defer: false, screen: screen)
            window.setFrame(screen.frame, display: false)
            window.isReleasedWhenClosed = false
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isOpaque = true; window.hasShadow = false
            window.backgroundColor = light ? .white : .black
            window.exitAction = { [weak self] in self?.stopCleanScreen() }
            window.contentView = NSHostingView(rootView: ScreenCleaningOverlay(light: light, language: language) { [weak self] in self?.stopCleanScreen() })
            return window
        }
    }

    // MARK: Volumes

    private var protectedVolumePaths: [String] {
        [FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path,
         Bundle.main.bundleURL.resolvingSymlinksInPath().path] + additionalProtectedPaths
    }

    func refreshVolumes() async {
        guard !isRefreshingVolumes, ejectingVolumeID == nil else { return }
        isRefreshingVolumes = true
        let protected = protectedVolumePaths
        let result = await Task.detached(priority: .utility) { SystemToolsMetadata.volumes(protectedPaths: protected) }.value
        volumes = result.volumes; volumesLoaded = true; isRefreshingVolumes = false
        volumeMessage = result.error.map { t("無法讀取裝置清單：", "Could not read mounted volumes: ") + $0 }
            ?? (result.skipped > 0 ? t("部分磁碟資料無法確認，因此未提供退出操作。", "Some volume metadata could not be confirmed, so no eject action is offered for those volumes.") : "")
    }

    /// The caller must present a confirmation naming the selected volume.
    /// Never called by smoke tests. No forced-unmount fallback is provided.
    func ejectVolume(_ selected: EjectableVolume) async {
        guard !ReadOnlyBenchmark.isTestLaunch(ProcessInfo.processInfo.arguments) else {
            errorMessage = t("測試模式不會退出真實磁碟。", "Test mode never ejects real volumes.")
            return
        }
        guard externalOperationInProgress?() != true else {
            errorMessage = t("請先完成或停止其他作業，再退出磁碟。", "Finish or stop other operations before ejecting a volume.")
            return
        }
        guard ejectingVolumeID == nil, !isRefreshingVolumes else { return }
        ejectingVolumeID = selected.id
        let protected = protectedVolumePaths
        let result = await Task.detached(priority: .userInitiated) { () -> String? in
            autoreleasepool {
                let current = SystemToolsMetadata.volumes(protectedPaths: protected)
                guard current.volumes.contains(where: { $0.id == selected.id && $0.url == selected.url }) else {
                    return "The mounted volume changed or is no longer eligible. Refresh the list."
                }
                do {
                    // Public NSWorkspace API; errors such as 'busy' are preserved.
                    try NSWorkspace.shared.unmountAndEjectDevice(at: selected.url)
                    let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
                    if mounted.contains(where: { $0.standardizedFileURL.path == selected.url.path }) {
                        return "The volume is still mounted after the eject request."
                    }
                    return nil
                } catch { return error.localizedDescription }
            }
        }.value
        ejectingVolumeID = nil
        if let result { errorMessage = t("無法退出磁碟：", "Could not eject volume: ") + result }
        else { volumeMessage = t("已退出：", "Ejected: ") + selected.name }
        await refreshVolumes()
    }

    // MARK: Read-only Doctor

    func generateDoctorReport(cliSummary: String? = nil) async {
        guard !isGeneratingDoctor else { return }
        isGeneratingDoctor = true
        let process = ProcessInfo.processInfo
        let power = SystemToolsMetadata.powerReading()
        let unavailable = t("無法取得", "Unavailable")
        var entries: [SystemDoctorEntry] = []
        func add(_ id: String, _ title: String, _ value: String, _ source: String, _ state: String = "observed") {
            entries.append(.init(id: id, title: title, value: value, source: source, state: state))
        }
        add("app", "MoPanel", (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? unavailable, "Bundle metadata")
        add("os", "macOS", process.operatingSystemVersionString, "ProcessInfo.operatingSystemVersionString")
        let model = SystemToolsMetadata.sysctlString("hw.model")
        add("model", t("機型", "Hardware model"), model ?? unavailable, "sysctl hw.model", model == nil ? "unavailable" : "observed")
        add("cpu", t("可用邏輯核心", "Active logical CPUs"), String(process.activeProcessorCount), "ProcessInfo.activeProcessorCount")
        add("memory", t("實體記憶體", "Physical memory"), ByteCountFormatter.string(fromByteCount: Int64(clamping: process.physicalMemory), countStyle: .memory), "ProcessInfo.physicalMemory")
        add("uptime", t("開機秒數", "Uptime seconds"), String(Int(process.systemUptime)), "ProcessInfo.systemUptime")
        let thermal: String
        switch process.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        add("thermal", t("系統熱狀態", "Thermal state"), thermal, "ProcessInfo.thermalState")
        add("low-power", t("低耗電模式", "Low Power Mode"), String(process.isLowPowerModeEnabled), "ProcessInfo.isLowPowerModeEnabled")
        add("power", t("目前電源", "Power source"), power.source.rawValue, "IOPSGetProvidingPowerSourceType", power.source == .unknown ? "unavailable" : "observed")
        add("battery", t("電池電量", "Battery level"), power.batteryPercent.map { String(format: "%.0f%%", $0) } ?? unavailable, "IOPSGetPowerSourceDescription", power.batteryPercent == nil ? "unavailable" : "observed")
        add("displays", t("螢幕", "Displays"), NSScreen.screens.map { "\(Int($0.frame.width)) × \(Int($0.frame.height)) pt @\($0.backingScaleFactor)x" }.joined(separator: "; "), "NSScreen.screens")
        add("uid", t("目前有效 UID", "Effective UID"), String(geteuid()), "geteuid()")
        add("cli", t("Mole 相容性摘要", "Mole compatibility summary"), cliSummary ?? t("未由 CLI 探測器提供", "Not supplied by CLI probe"), "MoPanel CLIProbe", cliSummary == nil ? "not_checked" : "reported_by_probe")
        add("fda", t("完整磁碟存取", "Full Disk Access"), t("本報告不讀取私人資料來推斷權限；請到系統設定確認。", "This report does not probe private files to infer authorization; check System Settings."), "No complete public TCC authorization query", "not_checked")
        add("security", "SIP / Gatekeeper / FileVault", t("本報告未檢查，也不修改系統安全設定。", "Not checked here; system security settings are not modified."), "No command or privileged probe executed", "not_checked")
        let protected = protectedVolumePaths
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let storage = await Task.detached(priority: .utility) {
            (SystemToolsMetadata.volumes(protectedPaths: protected), SystemToolsMetadata.storage(at: homeURL))
        }.value
        add("volume-count", t("可退出外接磁碟數", "Eligible external volumes"), String(storage.0.volumes.count), "FileManager mountedVolumeURLs + URLResourceValues", storage.0.error == nil ? "observed" : "unavailable")
        if let value = storage.1 {
            add("storage", t("家目錄所在磁碟", "Home volume capacity"), "\(value.available) / \(value.total) bytes available", "URLResourceValues volumeAvailableCapacity / volumeTotalCapacity")
        } else {
            add("storage", t("家目錄所在磁碟", "Home volume capacity"), unavailable, "URLResourceValues", "unavailable")
        }
        add("tools", t("電源／螢幕工具", "Power / screen tools"), "keepAwake=\(keepAwakeDecision.rawValue); assertion=\(assertionIsActive); screenOverlay=\(isCleaningScreen)", "MoPanel native tool state")
        doctorReport = .init(generatedAt: Date(), implementation: "MoPanel 新實作 / MoPanel implementation", entries: entries)
        isGeneratingDoctor = false
    }

    func copyDoctorReport() {
        guard let report = doctorReport else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.plainText, forType: .string)
    }

    func exportDoctorReport() {
        guard let report = doctorReport else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "MoPanel-Doctor.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try report.plainText.write(to: url, atomically: true, encoding: .utf8) }
        catch { errorMessage = error.localizedDescription }
    }

    // MARK: Safe CI smoke (no input interception or device ejection)

    func runSafeSmokeTest() async -> SystemToolsSmokeReport {
        var errors: [String] = []
        var created = false, readable = false, absent = false
        var releaseCode: Int32?
        if hasKeepAwakeSession || isCleaningScreen {
            errors.append("Smoke test refused while a user tool session is active.")
        } else {
            do {
                let probe = try NativePowerAssertion(mode: .system, timeout: 5)
                created = true; readable = probe.propertiesExist
                let id = probe.identifier
                releaseCode = probe.release()
                if let id { absent = !NativePowerAssertion.propertiesExist(for: id) }
                if !readable { errors.append("New assertion properties were unavailable.") }
                if releaseCode != kIOReturnSuccess { errors.append("Assertion release did not succeed.") }
                if !absent { errors.append("Assertion still exists after release.") }
            } catch { errors.append(error.localizedDescription) }
        }
        // Exercise real AppKit window construction and close without ordering
        // windows on screen, activating the app, taking focus, or intercepting input.
        let windows = makeCleaningWindows(light: false)
        let count = windows.count
        for window in windows { window.close() }
        if count == 0 { errors.append("No NSScreen available for overlay construction test.") }
        await generateDoctorReport(cliSummary: "Safe smoke test; no CLI mutation")
        return .init(platform: ProcessInfo.processInfo.operatingSystemVersionString,
                     assertionCreated: created, assertionReadableBeforeRelease: readable,
                     assertionReleaseCode: releaseCode, assertionAbsentAfterRelease: absent,
                     screenCount: NSScreen.screens.count, overlayWindowsCreated: count,
                     overlayWindowsClosed: windows.filter { !$0.isVisible }.count,
                     overlayWasPresented: false, inputWasIntercepted: false, ejectWasCalled: false,
                     doctorEntryCount: doctorReport?.entries.count ?? 0, errors: errors)
    }

    deinit {
        // IOPM assertions are also removed by the OS when their owning process
        // exits. These non-AppKit resources can be released if the owner drops.
        _ = assertion?.release()
        expirationTimer?.invalidate(); cleaningTimer?.invalidate()
        if let source = powerSource { CFRunLoopSourceInvalidate(source) }
        for token in powerObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        for token in cleanObservers {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }
}

private final class NativePowerAssertion {
    private(set) var identifier: IOPMAssertionID?
    var isActive: Bool { identifier != nil }
    var propertiesExist: Bool {
        guard let identifier else { return false }
        return Self.propertiesExist(for: identifier)
    }
    static func propertiesExist(for identifier: IOPMAssertionID) -> Bool {
        guard let copy = IOPMAssertionCopyProperties(identifier) else { return false }
        // Copy-rule ownership must be consumed even when only checking existence.
        _ = copy.takeRetainedValue()
        return true
    }
    init(mode: KeepAwakeMode, timeout: TimeInterval?) throws {
        var value: IOPMAssertionID = 0
        let type = mode == .displayAndSystem ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
        let result = IOPMAssertionCreateWithDescription(type as CFString,
            "MoPanel Keep Awake" as CFString, "Explicit user-requested session" as CFString,
            "Keep an active task awake until the selected deadline or Stop." as CFString,
            nil, timeout.map { max(0.01, $0) } ?? 0, kIOPMAssertionTimeoutActionRelease as CFString, &value)
        guard result == kIOReturnSuccess else {
            throw NSError(domain: "MoPanel.IOPM", code: Int(result), userInfo: [NSLocalizedDescriptionKey: "IOPMAssertionCreateWithDescription returned \(result)"])
        }
        identifier = value
    }
    @discardableResult func release() -> IOReturn {
        guard let identifier else { return kIOReturnSuccess }
        let result = IOPMAssertionRelease(identifier)
        if result == kIOReturnSuccess || result == kIOReturnNotFound { self.identifier = nil }
        return result
    }
    deinit { _ = release() }
}

private enum SystemToolsMetadata {
    struct VolumeResult: Sendable { let volumes: [EjectableVolume]; let skipped: Int; let error: String? }
    static func volumes(protectedPaths: [String]) -> VolumeResult {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeUUIDStringKey, .volumeIsRootFileSystemKey,
            .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsEjectableKey, .volumeIsRemovableKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        guard let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) else {
            return .init(volumes: [], skipped: 0, error: "Mounted volumes unavailable")
        }
        var result: [EjectableVolume] = [], skipped = 0
        for mount in mounted {
            let url = URL(fileURLWithPath: mount.path).resolvingSymlinksInPath().standardizedFileURL
            do {
                let values = try url.resourceValues(forKeys: keys)
                guard EjectEligibility.allows(isRoot: values.volumeIsRootFileSystem, isInternal: values.volumeIsInternal,
                    isLocal: values.volumeIsLocal, isEjectable: values.volumeIsEjectable, isRemovable: values.volumeIsRemovable,
                    mountPath: url.path, protectedPaths: protectedPaths) else { continue }
                var information = stat()
                guard stat(url.path, &information) == 0 else { skipped += 1; continue }
                let identity = (values.volumeUUIDString ?? "no-uuid") + ":\(information.st_dev):\(information.st_ino)"
                result.append(.init(id: url.path + "|" + identity, url: url, name: values.volumeName ?? url.lastPathComponent,
                                    totalBytes: values.volumeTotalCapacity.map(Int64.init), availableBytes: values.volumeAvailableCapacity.map(Int64.init)))
            } catch { skipped += 1 }
        }
        return .init(volumes: result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, skipped: skipped, error: nil)
    }

    static func storage(at url: URL) -> (total: Int64, available: Int64)? {
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity else { return nil }
        return (Int64(total), Int64(available))
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1, size < 4_096 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }

    static func powerReading() -> SystemPowerReading {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return .init(source: .unknown, batteryPercent: nil) }
        let provider = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        let source: SystemPowerReading.Source
        switch provider {
        case kIOPSACPowerValue: source = .external
        case kIOPSBatteryPowerValue: source = .battery
        case kIOPMUPSPowerKey: source = .ups
        default: source = .unknown
        }
        let handles = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] ?? []
        var percent: Double?
        for handle in handles {
            guard let details = IOPSGetPowerSourceDescription(snapshot, handle)?.takeUnretainedValue() as? [String: Any],
                  (details[kIOPSIsPresentKey] as? NSNumber)?.boolValue != false else { continue }
            let type = details[kIOPSTypeKey] as? String
            guard type == (source == .ups ? kIOPSUPSType : kIOPSInternalBatteryType),
                  let current = details[kIOPSCurrentCapacityKey] as? NSNumber,
                  let maximum = details[kIOPSMaxCapacityKey] as? NSNumber,
                  maximum.doubleValue > 0 else { continue }
            let value = 100 * current.doubleValue / maximum.doubleValue
            if value.isFinite, (0...100).contains(value) { percent = min(percent ?? value, value) }
        }
        return .init(source: source, batteryPercent: percent)
    }
}

@MainActor private final class ScreenCleaningWindow: NSWindow {
    var exitAction: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { exitAction?() } else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { exitAction?() }
}

private struct ScreenCleaningOverlay: View {
    let light: Bool
    let language: String
    let exit: () -> Void
    var body: some View {
        ZStack {
            (light ? Color.white : Color.black).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "display").font(.largeTitle)
                Text(language == "en" ? "Press Esc to finish" : "按 Esc 結束清潔").font(.title2)
                Text(language == "en" ? "Closes automatically after 5 minutes. Keyboard is not locked." : "5 分鐘後自動結束；此模式不鎖住鍵盤。")
                    .font(.callout)
                Button(language == "en" ? "Finish" : "結束", action: exit).buttonStyle(.bordered).keyboardShortcut(.cancelAction)
            }.foregroundStyle(light ? Color.black.opacity(0.6) : Color.white.opacity(0.6))
        }.accessibilityElement(children: .contain)
    }
}
