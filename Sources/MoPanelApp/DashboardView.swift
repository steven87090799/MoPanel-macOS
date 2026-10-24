import SwiftUI
import Charts
import MoPanelCore

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeading(title: model.t("看見 Mac 的當下", "Your Mac, right now"), subtitle: model.t("資料由官方 Mole Status 提供。離開此頁時停止監控；若自行開啟選單列監控，則共用同一個串流繼續更新。", "Live data from Mole Status. Monitoring pauses away from this page unless you enable menu bar monitoring, which shares the same stream."), symbol: "waveform.path.ecg")
                HStack {
                    Label(model.monitoring ? model.t("即時監控中", "Live") : model.t("監控已暫停", "Paused"), systemImage: model.monitoring ? "record.circle" : "pause.circle")
                        .foregroundStyle(model.monitoring ? Color.teal : Color.secondary)
                    if let collected = model.status?.collectedAt { Text(collected).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button(model.t("單次快照", "Snapshot")) { Task { await model.takeSnapshot() } }.disabled(!model.canStart)
                        .accessibilityIdentifier("mopanel.dashboard.snapshot")
                    Button(model.monitoring ? model.t("暫停", "Pause") : model.t("開始監控", "Start Monitoring")) {
                        if model.monitoring { model.pauseMonitoring() } else { model.resumeMonitoring() }
                    }.buttonStyle(.borderedProminent).disabled(model.installation == nil || model.hasRunningOperation)
                }
                if let s = model.status {
                    summary(s)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                        TrendCard(title: "CPU", unit: "%", metric: .cpu)
                        TrendCard(title: model.t("記憶體", "Memory"), unit: "%", metric: .memory)
                        TrendCard(title: model.t("磁碟讀寫", "Disk I/O"), unit: "MB/s", metric: .disk)
                        TrendCard(title: model.t("網路", "Network") + " · " + model.selectedNetwork, unit: "MB/s", metric: .network)
                    }
                    if !model.monitorWarnings.isEmpty {
                        Notice(text: model.t("部分指標可能無法取得；官方診斷：\n", "Some metrics may be unavailable. Mole diagnostics:\n") + model.monitorWarnings, warning: true)
                    }
                    detail(s)
                } else {
                    ContentUnavailableView(model.t("等待第一筆真實資料", "Waiting for real metrics"), systemImage: "waveform.path.ecg", description: Text(model.t("可開始監控或取得單次快照；尚未提供的數據不會以假數字代替。", "Start monitoring or request a snapshot. Missing data is never replaced by invented values.")))
                }
            }.padding(26)
        }
        .onChange(of: model.selectedNetwork) { _, _ in model.trends.removeAll() }
    }

    private func summary(_ s: StatusSnapshot) -> some View {
        GlassEffectContainer(spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                GlassCard {
                    Text(model.t("系統健康", "System Health")).font(.headline)
                    HStack(alignment: .firstTextBaseline) {
                        Text(s.healthScore.map(String.init) ?? "—").font(.system(size: 54, weight: .light, design: .rounded))
                        Text("/ 100").foregroundStyle(.secondary)
                    }
                    Text(s.healthScoreMsg ?? model.unavailable).font(.caption).foregroundStyle(.secondary)
                    Text(s.hardware?.model ?? s.host ?? model.unavailable).font(.callout)
                    Text(s.hardware?.cpuModel ?? "").font(.caption).foregroundStyle(.secondary)
                }
                GlassCard {
                    Text("CPU").font(.headline)
                    Text(s.cpu.logicalCPU > 0 ? DisplayFormat.percent(s.cpu.usage) : "—").font(.system(size: 42, weight: .light, design: .rounded))
                    Text("\(s.cpu.logicalCPU) " + model.t("邏輯核心", "logical cores")).font(.callout).foregroundStyle(.secondary)
                    Text(model.t("開機時間：", "Uptime: ") + (s.uptime ?? model.unavailable)).font(.caption)
                }
                GlassCard {
                    Text(model.t("記憶體", "Memory")).font(.headline)
                    Text(s.memory.total > 0 ? DisplayFormat.bytes(s.memory.used) : "—").font(.system(size: 36, weight: .light, design: .rounded))
                    Text(model.t("可用：", "Available: ") + (s.memory.total > 0 ? DisplayFormat.bytes(s.memory.available) : model.unavailable)).foregroundStyle(.secondary)
                    Text(model.t("壓力：", "Pressure: ") + (s.memory.pressure?.isEmpty == false ? s.memory.pressure! : model.unavailable)).font(.caption)
                    Text("Swap " + DisplayFormat.bytes(s.memory.swapUsed) + " / " + DisplayFormat.bytes(s.memory.swapTotal)).font(.caption)
                }
            }
        }
    }

    @ViewBuilder private func detail(_ s: StatusSnapshot) -> some View {
        GroupBox(model.t("各核心使用率", "Per-core Usage")) {
            if let cores = s.cpu.perCore, !cores.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145))], spacing: 12) {
                    ForEach(Array(cores.enumerated()), id: \.offset) { index, value in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text("Core \(index + 1)"); Spacer(); Text(DisplayFormat.percent(value)) }.font(.caption)
                            ProgressView(value: min(max(value, 0), 100), total: 100)
                        }.padding(6)
                    }
                }.padding(8)
                if s.cpu.perCoreEstimated == true { Text(model.t("官方標示各核心數值為估計值。", "Mole marks per-core values as estimates.")).font(.caption).foregroundStyle(.secondary) }
            } else { unavailableRow() }
        }
        GroupBox(model.t("磁碟與檔案系統", "Disks and Filesystems")) {
            VStack(spacing: 12) {
                ForEach(s.disks) { disk in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label(disk.mount, systemImage: disk.external == true ? "externaldrive" : "internaldrive")
                            Spacer()
                            Text(disk.total > 0 ? DisplayFormat.bytes(disk.used) + " / " + DisplayFormat.bytes(disk.total) : model.unavailable).font(.callout.monospacedDigit())
                        }
                        if disk.total > 0 { ProgressView(value: min(max(disk.usedPercent, 0), 100), total: 100) }
                        HStack { Text(disk.fstype ?? ""); Spacer(); Text("SMART: " + (disk.smartStatus?.isEmpty == false ? disk.smartStatus! : model.unavailable)) }.font(.caption).foregroundStyle(.secondary)
                    }
                }
                if s.disks.isEmpty { unavailableRow() }
            }.padding(10)
        }
        GroupBox(model.t("網路介面", "Network Interfaces")) {
            VStack(alignment: .leading, spacing: 10) {
                if s.network.isEmpty { unavailableRow() }
                else {
                    Picker(model.t("圖表介面", "Chart Interface"), selection: $model.selectedNetwork) {
                        ForEach(s.network) { network in Text(network.name).tag(network.name) }
                    }.pickerStyle(.segmented)
                    ForEach(s.network) { network in
                        HStack { Text(network.name).font(.body.monospaced()); Text(network.ip ?? "").foregroundStyle(.secondary); Spacer(); Text("↓ " + DisplayFormat.number(network.rxRateMbs, suffix: " MB/s")); Text("↑ " + DisplayFormat.number(network.txRateMbs, suffix: " MB/s")) }.font(.callout)
                    }
                    Text(model.t("各介面分開顯示，不將 VPN 與實體網卡重複相加。", "Interfaces are shown separately; VPN and physical traffic are not added twice.")).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(10)
        }
        GroupBox(model.t("電池、溫度與功耗", "Battery, Thermals and Power")) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(s.batteries.enumerated()), id: \.offset) { index, battery in
                    LabeledContent(model.t("電池", "Battery") + " \(index + 1)", value: DisplayFormat.percent(battery.percent) + " · " + (battery.status ?? model.unavailable))
                    LabeledContent(model.t("健康／循環", "Health / Cycles"), value: (battery.health ?? "—") + " / " + (battery.cycleCount.map(String.init) ?? "—"))
                    LabeledContent(model.t("最大容量", "Maximum Capacity"), value: battery.capacity.map { "\($0)%" } ?? model.unavailable)
                }
                if s.batteries.isEmpty { LabeledContent(model.t("電池", "Battery"), value: model.unavailable) }
                LabeledContent("CPU", value: positive(s.thermal?.cpuTemp, suffix: " °C"))
                LabeledContent("GPU", value: positive(s.thermal?.gpuTemp, suffix: " °C"))
                LabeledContent(model.t("電池溫度", "Battery Temperature"), value: positive(s.thermal?.batteryTemp, suffix: " °C"))
                LabeledContent(model.t("系統功耗", "System Power"), value: positive(s.thermal?.systemPower, suffix: " W"))
                LabeledContent(model.t("電源供應器", "Power Adapter"), value: positive(s.thermal?.adapterPower, suffix: " W"))
                LabeledContent(model.t("風扇讀值", "Fan Reading"), value: (s.thermal?.fanCount ?? 0) > 0 ? "\(s.thermal?.fanSpeed ?? 0) RPM" : model.unavailable)
                ForEach(Array(s.sensors.enumerated()), id: \.offset) { _, sensor in LabeledContent(sensor.label, value: DisplayFormat.number(sensor.value, suffix: " " + sensor.unit)) }
                Text(model.t("僅顯示 CLI 提供的硬體讀值，不提供風扇或充電控制。", "Displays CLI-provided hardware readings only.")).font(.caption).foregroundStyle(.secondary)
            }.padding(10)
        }
        GroupBox(model.t("高資源使用率行程", "Top Processes")) {
            ProcessInspectorView(snapshot: s).padding(10)
        }
        DisclosureGroup(model.t("GPU 與其他硬體讀值", "GPU and Other Hardware")) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(s.gpu.enumerated()), id: \.offset) { _, gpu in
                    LabeledContent(gpu.name ?? "GPU", value: DisplayFormat.percent(gpu.usage))
                    if let note = gpu.note, !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
                }
                ForEach(Array(s.bluetooth.enumerated()), id: \.offset) { _, device in
                    LabeledContent(device.name, value: device.battery ?? model.unavailable)
                }
                Button(model.t("查看官方 JSON 快照", "View Official JSON Snapshot")) { model.request(.status, options: [.json]) }
            }.padding(10)
        }
    }
    private func positive(_ value: Double?, suffix: String) -> String { ThermalStatus.availablePositive(value).map { DisplayFormat.number($0, suffix: suffix) } ?? model.unavailable }
    private func unavailableRow() -> some View { Text(model.unavailable).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(10) }
}

enum TrendMetric { case cpu, memory, disk, network }
struct TrendPoint: Identifiable {
    let id: String
    let date: Date
    let value: Double
    let series: String
}
struct TrendCard: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    let unit: String
    let metric: TrendMetric
    var points: [TrendPoint] {
        model.trends.flatMap { sample -> [TrendPoint] in
            let pairs: [(String, Double?)]
            switch metric {
            case .cpu: pairs = [("CPU", sample.cpu)]
            case .memory: pairs = [(model.t("記憶體", "Memory"), sample.memory)]
            case .disk: pairs = [(model.t("讀取", "Read"), sample.diskRead), (model.t("寫入", "Write"), sample.diskWrite)]
            case .network: pairs = [(model.t("下載", "Download"), sample.down), (model.t("上傳", "Upload"), sample.up)]
            }
            return pairs.compactMap { name, value in value.map { TrendPoint(id: sample.id.uuidString + name, date: sample.date, value: $0, series: name) } }
        }
    }
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text(title).font(.headline); Spacer(); Text(unit).font(.caption).foregroundStyle(.secondary) }
                if points.isEmpty { Text(model.unavailable).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 125) }
                else {
                    Chart(points) { point in
                        LineMark(x: .value(model.t("時間", "Time"), point.date), y: .value(unit, point.value)).foregroundStyle(by: .value(model.t("指標", "Metric"), point.series)).interpolationMethod(.linear)
                    }.chartForegroundStyleScale(range: [Color.teal, Color.blue]).chartXAxis(.hidden).frame(height: 125)
                        .accessibilityLabel(title + " " + model.t("最近最多 120 筆讀值", "up to 120 recent samples"))
                }
            }.padding(8)
        }
    }
}
