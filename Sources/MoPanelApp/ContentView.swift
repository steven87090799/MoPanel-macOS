import SwiftUI
import AppKit
import MoPanelCore
import MoPanelProcess
import MoPanelTerminal

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var systemTools: SystemToolsController
    @EnvironmentObject private var appUpdates: AppUpdatesController
    @EnvironmentObject private var startup: StartupController
    @EnvironmentObject private var worktrees: GitWorktreeController
    @Environment(\.scenePhase) private var scenePhase
    @State private var started = false
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up.fill").font(.title2).foregroundStyle(.teal)
                    VStack(alignment: .leading) {
                        Text("MoPanel").font(.title2.bold())
                        Text(model.t("非官方原生介面", "Unofficial native interface")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(20)
                List(AppSection.allCases, selection: Binding<AppSection?>(get: { model.section }, set: { if let value = $0 { model.section = value } })) { section in
                    Label(model.t(section.zh, section.en), systemImage: section.symbol)
                        .foregroundStyle(model.section == section ? Color.white : Color.primary)
                        .tag(section).padding(.vertical, 5)
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 5) {
                    Label(model.installation.map { "Mole \($0.version)" } ?? model.t("尚未連接 CLI", "CLI not connected"), systemImage: model.installation == nil ? "circle.dashed" : "checkmark.circle")
                        .font(.caption.weight(.medium))
                    Text(model.t("清理由官方 CLI 執行", "Powered by the official CLI")).font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }.navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 270)
        } detail: {
            VStack(spacing: 0) {
                if model.fixtureMode {
                    Text(model.t("自動化測試模式 · 以下為合成測試資料", "AUTOMATED TEST MODE · Synthetic fixture data"))
                        .font(.caption.weight(.semibold)).frame(maxWidth: .infinity).padding(8).background(Color.yellow.opacity(0.22))
                }
                if let error = model.error {
                    HStack(alignment: .top) {
                        Label(error, systemImage: "exclamationmark.triangle").font(.callout).textSelection(.enabled)
                        Spacer(minLength: 12)
                        NativeActionButton(model.t("關閉錯誤訊息", "Dismiss error"), identifier: "mopanel.error.dismiss",
                                           systemImage: "xmark", appearance: .icon) { model.error = nil }
                    }.padding(14).background(Color.orange.opacity(0.12))
                }
                if let busy = model.busy {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(busy).font(.caption.monospaced()).lineLimit(1)
                        Spacer()
                        NativeActionButton(model.t("停止掃描", "Stop Scan"), identifier: "mopanel.scan.stop") {
                            model.cancelScan()
                        }
                    }.padding(12).background(.thinMaterial)
                }
                if model.section == .settings { SettingsView() }
                else if model.section == .appUpdates {
                    AppUpdatesView(controller: appUpdates, language: model.language,
                                   operationInProgress: model.moleOperationInProgress || model.isDetecting || startup.isBusy || worktrees.isBusy || systemTools.ejectingVolumeID != nil)
                }
                else if model.section == .startup {
                    StartupView(controller: startup, language: model.language,
                                operationInProgress: model.moleOperationInProgress || model.isDetecting || appUpdates.isBusy || worktrees.isBusy || systemTools.ejectingVolumeID != nil)
                }
                else if model.section == .worktrees {
                    GitWorktreeView(controller: worktrees, language: model.language,
                                    operationInProgress: model.moleOperationInProgress || model.isDetecting || appUpdates.isBusy || startup.isBusy || systemTools.ejectingVolumeID != nil)
                }
                else if model.section == .tools {
                    SystemToolsView(controller: systemTools, language: model.language,
                                    operationInProgress: model.moleOperationInProgress || model.isDetecting || appUpdates.isBusy || startup.isBusy || worktrees.isBusy,
                                    cliSummary: model.installation.map { "Mole \($0.version) · \($0.source.rawValue) · \($0.executable.path)" })
                }
                else if model.installation == nil { MissingEngineView() }
                else {
                    switch model.section {
                    case .dashboard: DashboardView()
                    case .uninstall: UninstallView()
                    case .analyze: AnalyzeView()
                    case .history: HistoryView()
                    case .clean, .optimize, .purge, .installer, .slim: MaintenanceView(section: model.section).id(model.section)
                    case .settings, .tools, .appUpdates, .startup, .worktrees: EmptyView()
                    }
                }
            }
            .background {
                LinearGradient(colors: [Color.teal.opacity(0.06), Color(nsColor: .windowBackgroundColor), Color.blue.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .navigationTitle(model.t(model.section.zh, model.section.en))
            .toolbar {
                ToolbarItem {
                    if model.isDetecting { ProgressView().controlSize(.small) }
                    else { Button { Task { await model.detect() } } label: { Label(model.t("重新偵測", "Re-detect"), systemImage: "arrow.clockwise") }.disabled(model.hasRunningOperation) }
                }
            }
        }
        .tint(.teal)
        .sheet(item: $model.pending) { pending in ConfirmationSheet(pending: pending) }
        .sheet(isPresented: $model.showOperation) { OperationSheet(session: model.operationSession) }
        .alert(model.t("安裝官方 Mole CLI？", "Install the official Mole CLI?"), isPresented: $model.homebrewConfirmation) {
            Button(model.t("取消", "Cancel"), role: .cancel) {}
            Button(model.t("透過 Homebrew 安裝", "Install with Homebrew")) { model.installWithHomebrew() }
        } message: { Text(model.t("將執行 brew install mole，從 Homebrew 下載並安裝 CLI 及必要相依套件。安裝過程會在 App 中顯示。", "Runs brew install mole to download the CLI and required dependencies. Installation output appears in the app.")) }
        .task {
            guard !started else { return }
            started = true
            if model.isTestLaunch { await SmokeHarness.run(model, systemTools: systemTools) }
            else { await model.detect() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard !model.isTestLaunch else { return }
            let active = phase == .active
            guard model.windowActive != active else { return }
            model.windowActive = active
        }
        .modifier(NativeUISmokeAccessibilityEnvironment())
        // A SwiftUI root-host replacement can make this view disappear while
        // its NSWindow is still open. Scene phase owns activity; the application
        // delegate owns last-window/quit cleanup. Publishing here would reenter
        // AppGraph while it is updating that host.
    }
}

struct MissingEngineView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "externaldrive.badge.questionmark").font(.system(size: 60)).foregroundStyle(.teal)
            Text(model.t("先連接官方 Mole CLI", "Connect the official Mole CLI")).font(.largeTitle.bold())
            Text(model.t("MoPanel 是操作介面。清理、分析及維護都交由獨立安裝的官方引擎執行。", "MoPanel is an interface. An independently installed official engine performs analysis, cleanup and maintenance."))
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            if model.isDetecting { ProgressView(model.t("正在偵測版本與指令…", "Checking version and commands…")) }
            else {
                HStack {
                    Button(model.t("選擇已安裝的 CLI", "Choose Installed CLI")) { model.chooseCLI() }
                    if model.brewURL != nil {
                        Button(model.t("以 Homebrew 安裝", "Install with Homebrew")) { model.homebrewConfirmation = true }.buttonStyle(.borderedProminent)
                    } else {
                        Link(model.t("Homebrew 安裝說明", "Homebrew Installation"), destination: URL(string: "https://brew.sh/")!)
                    }
                }
                Button(model.t("重新偵測常見安裝位置", "Search Standard Install Locations")) { Task { await model.detect() } }
            }
            Link(model.t("官方 Mole 安裝文件", "Official Mole Installation Guide"), destination: URL(string: "https://github.com/tw93/Mole/blob/main/README_TW.md")!)
            Text(model.t("不會自動下載或執行安裝腳本。", "Installation requires your explicit confirmation.")).font(.caption).foregroundStyle(.secondary)
        }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ConfirmationSheet: View {
    @EnvironmentObject private var model: AppModel
    let pending: PendingOperation
    @State private var acknowledged = false
    @State private var removalText = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(pending.title, systemImage: "exclamationmark.shield.fill").font(.title2.bold()).foregroundStyle(.orange)
            Text(pending.details).fixedSize(horizontal: false, vertical: true)
            Text(pending.invocation.displayCommand).font(.callout.monospaced()).textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            NativeAcknowledgementToggle(model.t("我已檢查預覽，了解操作影響並要繼續。", "I reviewed the preview and understand the effect of this operation."),
                                        identifier: "mopanel.confirmation.acknowledge", isOn: $acknowledged)
            if pending.isRemoval { TextField("REMOVE", text: $removalText).textFieldStyle(.roundedBorder) }
            HStack {
                NativeActionButton(model.t("取消", "Cancel"), identifier: "mopanel.confirmation.cancel", shortcut: .cancel) {
                    model.pending = nil
                }
                Spacer()
                NativeActionButton(model.t("繼續至官方操作", "Continue to Mole"), identifier: "mopanel.confirmation.continue", appearance: .warning) {
                    model.confirmPending()
                }
                    .disabled(!acknowledged || (pending.isRemoval && removalText != "REMOVE"))
            }
        }.padding(28).frame(width: 620)
    }
}

struct OperationSheet: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: ManagedProcess
    @State private var stopping = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.operationTitle).font(.title2.bold())
                    Text(model.operationCommand).font(.caption.monospaced()).textSelection(.enabled)
                }
                Spacer()
                if session.running { ProgressView().controlSize(.small) }
                Button(model.operationIsInteractive ? model.t("儲存執行摘要…", "Save Execution Summary…") : model.t("儲存此次輸出…", "Save Output…")) { model.exportOperationOutput() }.disabled(model.operationResult == nil)
                NativeActionButton(model.t("停止", "Stop"), identifier: "mopanel.operation.stop", destructive: true) {
                    stopping = true; session.cancel()
                }.disabled(!session.running || stopping)
                NativeActionButton(model.t("關閉", "Close"), identifier: "mopanel.operation.close", shortcut: .cancel) {
                    model.showOperation = false; if model.section == .dashboard { model.startMonitoring() }
                }.disabled(session.running)
            }
            if model.operationWasPreview {
                Notice(text: model.t("Dry Run 預覽：以官方畫面呈現項目、路徑、大小及略過原因。這不是已鎖定的刪除計畫，真正執行時 Mole 會重新檢查。", "Dry-run preview: Mole shows items, paths, sizes and skip reasons. This is not a locked deletion plan; Mole rechecks at execution."))
            } else if model.operationIsInteractive {
                Notice(text: model.t("官方互動介面。可以使用下方按鈕或直接用鍵盤操作；管理員密碼由 CLI／macOS 處理。請看清楚畫面再確認。", "Official interactive interface. Use the buttons or your keyboard. CLI/macOS handles administrator authentication. Read each prompt before confirming."))
            }
            if model.operationIsInteractive {
                Notice(text: model.t("互動終端內容只顯示在目前視窗，不保存在匯出檔案；匯出僅包含執行摘要。可在「操作歷史」查看 Mole 提供的紀錄，這些紀錄不是完整終端逐字稿。", "Interactive terminal content is shown in this window and is not stored in exports; the export contains an execution summary. History shows the records Mole provides, not a full terminal transcript."))
                TerminalPanel(session: session, english: model.language == "en").frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black).clipShape(RoundedRectangle(cornerRadius: 10))
                HStack {
                    terminalKey("←", "\u{1B}[D"); terminalKey("→", "\u{1B}[C")
                    terminalKey("Q", "q")
                    if model.operationCommand.contains("uninstall") { terminalKey(model.t("D／個人資料", "D / Personal data"), "d") }
                }.controlSize(.small)
            } else {
                ScrollView { Text(model.rawResult.isEmpty ? model.t("正在等待官方輸出…", "Waiting for Mole output…") : model.rawResult).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
            }
            if let result = model.operationResult {
                let text = result.cancelled ? model.t("已取消；已完成的步驟不會回復。", "Cancelled; completed steps are not rolled back.") : result.timedOut ? model.t("作業逾時，已停止子程序。", "Timed out; subprocesses were stopped.") : "Exit \(result.exitCode) · " + model.t("詳細結果請查看上方官方輸出及操作歷史。", "See Mole output and History for detailed results.")
                Label(text, systemImage: result.succeeded ? "checkmark.circle" : "exclamationmark.circle").font(.callout)
                if model.operationIsInteractive, !result.stderrText.isEmpty {
                    DisclosureGroup(model.t("子程序管理診斷", "Subprocess Diagnostics")) {
                        ScrollView {
                            Text(String(TerminalText.plain(result.stderrText).prefix(16_384)))
                                .font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 130)
                    }
                }
                if result.outputTruncated { Notice(text: model.t("輸出超過安全上限，作業已停止，不能將這次結果視為完整。", "Output exceeded the safety limit. The operation was stopped; this result is incomplete."), warning: true) }
            }
            if stopping && session.running { Notice(text: model.t("正在要求官方程序停止。Slim 若正在替換 App，會先完成安全步驟；已完成的變更不會回復。", "Waiting for the official process to stop. Slim finishes an in-progress app replacement safely. Completed changes are not rolled back."), warning: true) }
        }.padding(22).frame(minWidth: 980, idealWidth: 1100, minHeight: 680, idealHeight: 790).interactiveDismissDisabled(session.running)
    }
    private func terminalKey(_ title: String, _ key: String) -> some View {
        Button(title) { session.send(Data(key.utf8)) }.disabled(!session.running)
    }
}
