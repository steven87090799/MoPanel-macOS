import SwiftUI
import Charts
import MoPanelCore

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hardwareExpanded = true
    @State private var showDetails = false
    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeading(title: model.t("看見 Mac 的當下", "Your Mac, right now"), subtitle: model.t("Mole 提供即時資源資料，macOS 補充記憶體壓力與硬體讀值。點選摘要卡可查看詳細資料。", "Live resources from Mole, with memory pressure and hardware readings from macOS. Select a summary card for details."), symbol: "waveform.path.ecg")
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
                    summary(s) { target in
                        showDetails = true
                        DispatchQueue.main.async { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { proxy.scrollTo(target, anchor: .top) } }
                    }
                    quickResources(s) { target in
                        showDetails = true
                        DispatchQueue.main.async { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { proxy.scrollTo(target, anchor: .top) } }
                    }
                    if !model.fixtureMode || !model.applicationUsage.isEmpty { GroupBox { ApplicationUsageList().padding(10) } }
                    DisclosureGroup(model.t("資源趨勢", "Resource Trends")) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                        TrendCard(title: "CPU", unit: "%", metric: .cpu)
                        TrendCard(title: model.t("記憶體", "Memory"), unit: "%", metric: .memory)
                        TrendCard(title: model.t("磁碟讀寫", "Disk I/O"), unit: "MB/s", metric: .disk)
                        TrendCard(title: model.t("網路", "Network") + " · " + model.selectedNetwork, unit: "MB/s", metric: .network)
                    }
                    }
                    if !model.monitorWarnings.isEmpty {
                        Notice(text: model.t("部分指標可能無法取得；官方診斷：\n", "Some metrics may be unavailable. Mole diagnostics:\n") + model.monitorWarnings, warning: true)
                    }
                    DisclosureGroup(model.t("更多系統資料與進階控制", "More System Details and Controls"), isExpanded: $showDetails) { detail(s) }
                } else {
                    ContentUnavailableView(model.t("等待第一筆真實資料", "Waiting for real metrics"), systemImage: "waveform.path.ecg", description: Text(model.t("可開始監控或取得單次快照；尚未提供的數據不會以假數字代替。", "Start monitoring or request a snapshot. Missing data is never replaced by invented values.")))
                }
            }.padding(26)
        }
        }
    }

    private func summary(_ s: StatusSnapshot, navigate: @escaping (String) -> Void) -> some View {
        GlassEffectContainer(spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                summaryCard("system-details", title: model.t("系統健康", "System Health"), navigate: navigate) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(s.healthScore.map(String.init) ?? "—").font(.system(size: 42, weight: .light, design: .rounded))
                        Text("/ 100").foregroundStyle(.secondary)
                    }
                    Text(model.t("Mole CLI 評分", "Mole CLI score")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(s.hardware?.model ?? s.host ?? model.unavailable).font(.callout).lineLimit(1)
                    Text(s.hardware?.cpuModel ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                summaryCard("cpu-details", title: "CPU", navigate: navigate) {
                    Text(s.cpu.logicalCPU > 0 ? DisplayFormat.percent(s.cpu.usage) : "—").font(.system(size: 42, weight: .light, design: .rounded))
                    Text("\(s.cpu.logicalCPU) " + model.t("邏輯核心", "logical cores")).font(.callout).foregroundStyle(.secondary)
                    Text(model.t("1 分鐘負載 ", "1-minute load ") + DisplayFormat.number(s.cpu.load1, suffix: "")).font(.caption)
                    Text(model.t("溫度 ", "Temperature ") + positive(model.cpuTemperature, suffix: " °C")).font(.caption).foregroundStyle(.secondary)
                }
                summaryCard("memory-details", title: model.t("記憶體", "Memory"), navigate: navigate) {
                    Text(s.memory.total > 0 ? DisplayFormat.percent(s.memory.usedPercent) : "—").font(.system(size: 42, weight: .light, design: .rounded))
                    Text(DisplayFormat.bytes(s.memory.used) + " / " + DisplayFormat.bytes(s.memory.total)).font(.callout).foregroundStyle(.secondary)
                    Text(model.t("壓力：", "Pressure: ") + model.memoryPressureText).font(.caption).foregroundStyle(pressureColor)
                    Text(model.t("可用 ", "Available ") + DisplayFormat.bytes(s.memory.available) + " · Swap " + DisplayFormat.bytes(s.memory.swapUsed)).font(.caption).lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder private func detail(_ s: StatusSnapshot) -> some View {
        GroupBox(model.t("系統詳細資訊", "System Details")) {
            VStack(spacing: 12) {
                LabeledContent(model.t("機型", "Model"), value: s.hardware?.model ?? s.host ?? "—")
                LabeledContent(model.t("晶片", "Chip"), value: s.hardware?.cpuModel ?? "—")
                LabeledContent(model.t("系統版本", "System version"), value: s.hardware?.osVersion ?? s.platform ?? "—")
                LabeledContent(model.t("連續開機", "Uptime"), value: s.uptime ?? "—")
                LabeledContent(model.t("健康分數", "Health score"), value: s.healthScore.map { "\($0) / 100" } ?? "—")
                LabeledContent(model.t("狀態與原因", "Status and Reasons"), value: DisplayFormat.healthMessage(s.healthScoreMsg, language: model.language))
                Text(model.t("此分數來自 Mole CLI，與商業版 App 的評分方式可能不同。請搭配磁碟空間、記憶體壓力與負載判斷。", "This score comes from Mole CLI; the commercial app may use a different calculation. Review storage, memory pressure and load alongside it.")).font(.caption).foregroundStyle(.secondary)
            }.padding(10)
        }.id("system-details")
        GroupBox(model.t("CPU 詳細資訊", "CPU Details")) {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent(model.t("目前使用率", "Current usage"), value: DisplayFormat.percent(s.cpu.usage))
                LabeledContent(model.t("平均負載（1／5／15 分鐘）", "Load (1 / 5 / 15 min)"), value: [s.cpu.load1, s.cpu.load5, s.cpu.load15].map { DisplayFormat.number($0, suffix: "") }.joined(separator: " / "))
                LabeledContent(model.t("CPU 溫度", "CPU temperature"), value: positive(model.cpuTemperature, suffix: " °C"))
                Text(model.t("各核心使用率", "Per-core Usage")).font(.subheadline.weight(.semibold))
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
            }.padding(10)
        }.id("cpu-details")
        GroupBox(model.t("記憶體詳細資訊", "Memory Details")) {
            VStack(spacing: 12) {
                LabeledContent(model.t("記憶體壓力", "Memory pressure")) { Text(model.memoryPressureText).foregroundStyle(pressureColor) }
                LabeledContent(model.t("實體記憶體", "Physical memory"), value: DisplayFormat.bytes(s.memory.total))
                LabeledContent(model.t("已使用", "Used"), value: DisplayFormat.bytes(s.memory.used) + " · " + DisplayFormat.percent(s.memory.usedPercent))
                LabeledContent(model.t("可用", "Available"), value: DisplayFormat.bytes(s.memory.available))
                LabeledContent(model.t("檔案快取", "File cache"), value: DisplayFormat.bytes(s.memory.cached))
                LabeledContent(model.t("系統固定記憶體", "Wired memory"), value: DisplayFormat.bytes(model.nativeHardware.wiredMemory))
                LabeledContent(model.t("已壓縮", "Compressed"), value: DisplayFormat.bytes(model.nativeHardware.compressedMemory))
                LabeledContent(model.t("可回收快取", "Reclaimable cache"), value: DisplayFormat.bytes(model.nativeHardware.fileCache))
                LabeledContent(model.t("交換空間", "Swap"), value: DisplayFormat.bytes(s.memory.swapUsed) + " / " + DisplayFormat.bytes(s.memory.swapTotal))
                Text(model.t("壓力採 macOS 實際等級：正常、偏高、過高；與已使用百分比不同。", "Pressure uses macOS's actual normal, warning or critical state; it differs from percentage used.")).font(.caption).foregroundStyle(.secondary)
            }.padding(10)
        }.id("memory-details")
        GroupBox(model.t("磁碟與檔案系統", "Disks and Filesystems")) {
            VStack(spacing: 12) {
                ForEach(s.disks) { disk in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label(disk.mount, systemImage: disk.external == true ? "externaldrive" : "internaldrive")
                            Spacer()
                            Text(disk.total > 0 ? DisplayFormat.storage(disk.used) + " / " + DisplayFormat.storage(disk.total) : model.unavailable).font(.callout.monospacedDigit())
                        }
                        if disk.total > 0 { ProgressView(value: min(max(disk.usedPercent, 0), 100), total: 100) }
                        HStack { Text(disk.fstype ?? ""); Spacer(); Text("SMART: " + (disk.smartStatus?.isEmpty == false ? disk.smartStatus! : model.unavailable)) }.font(.caption).foregroundStyle(.secondary)
                    }
                }
                if s.disks.isEmpty { unavailableRow() }
            }.padding(10)
        }.id("disk-details")
        GroupBox(model.t("網路介面", "Network Interfaces")) {
            VStack(alignment: .leading, spacing: 10) {
                if model.networks.isEmpty { unavailableRow() }
                else {
                    Picker(model.t("圖表介面", "Chart Interface"), selection: Binding(get: { model.networkChartChoice }, set: model.selectNetwork)) {
                        Text(model.t("自動選擇使用中的連線", "Automatic active connection")).tag("auto")
                        ForEach(model.networks) { network in Text(model.networkName(network.name)).tag(network.name) }
                    }.pickerStyle(.menu)
                    ForEach(model.networks) { network in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.networkName(network.name)).font(.callout.weight(.medium))
                                Text(network.ip?.isEmpty == false ? network.ip! : model.t("未回報 IP 位址", "No IP address reported")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("↓ " + MonitorFormat.rate(network.rxRateMbs)).monospacedDigit()
                            Text("↑ " + MonitorFormat.rate(network.txRateMbs)).monospacedDigit()
                        }.font(.callout).padding(.vertical, 4)
                    }
                    Text(model.t("各介面分開顯示，不將 VPN 與實體網卡重複相加。", "Interfaces are shown separately; VPN and physical traffic are not added twice.")).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(10)
        }.id("network-details")
        GroupBox(model.t("電池、溫度與功耗", "Battery, Thermals and Power")) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(s.batteries.enumerated()), id: \.offset) { index, battery in
                    LabeledContent(model.t("電池", "Battery") + " \(index + 1)", value: DisplayFormat.percent(battery.percent) + " · " + (battery.status ?? model.unavailable))
                    LabeledContent(model.t("健康／循環", "Health / Cycles"), value: (battery.health ?? "—") + " / " + (battery.cycleCount.map(String.init) ?? "—"))
                    LabeledContent(model.t("最大容量", "Maximum Capacity"), value: battery.capacity.map { "\($0)%" } ?? model.unavailable)
                }
                if s.batteries.isEmpty { LabeledContent(model.t("電池", "Battery"), value: model.unavailable) }
                LabeledContent("CPU", value: positive(model.cpuTemperature, suffix: " °C"))
                LabeledContent("GPU", value: positive(model.gpuTemperature, suffix: " °C"))
                LabeledContent(model.t("電池溫度", "Battery Temperature"), value: positive(s.thermal?.batteryTemp, suffix: " °C"))
                LabeledContent(model.t("系統功耗", "System Power"), value: positive(s.thermal?.systemPower, suffix: " W"))
                LabeledContent(model.t("電源供應器", "Power Adapter"), value: positive(s.thermal?.adapterPower, suffix: " W"))
                ForEach(Array(model.fanSpeeds.enumerated()), id: \.offset) { index, rpm in
                    LabeledContent(model.t("風扇", "Fan") + " \(index + 1)", value: String(format: "%.0f RPM", rpm) + (rpm == 0 ? model.t(" · 停轉", " · stopped") : ""))
                }
                if model.fanSpeeds.isEmpty { LabeledContent(model.t("風扇", "Fans"), value: model.t("尚無讀值", "No reading")) }
                ForEach(Array(s.sensors.enumerated()), id: \.offset) { _, sensor in LabeledContent(sensor.label, value: DisplayFormat.number(sensor.value, suffix: " " + sensor.unit)) }
                Text(model.t("硬體資料由 Mole 與 macOS 唯讀感測提供；風扇停轉時顯示 0 RPM。", "Read-only Mole and macOS hardware readings; a stopped fan reports 0 RPM.")).font(.caption).foregroundStyle(.secondary)
            }.padding(10)
        }.id("thermal-details")
        GroupBox(model.t("高資源使用率行程", "Top Processes")) {
            ProcessInspectorView(snapshot: s).padding(10)
        }
        DisclosureGroup(model.t("GPU 與其他硬體讀值", "GPU and Other Hardware"), isExpanded: $hardwareExpanded) {
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
        .id("gpu-details")
    }

    private func quickResources(_ s: StatusSnapshot, navigate: @escaping (String) -> Void) -> some View {
        let gpu = s.gpu.first.flatMap { model.gpuUsage($0) } ?? model.nativeHardware.gpuUsage
        let disk = s.disks.first(where: { $0.mount == "/" }) ?? s.disks.first
        let available = disk.flatMap { $0.total >= $0.used && $0.total > 0 ? $0.total - $0.used : nil }
        let network = model.networks.first { $0.name == model.selectedNetwork }
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            quickCard("GPU", value: DisplayFormat.percent(gpu), detail: positive(model.gpuTemperature, suffix: " °C"), target: "gpu-details", navigate: navigate)
            quickCard(model.t("可用空間", "Free Space"), value: DisplayFormat.storage(available), detail: disk.map { DisplayFormat.storage($0.total) + model.t(" 總容量", " total") } ?? "", target: "disk-details", navigate: navigate)
            quickCard(model.t("網路", "Network"), value: "↓ " + MonitorFormat.rate(network?.rxRateMbs), detail: "↑ " + MonitorFormat.rate(network?.txRateMbs) + " · " + model.networkName(model.selectedNetwork), target: "network-details", navigate: navigate)
            quickCard(model.t("風扇", "Fans"), value: model.fanSpeeds.isEmpty ? "—" : model.fanSpeeds.map { String(format: "%.0f", $0) }.joined(separator: " / ") + " RPM", detail: model.fanSpeeds.isEmpty ? model.t("等待讀值", "Waiting for readings") : "\(model.fanSpeeds.count) " + model.t("個風扇", "fans"), target: "thermal-details", navigate: navigate)
        }
    }
    private func quickCard(_ title: String, value: String, detail: String, target: String, navigate: @escaping (String) -> Void) -> some View {
        Button { navigate(target) } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack { Text(title).font(.callout.weight(.semibold)); Spacer(); Text(model.t("詳情", "Details")).font(.caption2).foregroundStyle(.secondary) }
                Text(value).font(.system(size: 23, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.padding(16).frame(maxWidth: .infinity, minHeight: 112, alignment: .leading).moPanelGlass(cornerRadius: 16)
        }.buttonStyle(.plain)
    }

    private var pressureColor: Color {
        switch model.memoryPressure { case .normal: return MoPanelTheme.positive; case .warning: return .orange; case .critical: return .red; case nil: return .secondary }
    }
    private func summaryCard<Content: View>(_ target: String, title: String, navigate: @escaping (String) -> Void,
                                           @ViewBuilder content: () -> Content) -> some View {
        Button { navigate(target) } label: {
            GlassCard(minHeight: 208) {
                HStack { Text(title).font(.headline); Spacer(); Text(model.t("查看詳情", "Details")).font(.caption).foregroundStyle(.secondary) }
                content()
            }.contentShape(RoundedRectangle(cornerRadius: 22))
        }.buttonStyle(.plain).accessibilityIdentifier("mopanel.dashboard." + target)
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
                Text(model.gpuUsage(gpu).map(DisplayFormat.percent) ?? model.t("暫無讀值", "No reading"))
                    .font(.system(size: 28, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(model.gpuUsage(gpu) != nil ? Color.primary : Color.secondary)
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

enum MonitorFormat {
    static func rate(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        if value >= 1 { return String(format: "%.2f MB/s", value) }
        if value >= 1 / 1024 { return String(format: "%.1f KB/s", value * 1024) }
        return String(format: "%.0f B/s", value * 1024 * 1024)
    }
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
    private var isRate: Bool { metric == .disk || metric == .network }
    private var rawPoints: [TrendPoint] {
        model.trends.flatMap { sample -> [TrendPoint] in
            let pairs: [(String, Double?)]
            switch metric {
            case .cpu: pairs = [("CPU", sample.cpu)]
            case .memory: pairs = [(model.t("記憶體", "Memory"), sample.memory)]
            case .disk: pairs = [(model.t("讀取", "Read"), sample.diskRead), (model.t("寫入", "Write"), sample.diskWrite)]
            case .network:
                let interface = sample.networkInterfaces[model.selectedNetwork]
                pairs = [(model.t("下載", "Download"), interface?.rxRateMbs), (model.t("上傳", "Upload"), interface?.txRateMbs)]
            }
            return pairs.compactMap { name, value in
                guard let value, value.isFinite, value >= 0 else { return nil }
                return TrendPoint(id: sample.id.uuidString + name, date: sample.date, value: value, series: name)
            }
        }
    }
    private var scale: Double { isRate && (rawPoints.map(\.value).max() ?? 0) < 1 ? 1024 : 1 }
    private var chartUnit: String { isRate ? (scale == 1024 ? "KB/s" : "MB/s") : "%" }
    private var peak: Double { rawPoints.map(\.value).max() ?? 0 }
    private var currentText: String {
        guard let status = model.status else { return "—" }
        switch metric {
        case .cpu: return status.cpu.logicalCPU > 0 ? DisplayFormat.percent(status.cpu.usage) : "—"
        case .memory: return status.memory.total > 0 ? DisplayFormat.percent(status.memory.usedPercent) : "—"
        case .disk: return "↓ " + MonitorFormat.rate(status.diskIO?.readRate) + "   ↑ " + MonitorFormat.rate(status.diskIO?.writeRate)
        case .network:
            let interface = model.networks.first { $0.name == model.selectedNetwork }
            return "↓ " + MonitorFormat.rate(interface?.rxRateMbs) + "   ↑ " + MonitorFormat.rate(interface?.txRateMbs)
        }
    }
    private var context: String {
        guard let status = model.status else { return "" }
        switch metric {
        case .cpu: return "\(status.cpu.logicalCPU) " + model.t("邏輯核心 · 1 分鐘負載 ", "logical cores · 1 min load ") + DisplayFormat.number(status.cpu.load1, suffix: "")
        case .memory: return DisplayFormat.bytes(status.memory.used) + " / " + DisplayFormat.bytes(status.memory.total) + model.t(" · 壓力", " · Pressure ") + model.memoryPressureText
        case .disk: return model.t("↓ 讀取   ↑ 寫入", "↓ Read   ↑ Write")
        case .network: return model.networkName(model.selectedNetwork) + (model.automaticNetworkSelection ? model.t(" · 自動", " · Auto") : model.t(" · 手動", " · Manual"))
        }
    }
    var body: some View {
        let points = rawPoints
        let multiplier = scale
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text(title).font(.headline); Spacer(); Text(chartUnit).font(.caption).foregroundStyle(.secondary) }
                Text(currentText).font(.system(size: isRate ? 20 : 28, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                Text(context).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(context)
                if points.isEmpty { Text(model.t("等待讀值", "Waiting for readings")).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 125) }
                else {
                    Chart(points) { point in
                        LineMark(x: .value(model.t("時間", "Time"), point.date), y: .value(chartUnit, point.value * multiplier))
                            .foregroundStyle(by: .value(model.t("指標", "Metric"), point.series)).interpolationMethod(.linear)
                    }
                    .chartForegroundStyleScale(range: [MoPanelTheme.accent, MoPanelTheme.chartSecondary])
                    .chartYScale(domain: 0...(isRate ? max(peak * multiplier * 1.15, 1) : 100))
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 2)) { value in AxisValueLabel(format: .dateTime.hour().minute().second()) } }
                    .frame(height: 125)
                    .accessibilityLabel(title + " " + currentText)
                }
                HStack {
                    Text(model.t("最近 ", "Recent ") + String(model.trends.count) + model.t(" 筆", " samples"))
                    Spacer()
                    Text(model.t("峰值 ", "Peak ") + (isRate ? MonitorFormat.rate(points.isEmpty ? nil : peak) : (points.isEmpty ? "—" : DisplayFormat.percent(peak))))
                }.font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }.padding(8)
        }
    }
}
