import SwiftUI
import AppKit
import MoPanelCore

struct MenuBarPanel: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var systemTools: SystemToolsController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if model.fixtureMode {
                    Text(model.t("合成測試資料", "Synthetic test data"))
                        .font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                }
                if let snapshot = model.status {
                    health(snapshot)
                    resourceCards(snapshot)
                    battery(snapshot)
                    if model.fixtureMode && model.applicationUsage.isEmpty { processes(snapshot) } else { ApplicationUsageList(compact: true).padding(12).moPanelGlass(cornerRadius: 16) }
                    Text(model.t("更新於 ", "Updated ") + DisplayFormat.timestamp(snapshot.collectedAt, language: model.language))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    Label("MoPanel", systemImage: "gauge.with.dots.needle.67percent").font(.title2.bold())
                    ContentUnavailableView(model.t("等待系統讀值", "Waiting for Readings"), systemImage: "waveform.path.ecg",
                                           description: Text(model.t("連接 Mole 後，這裡會顯示即時資源狀態。", "Connect Mole to see live system metrics.")))
                }
                controls
                Text(model.t("Mole Status + macOS 感測 · 與總覽同步", "Mole Status + macOS · Shared with Dashboard"))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }.padding(14)
        }
        .frame(width: 390, height: model.status == nil ? 360 : min(790, max(520, (NSScreen.main?.visibleFrame.height ?? 900) - 60)))
        .background(MoPanelBackdrop(translucent: true))
        .tint(MoPanelTheme.accent)
    }

    private func health(_ snapshot: StatusSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: "sun.max.fill").font(.title2).foregroundStyle(MoPanelTheme.accent)
                Text(snapshot.healthScore.flatMap { (0...100).contains($0) ? String($0) : nil } ?? "—")
                    .font(.system(size: 39, weight: .semibold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                Text(healthDescription(snapshot.healthScore, message: snapshot.healthScoreMsg)).font(.headline).foregroundStyle(.secondary)
                    .lineLimit(1).help(snapshot.healthScoreMsg ?? model.unavailable)
                Spacer()
                Circle().fill(model.monitoring ? Color.green : .secondary).frame(width: 6, height: 6)
                Text(model.monitoring ? model.t("即時", "Live") : model.t("暫停", "Paused"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 5) {
                chip(snapshot.hardware?.cpuModel?.replacingOccurrences(of: "Apple ", with: "") ?? "Mac")
                chip(snapshot.memory.total > 0 ? DisplayFormat.bytes(snapshot.memory.total) : "—")
                chip(snapshot.hardware?.osVersion ?? snapshot.platform ?? "—")
                chip(uptime(snapshot))
            }
        }
    }

    private func resourceCards(_ snapshot: StatusSnapshot) -> some View {
        let gpu = snapshot.gpu.first { value in value.usage.map { $0.isFinite && (0...100).contains($0) } == true } ?? snapshot.gpu.first
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            MonitorTile(title: "CPU", symbol: "cpu", tint: MoPanelTheme.positive,
                        badge: temperature(model.cpuTemperature),
                        value: percentage(snapshot.cpu.logicalCPU > 0 ? snapshot.cpu.usage : nil),
                        detail: model.t("平均負載 ", "Load ") + DisplayFormat.number(snapshot.cpu.load1, suffix: "")) {
                CoreUsageBars(values: Array((snapshot.cpu.perCore ?? []).prefix(16)))
            }
            MonitorTile(title: "GPU", symbol: "cpu", tint: MoPanelTheme.accent,
                        badge: temperature(model.gpuTemperature),
                        value: percentage(gpu.flatMap { model.gpuUsage($0) }),
                        detail: gpu?.name ?? model.t("尚無 GPU 讀值", "GPU data unavailable")) {
                MiniResourceTrend(observations: model.trends.map { $0.observation($0.gpu) }, color: MoPanelTheme.accent, ceiling: 100)
            }
            MonitorTile(title: model.t("記憶體", "Memory"), symbol: "memorychip", tint: MoPanelTheme.accent,
                        badge: model.memoryPressureText,
                        value: percentage(snapshot.memory.total > 0 ? snapshot.memory.usedPercent : nil),
                        detail: snapshot.memory.total > 0 ? DisplayFormat.bytes(snapshot.memory.used) + " / " + DisplayFormat.bytes(snapshot.memory.total) : model.unavailable) {
                MiniResourceTrend(observations: model.trends.map { $0.observation($0.memory) }, color: MoPanelTheme.accent, ceiling: 100)
            }
            storage(snapshot)
            network(snapshot)
            MonitorTile(title: model.t("風扇", "Fans"), symbol: "fan", tint: MoPanelTheme.accent,
                        badge: model.t("讀值", "Readout"),
                        value: model.fanSpeeds.isEmpty ? "—" : model.fanSpeeds.map { String(format: "%.0f", $0) }.joined(separator: " / ") + " RPM",
                        detail: model.fanSpeeds.isEmpty ? model.t("等待風扇讀值", "Waiting for fan readings") : "\(model.fanSpeeds.count) " + model.t("個風扇 · 實際轉速", "fans · Actual RPM")) {
                Text(model.t("唯讀硬體感測", "Read-only hardware sensors"))
                    .font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func storage(_ snapshot: StatusSnapshot) -> some View {
        let disk = snapshot.disks.first(where: { $0.mount == "/" }) ?? snapshot.disks.first
        let available: UInt64? = disk.flatMap { $0.total > 0 && $0.used <= $0.total ? $0.total - $0.used : nil }
        return MonitorTile(title: model.t("可用空間", "Free Space"), symbol: "internaldrive", tint: MoPanelTheme.chartSecondary,
                           badge: disk.map { DisplayFormat.storage($0.total) } ?? "—",
                           value: DisplayFormat.storage(available),
                           detail: disk.map { model.t("已用 ", "Used ") + DisplayFormat.storage($0.used) + " · " + percentage($0.usedPercent) } ?? model.unavailable) {
            if let disk, disk.total > 0, disk.usedPercent.isFinite, (0...100).contains(disk.usedPercent) {
                ProgressView(value: disk.usedPercent, total: 100).tint(MoPanelTheme.chartSecondary)
            } else {
                Text(model.t("尚無磁碟讀值", "Disk data unavailable")).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func network(_ snapshot: StatusSnapshot) -> some View {
        let network = model.networks.first(where: { $0.name == model.selectedNetwork }) ?? model.networks.first
        return MonitorTile(title: model.t("網路", "Network"), symbol: "network", tint: MoPanelTheme.chartSecondary,
                           badge: network.map { model.networkName($0.name) } ?? "—", value: MonitorFormat.rate(network?.rxRateMbs),
                           detail: "↑ " + MonitorFormat.rate(network?.txRateMbs)) {
            MiniResourceTrend(observations: model.trends.map { $0.observation($0.networkInterfaces[model.selectedNetwork]?.rxRateMbs) }, color: MoPanelTheme.chartSecondary)
        }
    }

    private func battery(_ snapshot: StatusSnapshot) -> some View {
        let battery = snapshot.batteries.first
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(model.t("電池", "Battery"), systemImage: "battery.100percent").font(.caption.weight(.semibold))
                Spacer()
                Text(battery?.health ?? model.t("未提供健康度", "Health unavailable")).font(.caption2).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(percentage(battery?.percent)).font(.system(size: 29, weight: .semibold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                Spacer()
                Text(batteryState(battery?.status)).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(12).moPanelGlass(cornerRadius: 16)
    }

    private func processes(_ snapshot: StatusSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(model.t("高佔用程式", "Top Processes")).font(.caption.weight(.semibold))
                Spacer()
                Text(model.t("記憶體", "Memory")).frame(width: 75, alignment: .trailing)
                Text("CPU").frame(width: 48, alignment: .trailing)
            }.font(.caption2).foregroundStyle(.secondary)
            ForEach(Array(snapshot.topProcesses.sorted { $0.cpu > $1.cpu }.prefix(5))) { process in
                HStack(spacing: 7) {
                    Text(process.name).font(.caption.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(DisplayFormat.bytes(process.memoryBytes)).frame(width: 75, alignment: .trailing)
                    Text(DisplayFormat.percent(process.cpu)).frame(width: 48, alignment: .trailing)
                }.font(.caption2).monospacedDigit()
            }
            if snapshot.topProcesses.isEmpty {
                Text(model.t("尚無行程讀值", "No process readings")).font(.caption).foregroundStyle(.secondary)
            }
            if snapshot.processStale == true {
                Text(model.t("行程清單為較早的樣本", "Process list is an older sample")).font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(12).moPanelGlass(cornerRadius: 16)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack {
                Button { show(.dashboard) } label: { Label(model.t("總覽", "Dashboard"), systemImage: "square.grid.2x2") }
                    .buttonStyle(.glass)
                Spacer()
                Button(systemTools.assertionIsActive ? model.t("保持喚醒中", "Keep Awake On") : model.t("系統工具", "System Tools")) { show(.tools) }
            }
            HStack {
                Button(model.monitoringPaused ? model.t("繼續監控", "Resume") : model.t("暫停監控", "Pause")) {
                    if model.monitoringPaused { model.resumeMonitoring() } else { model.pauseMonitoring() }
                }.disabled(model.installation == nil || model.hasRunningOperation)
                Spacer()
                Button(model.t("結束 MoPanel", "Quit MoPanel")) { NSApp.terminate(nil) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            if model.hasRunningOperation {
                HStack {
                    Text(model.t("作業執行中，監控暫停。", "Monitoring pauses during an operation.")).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button(model.t("查看進度", "View Progress")) { show(model.nativeReviewSection ?? model.section) }
                }
            }
        }.buttonStyle(.bordered).font(.caption)
    }

    private func chip(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .medium)).lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .help(text)
    }
    private func percentage(_ value: Double?) -> String {
        guard let value, value.isFinite, (0...100).contains(value) else { return "—" }
        return String(format: "%.0f%%", value)
    }
    private func temperature(_ value: Double?) -> String {
        ThermalStatus.availablePositive(value).map { String(format: "%.0f°C", $0) } ?? "—"
    }
    private func fanSpeed(_ thermal: ThermalStatus?) -> String {
        guard let thermal, let speed = thermal.fanSpeed,
              speed > 0 || (speed == 0 && (thermal.fanCount ?? 0) > 0) else { return "—" }
        return speed.formatted() + " RPM"
    }
    private func rate(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return value < 1 ? String(format: "%.0f KB/s", value * 1000) : String(format: "%.1f MB/s", value)
    }
    private func memoryPressure(_ value: String?) -> String {
        switch value?.lowercased() {
        case "normal", "nominal": return model.t("壓力正常", "Normal")
        case "warn", "warning": return model.t("壓力偏高", "Elevated")
        case "critical": return model.t("壓力過高", "High pressure")
        default: return model.t("未提供壓力", "Pressure unavailable")
        }
    }
    private func healthDescription(_ score: Int?, message: String?) -> String {
        guard let score, (0...100).contains(score) else { return model.t("未提供", "Unavailable") }
        switch message?.components(separatedBy: ":").first?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "good", "excellent", "healthy", "normal": return model.t("良好", "Good")
        case "fair", "warning", "moderate": return model.t("需留意", "Fair")
        case "poor", "critical", "needs attention": return model.t("需關注", "Needs attention")
        default: return model.t("CLI 狀態分數", "CLI Score")
        }
    }
    private func uptime(_ snapshot: StatusSnapshot) -> String {
        guard let seconds = snapshot.uptimeSeconds else { return snapshot.uptime ?? "—" }
        let days = seconds / 86400, hours = seconds % 86400 / 3600
        return model.language == "en" ? "\(days)d \(hours)h" : "\(days) 天 \(hours) 小時"
    }
    private func batteryState(_ value: String?) -> String {
        switch value?.lowercased() {
        case "charged", "full": return model.t("已充飽", "Charged")
        case "charging": return model.t("充電中", "Charging")
        case "discharging": return model.t("使用電池", "On battery")
        default: return value ?? model.t("尚無電池讀值", "Battery data unavailable")
        }
    }
    private func show(_ section: AppSection) {
        model.section = section
        openWindow(id: "main")
        NSApp.activate()
        NSApp.windows.first(where: { $0.styleMask.contains(.titled) && !$0.isSheet })?.makeKeyAndOrderFront(nil)
    }
}

private struct MonitorTile<Chart: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    let badge: String
    let value: String
    let detail: String
    @ViewBuilder let chart: () -> Chart
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Label(title, systemImage: symbol).foregroundStyle(tint).font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                Text(badge).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.65).contentTransition(.numericText())
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: value)
            chart().frame(height: 18)
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).help(detail)
        }.padding(10).frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .moPanelGlass(cornerRadius: 16)
    }
}

private struct CoreUsageBars: View {
    let values: [Double]
    var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(colors: [MoPanelTheme.positive.opacity(0.9), MoPanelTheme.positive.opacity(0.35)], startPoint: .top, endPoint: .bottom))
                        .frame(height: value.isFinite ? proxy.size.height * min(max(value, 0), 100) / 100 : 0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
        }.accessibilityLabel("CPU")
    }
}

private struct MiniResourceTrend: View {
    let observations: [ResourceTrendObservation]
    let color: Color
    var ceiling: Double? = nil
    var body: some View {
        GeometryReader { proxy in
            let plot = ResourceTrendPlot.make(Array(observations.suffix(40)))
            let maximum = ceiling ?? max(plot.points.map(\.value).max() ?? 0, 0.001)
            if !plot.points.isEmpty, let domain = plot.dateDomain {
                Path { path in
                    var previousSegment: Int?
                    let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
                    for sample in plot.points {
                        let point = CGPoint(x: proxy.size.width * sample.date.timeIntervalSince(domain.lowerBound) / span,
                                            y: proxy.size.height * (1 - min(sample.value / maximum, 1)))
                        if previousSegment == sample.segment { path.addLine(to: point) } else { path.move(to: point) }
                        if sample.isolated { path.addEllipse(in: CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)) }
                        previousSegment = sample.segment
                    }
                }.stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            } else {
                Text("—").font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.accessibilityHidden(true)
    }
}
