import SwiftUI
import AppKit
import Darwin

@main struct MoPanelApp: App {
    @NSApplicationDelegateAdaptor(MoPanelDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @StateObject private var systemTools = SystemToolsController()
    @StateObject private var appUpdates = AppUpdatesController()
    @StateObject private var startup = StartupController()
    var body: some Scene {
        WindowGroup("MoPanel") {
            ContentView().environmentObject(model).environmentObject(systemTools)
                .environmentObject(appUpdates).environmentObject(startup).preferredColorScheme(model.colorScheme)
                .frame(minWidth: 1000, minHeight: 700)
                .onAppear {
                    // Bind references before nested weak captures; do not capture
                    // SwiftUI's StateObject storage through an outer App value.
                    let appModel = model, toolsController = systemTools
                    let updatesController = appUpdates, startupController = startup
                    delegate.model = appModel
                    delegate.systemTools = toolsController
                    delegate.appUpdates = updatesController
                    delegate.startup = startupController
                    toolsController.language = appModel.language
                    appModel.nativeOperationInProgress = { [weak toolsController, weak updatesController, weak startupController] in
                        toolsController?.ejectingVolumeID != nil || updatesController?.isBusy == true || startupController?.isBusy == true
                    }
                    toolsController.externalOperationInProgress = { [weak appModel, weak updatesController, weak startupController] in
                        appModel?.moleOperationInProgress == true || appModel?.isDetecting == true || updatesController?.isBusy == true || startupController?.isBusy == true
                    }
                    updatesController.externalOperationInProgress = { [weak appModel, weak toolsController, weak startupController] in
                        appModel?.moleOperationInProgress == true || appModel?.isDetecting == true || toolsController?.ejectingVolumeID != nil || startupController?.isBusy == true
                    }
                    startupController.externalOperationInProgress = { [weak appModel, weak toolsController, weak updatesController] in
                        appModel?.moleOperationInProgress == true || appModel?.isDetecting == true || toolsController?.ejectingVolumeID != nil || updatesController?.isBusy == true
                    }
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate()
                }
                .onReceive(systemTools.$ejectingVolumeID) { _ in nativeOperationChanged() }
                .onReceive(appUpdates.$isBusy) { _ in nativeOperationChanged() }
                .onReceive(startup.$isBusy) { _ in nativeOperationChanged() }
                .onChange(of: model.installation?.fingerprint) { _, _ in
                    systemTools.additionalProtectedPaths = [model.installation?.executable.path, model.installation?.resourceLocation].compactMap { $0 }
                }
                .onChange(of: model.language) { _, language in systemTools.language = language; appUpdates.language = language; startup.language = language }
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
                    model.cancelScan(); model.operationSession.cancel(); startup.cancel(); appUpdates.requestCancellation()
                }
                    .keyboardShortcut(".", modifiers: .command)
                Button(model.t("暫停監控", "Pause Monitoring")) { model.pauseMonitoring() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
        MenuBarExtra(isInserted: $model.menuBarEnabled) {
            MenuBarPanel().environmentObject(model).preferredColorScheme(model.colorScheme)
        } label: {
            Label {
                if model.monitoring, let cpu = model.status?.cpu.usage { Text("CPU " + DisplayFormat.percent(cpu)) }
                else { Text("MoPanel") }
            } icon: { Image(systemName: "gauge.with.dots.needle.67percent") }
        }.menuBarExtraStyle(.window)
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
            alert.informativeText = model.t("已完成的變更不會自動回復。MoPanel 將要求受控子程序停止；Slim 與 Homebrew 更新若正在替換或回復 App，可能需要等待安全步驟完成。", "Completed changes are not automatically reversed. MoPanel requests cancellation of controlled subprocesses. Slim and Homebrew updates may need to finish an app replacement or rollback safely.")
            alert.addButton(withTitle: model.t("停止並離開", "Stop and Quit"))
            alert.addButton(withTitle: model.t("繼續作業", "Keep Running"))
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        systemTools?.cleanupForQuit()
        appUpdates?.shutdown()
        startup?.cleanupForQuit()
        model?.shutdown()
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        systemTools?.cleanupForQuit(); appUpdates?.shutdown(); startup?.cleanupForQuit(); model?.shutdown()
    }
}
