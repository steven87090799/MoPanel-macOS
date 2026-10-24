import SwiftUI
import AppKit
import Darwin

@main struct MoPanelApp: App {
    @NSApplicationDelegateAdaptor(MoPanelDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("MoPanel") {
            ContentView().environmentObject(model).preferredColorScheme(model.colorScheme)
                .frame(minWidth: 1000, minHeight: 700)
                .onAppear {
                    delegate.model = model
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate()
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
                Button(model.t("停止目前作業", "Stop Current Operation")) { model.cancelScan(); model.operationSession.cancel() }
                    .keyboardShortcut(".", modifiers: .command)
                Button(model.t("暫停監控", "Pause Monitoring")) { model.stopMonitoring() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
    }
}

@MainActor final class MoPanelDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
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
        if let model, model.hasRunningOperation, !model.fixtureMode {
            let alert = NSAlert()
            alert.messageText = model.t("停止作業並離開？", "Stop the operation and quit?")
            alert.informativeText = model.t("已完成的清理不會回復。MoPanel 將要求子程序停止；Slim 若正在替換 App，會等待安全步驟完成後才停止。", "Completed changes cannot be undone. MoPanel will request subprocess cancellation. If Slim is replacing an app, it waits for a safe stopping point.")
            alert.addButton(withTitle: model.t("停止並離開", "Stop and Quit"))
            alert.addButton(withTitle: model.t("繼續作業", "Keep Running"))
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        model?.shutdown()
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
}
