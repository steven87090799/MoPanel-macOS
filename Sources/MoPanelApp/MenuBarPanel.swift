import SwiftUI
import AppKit

struct MenuBarPanel: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Label("MoPanel", systemImage: "gauge.with.dots.needle.67percent").font(.headline); Spacer(); Text(model.monitoring ? model.t("即時", "Live") : model.t("暫停", "Paused")).font(.caption).foregroundStyle(.secondary) }
            if let snapshot = model.status {
                LabeledContent("CPU", value: snapshot.cpu.logicalCPU > 0 ? DisplayFormat.percent(snapshot.cpu.usage) : model.unavailable)
                LabeledContent(model.t("記憶體", "Memory"), value: snapshot.memory.total > 0 ? DisplayFormat.bytes(snapshot.memory.used) : model.unavailable)
                LabeledContent(model.t("健康分數", "Health"), value: snapshot.healthScore.map { "\($0) / 100" } ?? model.unavailable)
                if let network = snapshot.network.first(where: { $0.name == model.selectedNetwork }) {
                    LabeledContent("↓ " + network.name, value: DisplayFormat.number(network.rxRateMbs, suffix: " MB/s"))
                    LabeledContent("↑ " + network.name, value: DisplayFormat.number(network.txRateMbs, suffix: " MB/s"))
                }
                Text(snapshot.collectedAt).font(.caption2.monospaced()).foregroundStyle(.secondary)
            } else { Text(model.t("尚無讀值；請先連接 Mole CLI。", "No readings yet. Connect Mole CLI first.")).foregroundStyle(.secondary) }
            if model.hasRunningOperation { Text(model.t("其他作業執行中，監控暫停。", "Monitoring pauses during another operation.")).font(.caption) }
            Divider()
            HStack {
                Button(model.t("開啟總覽", "Dashboard")) { show(.dashboard) }
                Spacer()
                Button(model.monitoringPaused ? model.t("繼續監控", "Resume") : model.t("暫停監控", "Pause")) {
                    if model.monitoringPaused { model.resumeMonitoring() } else { model.pauseMonitoring() }
                }.disabled(model.installation == nil || model.hasRunningOperation)
            }
            HStack {
                Button(model.t("系統工具", "System Tools")) { show(.tools) }
                Spacer()
                Button(model.t("結束 MoPanel", "Quit MoPanel")) { NSApp.terminate(nil) }
            }
            Text(model.t("MoPanel 新實作。與總覽共用同一個 Mole 串流；關閉最後視窗或結束 App 就會停止。", "Added by MoPanel. Shares one Mole stream with Dashboard and stops when the last window or the app closes."))
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(18).frame(width: 355)
    }
    private func show(_ section: AppSection) {
        model.section = section
        NSApp.activate()
        NSApp.windows.first(where: { $0.styleMask.contains(.titled) && !$0.isSheet })?.makeKeyAndOrderFront(nil)
    }
}
