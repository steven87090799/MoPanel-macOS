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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = false
    @State private var isSidebarCollapsed = false
    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                SidebarNavigation(isCompact: $isSidebarCollapsed)
                Divider()
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
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(model.scanActivityTitle).font(.headline)
                                Spacer()
                                NativeActionButton(model.t("停止掃描", "Stop Scan"), identifier: "mopanel.scan.stop") {
                                    model.cancelScan()
                                }
                            }
                            ProgressView().progressViewStyle(.linear).accessibilityLabel(model.scanActivityTitle)
                            Text(model.t("指令：", "Command: ") + busy).font(.caption.monospaced()).textSelection(.enabled)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let pending = model.pending {
                        ConfirmationPanel(pending: pending).id(pending.id)
                            .padding(.horizontal, 16).padding(.bottom, 12)
                    } else if model.homebrewConfirmation {
                        HomebrewInstallConfirmationPanel().padding(.horizontal, 16).padding(.bottom, 12)
                    } else if appUpdates.showOperation, let session = appUpdates.operationSession, session.running || appUpdates.isBusy {
                        AppUpdateOperationView(controller: appUpdates, session: session, language: model.language)
                            .id(ObjectIdentifier(session)).padding(.horizontal, 16).padding(.bottom, 12)
                    } else if model.showOperation {
                        OperationPanel(session: model.operationSession).id(ObjectIdentifier(model.operationSession))
                            .padding(.horizontal, 16).padding(.bottom, 12)
                    } else if appUpdates.showOperation, let session = appUpdates.operationSession {
                        AppUpdateOperationView(controller: appUpdates, session: session, language: model.language)
                            .id(ObjectIdentifier(session)).padding(.horizontal, 16).padding(.bottom, 12)
                    }
                }
                .navigationTitle(model.t(model.section.zh, model.section.en))
                .toolbar {
                    ToolbarItem {
                        if model.isDetecting { ProgressView().controlSize(.small) }
                        else { Button { Task { await model.detect() } } label: { Label(model.t("重新偵測", "Re-detect"), systemImage: "arrow.clockwise") }.disabled(model.hasRunningOperation) }
                    }
                }
            }
            .background(MoPanelBackdrop())
        }
        .groupBoxStyle(MoPanelGroupBoxStyle())
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: isSidebarCollapsed)
        .tint(MoPanelTheme.accent)
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
        .onChange(of: model.showOperation) { _, shown in
            if shown && !appUpdates.isBusy { appUpdates.showOperation = false }
        }
        .onChange(of: appUpdates.showOperation) { _, shown in
            if shown && !model.moleOperationInProgress { model.showOperation = false }
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
            Image(systemName: "externaldrive.badge.questionmark").font(.system(size: 60)).foregroundStyle(MoPanelTheme.accent)
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

struct ConfirmationPanel: View {
    @EnvironmentObject private var model: AppModel
    let pending: PendingOperation
    @State private var acknowledged = false
    @State private var removalText = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(pending.title, systemImage: "exclamationmark.shield.fill").font(.headline).foregroundStyle(.orange)
            ScrollView {
                Text(pending.details).font(.callout).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 100)
            ExecutionCommandView(command: pending.invocation.displayCommand)
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
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).moPanelGlass(cornerRadius: 18)
    }
}

struct HomebrewInstallConfirmationPanel: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(model.t("安裝官方 Mole CLI", "Install the official Mole CLI"), systemImage: "shippingbox").font(.headline)
            Text(model.t("Homebrew 將下載 Mole 與必要套件。安裝進度會顯示在本頁。", "Homebrew will download Mole and required dependencies. Installation progress stays on this page.")).font(.callout)
            ExecutionCommandView(command: (model.brewURL?.path ?? "brew") + " install mole")
            HStack {
                Button(model.t("取消", "Cancel")) { model.homebrewConfirmation = false }
                Spacer()
                Button(model.t("確認安裝", "Install")) {
                    model.homebrewConfirmation = false
                    model.installWithHomebrew()
                }.buttonStyle(.borderedProminent)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).moPanelGlass(cornerRadius: 18)
    }
}

struct ExecutionCommandView: View {
    @EnvironmentObject private var model: AppModel
    let command: String
    var body: some View {
        HStack(spacing: 10) {
            Text(model.t("執行指令", "Command")).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                Text(command).font(.caption.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
            }.frame(height: 22)
        }
        .padding(9)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityLabel(model.t("實際執行指令：", "Actual command: ") + command)
    }
}

struct OperationPanel: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: ManagedProcess
    @State private var stopping = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label(activityTitle, systemImage: statusSymbol).font(.headline)
                    .foregroundStyle(model.operationResult?.succeeded == true ? Color.green : Color.primary)
                    .lineLimit(2).layoutPriority(1)
                Spacer(minLength: 8)
                NativeActionButton(model.t(detailsExpanded ? "收合詳細資訊" : "詳細資訊", detailsExpanded ? "Hide Details" : "Details"), identifier: "mopanel.operation.details.toggle",
                                   systemImage: detailsExpanded ? "chevron.down" : "chevron.right") {
                    model.operationDetailsExpanded.toggle()
                }
                Button(model.t("儲存結果…", "Save Result…")) { model.exportOperationOutput() }.disabled(model.operationResult == nil)
                NativeActionButton(model.t("停止", "Stop"), identifier: "mopanel.operation.stop", destructive: true) {
                    stopping = true; session.cancel()
                }.disabled(!session.running || stopping)
                NativeActionButton(model.t("關閉", "Close"), identifier: "mopanel.operation.close", shortcut: .cancel) {
                    model.showOperation = false
                    model.updateMonitoringDemand()
                }.disabled(session.running)
            }
            if session.running {
                ProgressView().progressViewStyle(.linear).accessibilityLabel(activityTitle)
            } else if model.operationResult?.succeeded == true {
                ProgressView(value: 1).progressViewStyle(.linear).tint(.green)
            }
            ExecutionCommandView(command: model.operationCommand)
            if session.running && model.operationIsInteractive {
                Text(model.t("需要選取、確認或輸入密碼時，請展開「詳細資訊」操作。", "Expand Details when Mole needs a selection, confirmation or password."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            operationDetails
            if let result = model.operationResult {
                Text(result.cancelled ? model.t("作業已停止，已完成的變更不會自動還原。", "Stopped; completed changes are not automatically rolled back.")
                     : result.succeeded ? model.t("已完成。可展開詳細資訊查看結果。", "Completed. Expand Details to review the result.")
                     : model.t("作業未完整完成，請展開詳細資訊檢查原因。", "The operation did not complete. Expand Details to inspect the reason."))
                    .font(.caption).foregroundStyle(.secondary)
                if result.outputTruncated { Notice(text: model.t("輸出超過安全上限，作業已停止，不能將這次結果視為完整。", "Output exceeded the safety limit. The operation was stopped; this result is incomplete."), warning: true) }
            }
            if stopping && session.running { Notice(text: model.t("正在要求官方程序停止。Slim 若正在替換 App，會先完成安全步驟；已完成的變更不會回復。", "Waiting for the official process to stop. Slim finishes an in-progress app replacement safely. Completed changes are not rolled back."), warning: true) }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).moPanelGlass(cornerRadius: 18)
    }

    private var detailsExpanded: Bool { model.operationDetailsExpanded }

    private var operationDetails: some View {
        // Keep the terminal mounted while folded: its bounded in-memory screen
        // continues consuming PTY output without drawing or cancelling the child.
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if model.operationWasPreview {
                    Notice(text: model.t("這是預覽。實際執行前，Mole 會重新檢查項目與保護規則。", "This is a preview. Mole rechecks items and protection rules before an actual operation."))
                }
                if model.operationIsInteractive {
                    TerminalPanel(session: session, english: model.language == "en", isVisible: detailsExpanded, minimumTerminalHeight: 200)
                        .background(Color.black).clipShape(RoundedRectangle(cornerRadius: 10))
                    HStack {
                        terminalKey("←", "\u{1B}[D"); terminalKey("→", "\u{1B}[C"); terminalKey("Q", "q")
                        if model.operationKind == .uninstall { terminalKey(model.t("D／個人資料", "D / Personal data"), "d") }
                    }.controlSize(.small)
                    Text(model.t("互動畫面只保留在本次操作中；密碼不會被記錄，匯出只包含執行摘要。", "The interactive screen is kept only for this operation. Passwords are not logged; export contains an execution summary."))
                        .font(.caption).foregroundStyle(.secondary)
                } else if detailsExpanded {
                    Text(model.rawResult.isEmpty ? model.t("正在等待 Mole 輸出…", "Waiting for Mole output…") : model.rawResult)
                        .font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                if detailsExpanded, let result = model.operationResult {
                    Text("Exit \(result.exitCode)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    if model.operationIsInteractive, !result.stderrText.isEmpty {
                        Text(String(TerminalText.plain(result.stderrText).prefix(16_384)))
                            .font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.padding(.top, 4)
        }
        .frame(height: detailsExpanded ? 320 : 0, alignment: .top)
        .clipped().opacity(detailsExpanded ? 1 : 0).accessibilityHidden(!detailsExpanded)
    }

    private var statusSymbol: String {
        if session.running { return stopping ? "stop.circle" : "gearshape.2" }
        return model.operationResult?.succeeded == true ? "checkmark.circle.fill" : "exclamationmark.circle"
    }

    private var activityTitle: String {
        if stopping && session.running { return model.t("正在停止作業", "Stopping operation") }
        if let result = model.operationResult {
            if result.cancelled { return model.t("作業已停止", "Operation stopped") }
            if result.timedOut { return model.t("作業逾時", "Operation timed out") }
            return result.succeeded ? model.t("作業已完成", "Operation completed") : model.t("作業未完整完成", "Operation incomplete")
        }
        if model.operationWasPreview { return model.t("正在掃描與預覽", "Scanning and previewing") }
        switch model.operationKind {
        case .clean: return model.t("系統清理作業執行中", "Cleanup in progress")
        case .uninstall: return model.t("解除安裝作業執行中", "Uninstall operation in progress")
        case .optimize: return model.t("系統整理作業執行中", "Maintenance in progress")
        case .purge: return model.t("專案清理作業執行中", "Project cleanup in progress")
        case .installer: return model.t("安裝檔整理作業執行中", "Installer cleanup in progress")
        case .slim: return model.t("App 瘦身作業執行中", "App slimming in progress")
        case .analyze: return model.t("磁碟分析作業執行中", "Disk analysis in progress")
        case .update: return model.t("正在更新 Mole", "Updating Mole")
        case .remove: return model.t("正在移除 Mole", "Removing Mole")
        case .touchid: return model.t("正在處理 Touch ID 設定", "Configuring Touch ID")
        case .completion: return model.t("正在設定命令列補全", "Configuring shell completion")
        case .status: return model.t("系統監控執行中", "System monitoring in progress")
        case nil: return model.t("正在安裝 Mole", "Installing Mole")
        default: return model.t("Mole 作業執行中", "Mole operation in progress")
        }
    }
    private func terminalKey(_ title: String, _ key: String) -> some View {
        Button(title) { session.send(Data(key.utf8)) }.disabled(!session.running)
    }
}
