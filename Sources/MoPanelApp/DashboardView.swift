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
                        .foregroundStyle(model.monitoring ? MoPanelTheme.accent : Color.secondary)
                    if let collected = model.status?.collectedAt {
                        Text(model.t("更新於 ", "Updated ") + DisplayFormat.timestamp(collected, language: model.language))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    NativeActionButton(model.t("單次快照", "Snapshot"), identifier: "mopanel.dashboard.snapshot") {
                        Task { await model.takeSnapshot() }
                    }.disabled(!model.canStart)
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
        GlassEffectContainer(spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                GlassCard(minHeight: 208) {
                    Text(model.t("系統健康", "System Health")).font(.headline)
                    HStack(alignment: .firstTextBaseline) {
                        Text(s.healthScore.map(String.init) ?? "—").font(.system(size: 42, weight: .light, design: .rounded))
                        Text("/ 100").foregroundStyle(.secondary)
                    }
                    Text(s.healthScoreMsg ?? model.unavailable).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(s.hardware?.model ?? s.host ?? model.unavailable).font(.callout).lineLimit(1).truncationMode(.middle)
                    Text(s.hardware?.cpuModel ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                GlassCard(minHeight: 208) {
                    Text("CPU").font(.headline)
                    Text(s.cpu.logicalCPU > 0 ? DisplayFormat.percent(s.cpu.usage) : "—").font(.system(size: 42, weight: .light, design: .rounded))
                    Text("\(s.cpu.logicalCPU) " + model.t("邏輯核心", "logical cores")).font(.callout).foregroundStyle(.secondary)
                    Text(model.t("開機時間：", "Uptime: ") + (s.uptime ?? model.unavailable)).font(.caption).lineLimit(1)
                }
                GlassCard(minHeight: 208) {
                    Text(model.t("記憶體", "Memory")).font(.headline)
                    Text(s.memory.total > 0 ? DisplayFormat.bytes(s.memory.used) : "—").font(.system(size: 42, weight: .light, design: .rounded))
                    Text(model.t("可用：", "Available: ") + (s.memory.total > 0 ? DisplayFormat.bytes(s.memory.available) : model.unavailable)).foregroundStyle(.secondary).lineLimit(1)
                    Text(model.t("壓力：", "Pressure: ") + (s.memory.pressure?.isEmpty == false ? s.memory.pressure! : model.unavailable)).font(.caption).lineLimit(1)
                    Text("Swap " + DisplayFormat.bytes(s.memory.swapUsed) + " / " + DisplayFormat.bytes(s.memory.swapTotal)).font(.caption).lineLimit(1)
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
            VStack(alignment: .leading, spacing: 20) {
                if !s.gpu.isEmpty {
                    hardwareSectionHeading(model.t("圖形處理器", "Graphics Processors"), symbol: "cpu", count: s.gpu.count)
                    VStack(spacing: 12) {
                        ForEach(Array(s.gpu.enumerated()), id: \.offset) { _, gpu in gpuCard(gpu) }
                    }
                }
                if !s.bluetooth.isEmpty {
                    hardwareSectionHeading(model.t("藍牙裝置", "Bluetooth Devices"), symbol: "wave.3.right", count: s.bluetooth.count)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 380))], alignment: .leading, spacing: 12) {
                        ForEach(Array(s.bluetooth.enumerated()), id: \.offset) { _, device in bluetoothCard(device) }
                    }
                }
                if !s.sensors.isEmpty {
                    hardwareSectionHeading(model.t("感測器", "Sensors"), symbol: "thermometer.medium", count: s.sensors.count)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 380))], alignment: .leading, spacing: 12) {
                        ForEach(Array(s.sensors.enumerated()), id: \.offset) { _, sensor in sensorCard(sensor) }
                    }
                }
                if s.gpu.isEmpty && s.bluetooth.isEmpty && s.sensors.isEmpty {
                    ContentUnavailableView(model.t("沒有其他硬體讀值", "No Additional Hardware Readings"),
                                           systemImage: "cpu",
                                           description: Text(model.t("Mole 目前沒有提供 GPU、藍牙或感測器資料。", "Mole did not provide GPU, Bluetooth or sensor data.")))
                        .frame(maxWidth: .infinity)
                }
                HStack {
                    Spacer()
                    Button(model.t("查看官方 JSON 快照", "View Official JSON Snapshot")) {
                        model.request(.status, options: [.json])
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 14)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .moPanelGlass(cornerRadius: 18)
    }

    private func hardwareSectionHeading(_ title: String, symbol: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: symbol).font(.headline)
            Text(String(count))
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: Capsule())
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func gpuCard(_ gpu: GPUStatus) -> some View {
        HStack(spacing: 18) {
            Image(systemName: "cpu")
                .font(.title2)
                .foregroundStyle(MoPanelTheme.accent)
                .frame(width: 44, height: 44)
                .moPanelGlass(cornerRadius: 13)
            VStack(alignment: .leading, spacing: 5) {
                Text(gpu.name ?? model.t("GPU", "GPU")).font(.headline)
                if let note = gpu.note, !note.isEmpty {
                    Text(readableGPUNote(note)).font(.caption).foregroundStyle(.secondary)
                }
                if let cores = gpu.coreCount, cores > 0 {
                    Text("\(cores) " + model.t("核心", "cores")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 3) {
                Text(model.t("使用率", "Utilization")).font(.caption).foregroundStyle(.secondary)
                Text(gpuUsage(gpu.usage))
                    .font(.system(size: 28, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(gpu.usage.map { $0 >= 0 && $0.isFinite } == true ? Color.primary : Color.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .moPanelGlass(cornerRadius: 16)
    }

    private func bluetoothCard(_ device: BluetoothDevice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "wave.3.right")
                    .foregroundStyle(device.connected ? MoPanelTheme.accent : Color.secondary)
                    .frame(width: 22)
                Text(readableBluetoothName(device.name))
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(device.connected ? model.t("已連線", "Connected") : model.t("未連線", "Not connected"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(device.connected ? MoPanelTheme.accent : Color.secondary)
                    .fixedSize()
            }
            if let battery = bluetoothBattery(device) {
                Label(battery, systemImage: "battery.100percent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 32)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
        .moPanelGlass(cornerRadius: 15)
    }

    private func sensorCard(_ sensor: SensorReading) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Label(sensor.label, systemImage: "thermometer.medium")
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(DisplayFormat.number(sensor.value, suffix: " " + sensor.unit))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .moPanelGlass(cornerRadius: 15)
    }

    private func gpuUsage(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return model.t("未提供", "Unavailable") }
        return DisplayFormat.percent(value)
    }

    private func readableGPUNote(_ note: String) -> String {
        let prefix = "sppci_vendor_"
        if note.hasPrefix(prefix) {
            let vendor = String(note.dropFirst(prefix.count)).replacingOccurrences(of: "_", with: " ")
            return model.t("廠商：\(vendor)", "Vendor: \(vendor)")
        }
        return note.replacingOccurrences(of: "_", with: " ")
    }

    private func readableBluetoothName(_ name: String) -> String {
        for marker in [" Right Battery Level:", " Left Battery Level:", " Battery Level:"] {
            if let range = name.range(of: marker, options: .caseInsensitive) {
                return String(name[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return name
    }

    private func bluetoothBattery(_ device: BluetoothDevice) -> String? {
        let rawValue = device.battery?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = rawValue.flatMap({ $0.isEmpty ? nil : $0 }) ?? embeddedBluetoothBattery(device.name) else { return nil }
        let detail = raw.range(of: "Battery Level:", options: .caseInsensitive).map { _ in raw }
            ?? embeddedBluetoothBattery(device.name)
            ?? raw
        guard let range = detail.range(of: "Battery Level:", options: .caseInsensitive) else {
            return model.t("電量：\(raw)", "Battery: \(raw)")
        }
        let side = String(detail[..<range.lowerBound]).lowercased()
        let value = String(detail[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let title = side.contains("right") ? model.t("右側電量", "Right battery")
            : side.contains("left") ? model.t("左側電量", "Left battery")
            : model.t("電量", "Battery")
        return title + (model.language == "en" ? ": " : "：") + value
    }

    private func embeddedBluetoothBattery(_ name: String) -> String? {
        for marker in ["Right Battery Level:", "Left Battery Level:", "Battery Level:"] {
            if let range = name.range(of: marker, options: .caseInsensitive) {
                return String(name[range.lowerBound...])
            }
        }
        return nil
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
                    }.chartForegroundStyleScale(range: [MoPanelTheme.accent, MoPanelTheme.chartSecondary]).chartXAxis(.hidden).frame(height: 125)
                        .accessibilityLabel(title + " " + model.t("最近最多 120 筆讀值", "up to 120 recent samples"))
                }
            }.padding(8)
        }
    }
}
