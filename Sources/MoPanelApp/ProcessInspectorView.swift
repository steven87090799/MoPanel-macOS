import SwiftUI
import AppKit
import MoPanelCore

@MainActor private struct PendingAppQuit: Identifiable {
    let id = UUID()
    let application: NSRunningApplication
    let identity: RunningApplicationIdentity
    let sample: MoleProcessInfo
    let sampledAt: Date
}

/// Native presentation of the process rows supplied by Mole. AppKit is used
/// only for an explicitly confirmed quit of a revalidated regular application.
struct ProcessInspectorView: View {
    @EnvironmentObject private var model: AppModel
    let snapshot: StatusSnapshot
    @State private var search = ""
    @State private var sort = "cpu"
    @State private var pinnedNames = Set<String>()
    @State private var pending: PendingAppQuit?
    @State private var forceQuit = false
    @State private var acknowledged = false
    @State private var outcome: String?

    private var rows: [MoleProcessInfo] {
        snapshot.topProcesses.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || String($0.pid).contains(search) }
            .sorted {
                let leftPinned = pinnedNames.contains($0.name), rightPinned = pinnedNames.contains($1.name)
                if leftPinned != rightPinned { return leftPinned }
                if sort == "name" { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                if sort == "memory" { return ($0.memoryBytes ?? 0) > ($1.memoryBytes ?? 0) }
                return $0.cpu > $1.cpu
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField(model.t("搜尋行程名稱或 PID", "Search process name or PID"), text: $search).textFieldStyle(.roundedBorder)
                Picker(model.t("排序", "Sort"), selection: $sort) {
                    Text("CPU").tag("cpu"); Text(model.t("記憶體", "Memory")).tag("memory"); Text(model.t("名稱", "Name")).tag("name")
                }.frame(width: 175)
            }
            if snapshot.processStale == true {
                Notice(text: model.t("目前是舊樣本，結束 App 的操作已停用。", "The process sample is stale; app quit actions are unavailable."), warning: true)
            }
            if snapshot.processCollectedAt == nil {
                Text(model.unavailable).foregroundStyle(.secondary)
            } else if rows.isEmpty {
                Text(model.t("沒有符合條件的行程。", "No matching process rows.")).foregroundStyle(.secondary)
            } else {
                ForEach(rows) { process in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            Button {
                                if pinnedNames.contains(process.name) { pinnedNames.remove(process.name) } else { pinnedNames.insert(process.name) }
                            } label: { Image(systemName: pinnedNames.contains(process.name) ? "pin.fill" : "pin") }
                                .buttonStyle(.plain).accessibilityLabel(model.t("置頂／取消置頂 ", "Pin or unpin ") + process.name)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(process.name).font(.callout.weight(.medium)).lineLimit(1)
                                Text("PID \(process.pid)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Text(DisplayFormat.percent(process.cpu)).monospacedDigit().frame(width: 85, alignment: .trailing)
                            Text(process.memoryBytes.map { DisplayFormat.bytes($0) } ?? DisplayFormat.percent(process.memory))
                                .monospacedDigit().frame(width: 100, alignment: .trailing)
                            Button(model.t("檢視", "Inspect")) { inspect(process) }.disabled(model.hasRunningOperation)
                        }
                        if let command = process.command, !command.isEmpty {
                            Text(command).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                        }
                    }.padding(.vertical, 6)
                    Divider()
                }
            }
            let missingPins = pinnedNames.subtracting(Set(snapshot.topProcesses.map(\.name)))
            if !missingPins.isEmpty {
                Text(model.t("置頂但未出現在此次官方樣本：", "Pinned, but absent from this Mole sample: ") + missingPins.sorted().joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            }
            Text(model.t("MoPanel 新實作：搜尋、排序、置頂與受保護的 App 結束要求。數值仍取自 Mole 的高用量行程清單；置頂不會額外掃描，也不會補造未回傳的讀值。", "Added by MoPanel: search, sort, pin and protected app quit requests. Metrics remain Mole's top-process sample. Pinning adds no collector and does not invent missing readings."))
                .font(.caption).foregroundStyle(.secondary)
            if let outcome { Notice(text: outcome) }
            HStack {
                if let zombies = snapshot.zombieCount { Text(model.t("殭屍行程：", "Zombie processes: ") + String(zombies)).font(.caption) }
                Spacer()
                Button(model.t("開啟系統活動監視器", "Open Activity Monitor")) {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") { NSWorkspace.shared.open(url) }
                    else { outcome = model.t("找不到系統活動監視器。", "Activity Monitor could not be located.") }
                }
            }
            ForEach(snapshot.processAlerts) { alert in
                Notice(text: alert.name + " · " + DisplayFormat.percent(alert.cpu) + " · " + alert.window + " · " + alert.status, warning: true)
            }
        }
        .sheet(item: $pending) { item in quitSheet(item) }
    }

    @MainActor private func identity(_ application: NSRunningApplication) -> RunningApplicationIdentity? {
        guard !application.isTerminated, let bundleID = application.bundleIdentifier,
              let appURL = application.bundleURL, let executableURL = application.executableURL,
              let launchedAt = application.launchDate else { return nil }
        return RunningApplicationIdentity(pid: application.processIdentifier, bundleIdentifier: bundleID,
                                          appPath: appURL.resolvingSymlinksInPath().path,
                                          executablePath: executableURL.resolvingSymlinksInPath().path,
                                          launchedAt: launchedAt, isRegularApplication: application.activationPolicy == .regular)
    }

    @MainActor private func inspect(_ process: MoleProcessInfo) {
        guard !model.hasRunningOperation else { return }
        guard let application = NSWorkspace.shared.runningApplications.first(where: { Int($0.processIdentifier) == process.pid }),
              let current = identity(application), let text = snapshot.processCollectedAt else {
            outcome = model.t("此行程不是可安全識別的一般 App；可在系統活動監視器查看。MoPanel 不會對未知 PID 傳送終止訊號。", "This process is not an identifiable regular app. Inspect it in Activity Monitor; MoPanel will not signal an unknown PID.")
            return
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let collected = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        guard snapshot.processStale != true, let collected else {
            outcome = denialText(.staleSample); return
        }
        do {
            try QuitAppPolicy.validate(expected: current, current: current, selfPID: ProcessInfo.processInfo.processIdentifier,
                                       sampleCommand: process.command ?? "", sampledAt: collected, now: Date(), testMode: model.isTestLaunch)
            forceQuit = false; acknowledged = false
            pending = PendingAppQuit(application: application, identity: current, sample: process, sampledAt: collected)
        } catch { outcome = denialText(error as? QuitAppPolicy.Denial) }
    }

    private func quitSheet(_ item: PendingAppQuit) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(item.application.localizedName ?? item.sample.name).font(.title2.bold())
            LabeledContent("PID", value: String(item.identity.pid))
            Text(item.identity.appPath).font(.callout.monospaced()).textSelection(.enabled)
            Text(model.t("一般結束會交由 App 自己處理，可出現儲存提示。強制結束可能遺失尚未儲存的資料；此操作由 MoPanel 透過 macOS AppKit 執行。", "A normal quit lets the app handle saving and may show its own prompt. Force Quit can lose unsaved data. MoPanel sends this request using macOS AppKit."))
            Button(model.t("在 Finder 顯示", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.identity.appPath)]) }
            Toggle(model.t("強制結束", "Force Quit"), isOn: $forceQuit)
            Toggle(model.t("我已確認 App 與未儲存資料的影響", "I checked the app and the impact on unsaved data"), isOn: $acknowledged)
            HStack {
                Button(model.t("返回", "Back"), role: .cancel) { pending = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(forceQuit ? model.t("強制結束 App", "Force Quit App") : model.t("要求 App 結束", "Request App Quit"), role: .destructive) { performQuit(item) }
                    .disabled(!acknowledged).buttonStyle(.borderedProminent)
            }
        }.padding(26).frame(width: 590)
    }

    @MainActor private func performQuit(_ item: PendingAppQuit) {
        defer { pending = nil }
        guard !model.hasRunningOperation else {
            outcome = model.t("另一個作業已開始，已取消這次結束要求。", "Another operation started; this quit request was cancelled.")
            return
        }
        guard let current = identity(item.application) else { outcome = denialText(.identityChanged); return }
        do {
            // Confirmation can remain open for a long time. Revalidate the app
            // identity; require a new current Mole sample for the same command.
            guard let latest = model.status, latest.processStale != true,
                  let sample = latest.topProcesses.first(where: { $0.pid == Int(item.identity.pid) }),
                  let text = latest.processCollectedAt else { throw QuitAppPolicy.Denial.staleSample }
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let sampledAt = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text) else { throw QuitAppPolicy.Denial.staleSample }
            try QuitAppPolicy.validate(expected: item.identity, current: current, selfPID: ProcessInfo.processInfo.processIdentifier,
                                       sampleCommand: sample.command ?? "", sampledAt: sampledAt, now: Date(), testMode: model.isTestLaunch)
            let accepted = forceQuit ? item.application.forceTerminate() : item.application.terminate()
            outcome = accepted ? model.t("macOS 已接受結束要求；App 可能仍在等待儲存。以後續行程樣本確認結果。", "macOS accepted the quit request; the app may still be waiting to save. Check a later process sample for the result.") : model.t("macOS 或 App 拒絕結束要求，未宣稱已停止。", "macOS or the app rejected the quit request. It is not reported as stopped.")
        } catch { outcome = denialText(error as? QuitAppPolicy.Denial) }
    }

    private func denialText(_ reason: QuitAppPolicy.Denial?) -> String {
        switch reason {
        case .testing: return model.t("測試模式不會結束真實 App。", "Test mode never quits real apps.")
        case .staleSample: return model.t("行程樣本已過期或 App 比樣本更新，請先重新取得快照。", "The process sample is stale or predates this app. Refresh the snapshot first.")
        case .identityChanged: return model.t("App 身分已改變或已結束；這次要求已取消。", "The app identity changed or the app exited. The request was cancelled.")
        case .protectedApplication: return model.t("系統 App、MoPanel 與受保護工具不提供結束操作。", "System apps, MoPanel and protected tools cannot be quit here.")
        case .sampleMismatch: return model.t("CLI 行程路徑無法與 macOS App 身分精確對應，已停止此操作。", "The CLI process path cannot be matched exactly to the macOS app identity. The action was blocked.")
        default: return model.t("此行程不是可安全識別的一般 App；請使用系統活動監視器。", "This is not an identifiable regular app. Use Activity Monitor.")
        }
    }
}
