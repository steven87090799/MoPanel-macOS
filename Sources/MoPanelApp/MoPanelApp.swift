import SwiftUI
import AppKit
import Darwin

@main struct MoPanelApp: App {
    @NSApplicationDelegateAdaptor(MoPanelDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @StateObject private var systemTools = SystemToolsController()
    @StateObject private var appUpdates = AppUpdatesController()
    @StateObject private var startup = StartupController()
    @StateObject private var worktrees = GitWorktreeController()
    var body: some Scene {
        WindowGroup("MoPanel") {
            ContentView().environmentObject(model).environmentObject(systemTools)
                .environmentObject(appUpdates).environmentObject(startup).environmentObject(worktrees)
                .preferredColorScheme(model.colorScheme)
                .frame(minWidth: 1000, minHeight: 700)
                .onAppear {
                    // Bind references before nested weak captures; do not capture
                    // SwiftUI's StateObject storage through an outer App value.
                    let appModel = model, toolsController = systemTools
                    let updatesController = appUpdates, startupController = startup
                    let worktreeController = worktrees
                    delegate.model = appModel
                    delegate.systemTools = toolsController
                    delegate.appUpdates = updatesController
                    delegate.startup = startupController
                    delegate.worktrees = worktreeController
                    toolsController.language = appModel.language
                    if worktreeController.language != appModel.language { worktreeController.language = appModel.language }
                    appModel.nativeOperationInProgress = { [weak toolsController, weak updatesController, weak startupController, weak worktreeController] in
                        toolsController?.ejectingVolumeID != nil || updatesController?.isBusy == true || startupController?.isBusy == true || worktreeController?.isBusy == true
                    }
                    toolsController.externalOperationInProgress = { [weak appModel, weak updatesController, weak startupController, weak worktreeController] in
                        appModel?.moleOperationInProgress == true || appModel?.isDetecting == true || updatesController?.isBusy == true || startupController?.isBusy == true || worktreeController?.isBusy == true
                    }
                    updatesController.externalOperationInProgress = { [weak appModel, weak toolsController, weak startupController, weak worktreeController] in
                        appModel?.moleOperationInProgress == true || appModel?.isDetecting == true || toolsController?.ejectingVolumeID != nil || startupController?.isBusy == true || worktreeController?.isBusy == true
                    }
                    startupController.externalOperationInProgress = { [weak appModel, weak toolsController, weak updatesController, weak worktreeController] in
                        appModel?.moleOperationInProgress == true || appModel?.isDetecting == true || toolsController?.ejectingVolumeID != nil || updatesController?.isBusy == true || worktreeController?.isBusy == true
                    }
                    worktreeController.externalOperationInProgress = { [weak appModel, weak toolsController, weak updatesController, weak startupController] in
                        appModel?.moleOperationInProgress == true || appModel?.isDetecting == true || toolsController?.ejectingVolumeID != nil || updatesController?.isBusy == true || startupController?.isBusy == true
                    }
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate()
                }
                // A @Published publisher emits immediately on subscription.
                // Forwarding that initial emission back to this App's model
                // can invalidate the view while SwiftUI is installing it.
                // Notify dependent views only for actual state transitions;
                // action guards still query the synchronous callbacks above.
                .onChange(of: systemTools.ejectingVolumeID) { _, _ in nativeOperationChanged() }
                .onChange(of: appUpdates.isBusy) { _, _ in nativeOperationChanged() }
                .onChange(of: startup.isBusy) { _, _ in nativeOperationChanged() }
                .onChange(of: worktrees.isBusy) { _, _ in nativeOperationChanged() }
                .onChange(of: model.installation?.fingerprint) { _, _ in
                    systemTools.additionalProtectedPaths = [model.installation?.executable.path, model.installation?.resourceLocation].compactMap { $0 }
                }
                .onChange(of: model.language) { _, language in
                    systemTools.language = language; appUpdates.language = language; startup.language = language
                    if worktrees.language != language { worktrees.language = language }
                }
        }
        .defaultSize(width: 1260, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appSettings) {
                Button(model.t("開啟設定", "Settings")) { model.section = .settings }.keyboardShortcut(",")
                Button(model.t("重新偵測 Mole", "Re-detect Mole")) { Task { await model.detect() } }.keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandMenu(model.t("作業", "Operation")) {
                Button(model.t("停止目前作業", "Stop Current Operation")) {
                    model.cancelScan(); model.operationSession.cancel(); startup.cancel(); appUpdates.requestCancellation(); worktrees.requestCancellation()
                }
                    .keyboardShortcut(".", modifiers: .command)
                Button(model.t("暫停監控", "Pause Monitoring")) { model.pauseMonitoring() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
        MenuBarExtra(isInserted: menuBarInsertion) {
            MenuBarPanel().environmentObject(model).environmentObject(systemTools).preferredColorScheme(model.colorScheme)
        } label: {
            Label {
                if model.monitoring, let cpu = model.status?.cpu.usage { Text("CPU " + DisplayFormat.percent(cpu)) }
                else { Text("MoPanel") }
            } icon: { Image(systemName: "gauge.with.dots.needle.67percent") }
        }.menuBarExtraStyle(.window)
    }
    private var menuBarInsertion: Binding<Bool> {
        let appModel = model
        return Binding(get: { appModel.menuBarEnabled }, set: { inserted in
            // Scene reconciliation can write its existing value back. Avoid
            // publishing a no-op change into the App graph being reconciled.
            guard appModel.menuBarEnabled != inserted else { return }
            appModel.menuBarEnabled = inserted
        })
    }
    private func nativeOperationChanged() {
        model.objectWillChange.send()
        if !model.isTestLaunch { Task { @MainActor in model.updateMonitoringDemand() } }
    }
}

@MainActor final class MoPanelDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    weak var systemTools: SystemToolsController?
    weak var appUpdates: AppUpdatesController?
    weak var startup: StartupController?
    weak var worktrees: GitWorktreeController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard geteuid() == 0 else { return }
        let alert = NSAlert()
        alert.messageText = "MoPanel 不應以 root 執行 / Do not run MoPanel as root"
        alert.informativeText = "請以一般使用者開啟。需要權限時由官方 Mole 個別要求授權。\nOpen the app as your regular user; Mole requests privileges only when needed."
        alert.runModal()
        NSApp.terminate(nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Once the last content window has closed, cancelling termination would
        // leave a windowless cleaner. Closing that window therefore stops the
        // app; a normal Quit while a window remains can still be cancelled.
        let hasContentWindow = sender.windows.contains { $0.isVisible && !$0.isSheet && $0.styleMask.contains(.titled) }
        if let model, model.hasRunningOperation, !model.fixtureMode, hasContentWindow {
            let alert = NSAlert()
            alert.messageText = model.t("停止作業並離開？", "Stop the operation and quit?")
            alert.informativeText = model.t("已完成的變更不會自動回復。MoPanel 將要求受控子程序停止；Slim、Homebrew 更新或 Git 工作目錄作業可能需要等待安全步驟完成。Git 的保留分支不會自動刪除。", "Completed changes are not automatically reversed. MoPanel requests cancellation of controlled subprocesses. Slim, Homebrew updates and Git worktree operations may need to finish a safe step. Git recovery branches are not deleted automatically.")
            alert.addButton(withTitle: model.t("停止並離開", "Stop and Quit"))
            alert.addButton(withTitle: model.t("繼續作業", "Keep Running"))
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        systemTools?.cleanupForQuit()
        appUpdates?.shutdown()
        startup?.cleanupForQuit()
        worktrees?.shutdown()
        model?.shutdown()
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        systemTools?.cleanupForQuit(); appUpdates?.shutdown(); startup?.cleanupForQuit(); worktrees?.shutdown(); model?.shutdown()
    }
}
