import AppKit
import SwiftUI
import Darwin
import MoPanelCore

struct ProcessApplicationIdentity: Sendable {
    let pid: Int32
    let name: String
    let path: String?
    let bundleID: String?
}

struct ApplicationUsage: Identifiable, Sendable {
    let id: String
    let name: String
    let appPath: String?
    let pid: Int32
    var memory: UInt64
    var cpu: Double?
    var processCount: Int
}

/// One bounded snapshot on the existing monitoring cadence; no ps subprocess.
/// Child attribution requires a verified bundle path or parent chain.
final class ApplicationUsageReader {
    private struct Previous { let started: UInt64; let cpu: UInt64; let time: TimeInterval }
    private var previous: [Int32: Previous] = [:]
    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t(); mach_timebase_info(&info); return info
    }()

    func reset() { previous.removeAll(keepingCapacity: false) }

    static func applicationIdentities() -> [ProcessApplicationIdentity] {
        NSWorkspace.shared.runningApplications.map { ProcessApplicationIdentity(pid: $0.processIdentifier, name: $0.localizedName ?? "", path: $0.bundleURL?.path, bundleID: $0.bundleIdentifier) }
    }

    func read(apps: [ProcessApplicationIdentity]) -> [ApplicationUsage] {
        let capacity = min(max(Int(proc_listallpids(nil, 0)) + 128, 256), 16384)
        var pids = [Int32](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        let appByPID = Dictionary(apps.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let rootApps = apps.filter { $0.path?.hasSuffix(".app") == true }
        let appByPath = Dictionary(rootApps.compactMap { app in app.path.map { ($0, app) } }, uniquingKeysWith: { first, _ in first })
        let webOwners = rootApps.map { (id: String($0.pid), name: $0.name) }
        let now = ProcessInfo.processInfo.systemUptime
        var records: [Int32: (parent: Int32, path: String, memory: UInt64, cpu: Double?)] = [:]
        var next: [Int32: Previous] = [:]
        for pid in pids.prefix(min(Int(count), capacity)) where pid > 0 {
            var info = proc_taskallinfo()
            let size = MemoryLayout<proc_taskallinfo>.stride
            guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, Int32(size)) == size,
                  info.pbsd.pbi_uid == getuid() else { continue }
            var pathBytes = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            guard proc_pidpath(pid, &pathBytes, UInt32(pathBytes.count)) > 0 else { continue }
            let path = String(cString: pathBytes)
            let ticks = info.ptinfo.pti_total_user + info.ptinfo.pti_total_system
            let started = info.pbsd.pbi_start_tvsec * 1_000_000 + info.pbsd.pbi_start_tvusec
            var cpu: Double?
            if let old = previous[pid], old.started == started, now > old.time, ticks >= old.cpu {
                cpu = MachCPUTime.percentage(deltaTicks: ticks - old.cpu, elapsedSeconds: now - old.time,
                                             numerator: timebase.numer, denominator: timebase.denom)
            }
            next[pid] = Previous(started: started, cpu: ticks, time: now)
            var usage = rusage_info_v2()
            let readUsage = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            let memory = readUsage == 0 ? usage.ri_phys_footprint : info.ptinfo.pti_resident_size
            records[pid] = (Int32(info.pbsd.pbi_ppid), path, memory, cpu)
        }
        previous = next
        var groups: [String: ApplicationUsage] = [:]
        for (pid, record) in records {
            var app = appByPID[pid]
            if let service = app, service.bundleID?.hasPrefix("com.apple.WebKit") == true,
               let owner = ApplicationUsageAttribution.webContentOwner(service.name, applications: webOwners),
               let ownerPID = Int32(owner) { app = appByPID[ownerPID] }
            var parent = record.parent
            var visited = Set<Int32>()
            while app == nil, parent > 1, visited.insert(parent).inserted, visited.count < 32 {
                app = appByPID[parent]
                parent = records[parent]?.parent ?? 0
            }
            var appPath = app?.path
            if appPath == nil, let end = record.path.range(of: ".app/") {
                appPath = String(record.path[..<end.lowerBound]) + ".app"
            }
            if let path = appPath, let end = path.range(of: ".app/") { appPath = String(path[..<end.lowerBound]) + ".app" }
            if let appPath, let main = appByPath[appPath] { app = main }
            let name = app?.name ?? appPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? URL(fileURLWithPath: record.path).lastPathComponent
            let key = appPath.map { $0.hasSuffix(".app") ? $0 : $0 + "|" + name } ?? record.path
            if var group = groups[key] {
                group.memory += record.memory
                if let cpu = record.cpu { group.cpu = (group.cpu ?? 0) + cpu }
                group.processCount += 1
                groups[key] = group
            } else {
                groups[key] = ApplicationUsage(id: key, name: name, appPath: appPath, pid: app?.pid ?? pid,
                                               memory: record.memory, cpu: record.cpu, processCount: 1)
            }
        }
        return groups.values.sorted { $0.memory > $1.memory }
    }
}

struct ApplicationUsageList: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sortByCPU = false
    @State private var showAll = false
    @State private var search = ""
    @State private var expanded: String?
    @State private var processDetails: ProcessDetails?
    @State private var readingDetails = false
    var compact = false
    private var rows: [ApplicationUsage] {
        let rows = model.applicationUsage.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted { sortByCPU ? ($0.cpu ?? -1) > ($1.cpu ?? -1) : $0.memory > $1.memory }
        return Array(rows.prefix(compact ? 5 : showAll ? 500 : 8))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.t("程式用量", "Application Usage") + " (\(model.applicationUsage.count))").font(.headline)
                Spacer()
                Button(model.t("記憶體", "Memory")) { sortByCPU = false }.buttonStyle(.plain).frame(width: compact ? 70 : 100, alignment: .trailing).foregroundStyle(sortByCPU ? Color.secondary : MoPanelTheme.accent)
                Button("CPU") { sortByCPU = true }.buttonStyle(.plain).frame(width: compact ? 50 : 65, alignment: .trailing).foregroundStyle(sortByCPU ? MoPanelTheme.accent : Color.secondary)
                Color.clear.frame(width: 22)
            }
            if !compact { TextField(model.t("搜尋程式", "Search apps"), text: $search).textFieldStyle(.roundedBorder) }
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                    Button { toggleDetails(row) } label: {
                        HStack(spacing: 8) {
                            AppIcon(path: row.appPath ?? row.id, size: compact ? 20 : 26)
                            Text(row.name).font(.callout.weight(.medium)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(DisplayFormat.bytes(row.memory)).frame(width: compact ? 70 : 100, alignment: .trailing)
                            Text(row.cpu.map { String(format: "%.1f%%", $0) } ?? "…").frame(width: compact ? 50 : 65, alignment: .trailing)
                        }.font(.caption).monospacedDigit().contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    NativeActionButton(row.name + " · " + model.t("為什麼在執行？", "Why is it running?"), identifier: "mopanel.usage.details." + row.id, systemImage: "ellipsis", appearance: .icon) {
                        toggleDetails(row)
                    }.frame(width: 22).help(model.t("詳細資訊", "Details"))
                    }
                    if expanded == row.id {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.t("為什麼在執行？", "Why is it running?")).font(.callout.weight(.semibold))
                            Text(processPurpose(row)).font(.caption).foregroundStyle(.secondary)
                            LabeledContent(model.t("記憶體用量", "Memory usage"), value: DisplayFormat.bytes(row.memory))
                            LabeledContent("CPU", value: row.cpu.map { String(format: "%.1f%%", $0) } ?? model.t("等待下次取樣", "Waiting for next sample"))
                            LabeledContent(model.t("包含程序", "Grouped processes"), value: String(row.processCount))
                            LabeledContent("PID", value: String(row.pid))
                            if readingDetails { ProgressView().controlSize(.small) }
                            if let details = processDetails, details.pid == row.pid {
                                LabeledContent(model.t("上層程序", "Parent process"), value: (details.parentName ?? "—") + " · \(details.parentPID)")
                                LabeledContent(model.t("啟動時間", "Started"), value: details.startedAt.formatted(date: .abbreviated, time: .standard))
                                LabeledContent(model.t("執行緒", "Threads"), value: String(details.threads))
                                LabeledContent(model.t("開啟檔案", "Open files"), value: details.openFiles.map(String.init) ?? "—")
                                LabeledContent(model.t("累計磁碟讀寫", "Lifetime disk I/O"), value: "↓ " + DisplayFormat.bytes(details.bytesRead) + "  ↑ " + DisplayFormat.bytes(details.bytesWritten))
                                Text(details.executable).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            } else if !readingDetails {
                                Text(model.t("程序可能已結束或無法確認歸屬，暫時無法讀取更多資料。", "The process may have exited or its identity could not be verified. More details are unavailable.")).font(.caption2).foregroundStyle(.secondary)
                            }
                            if let path = row.appPath { Text(path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }
                            Text(model.t("數值包含可確認歸屬的子程序；CPU 以單一核心滿載為 100%。", "Includes child processes with a verified owner. One fully used core equals 100% CPU."))
                                .font(.caption2).foregroundStyle(.secondary)
                            HStack {
                                if let path = row.appPath { Button(model.t("在 Finder 顯示", "Show in Finder")) { model.reveal(path) }.disabled(model.isTestLaunch) }
                                Spacer()
                                Button(model.t("活動監視器", "Activity Monitor")) {
                                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") { NSWorkspace.shared.open(url) }
                                }.disabled(model.isTestLaunch)
                            }
                        }.font(.caption).padding(12).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityIdentifier("mopanel.usage.expanded." + row.id)
                    }
                }.padding(.vertical, 4)
            }
            if !compact, model.applicationUsage.count > 8, search.isEmpty { Button(showAll ? model.t("只顯示主要程式", "Show Top Apps") : model.t("查看更多程式", "Show More Apps")) { showAll.toggle() }.buttonStyle(.borderless) }
            if rows.isEmpty { Text(model.t("等待程式讀值", "Waiting for app readings")).font(.caption).foregroundStyle(.secondary) }
            if !compact {
                DisclosureGroup(model.t("用量詳細資訊", "Usage Details")) {
                    Text(model.t("彙總可確認歸屬的子程序；無法歸屬的系統服務分開列出。CPU 單核心滿載為 100%，最多每 5 秒取樣一次。", "Known child processes are grouped; unassigned services stay separate. One fully used CPU core equals 100%. Samples are at least 5 seconds apart.")).font(.caption2).foregroundStyle(.secondary)
                    if let date = model.nativeCollectedAt { Text(date.formatted(date: .abbreviated, time: .standard)).font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
    }
    private func toggleDetails(_ row: ApplicationUsage) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { expanded = expanded == row.id ? nil : row.id }
        processDetails = nil
        guard expanded == row.id, !model.isTestLaunch else { readingDetails = false; return }
        readingDetails = true
        Task {
            let value = await Task.detached(priority: .utility) { ProcessDetailsReader.read(pid: row.pid, expectedAppPath: row.appPath) }.value
            guard expanded == row.id else { return }
            processDetails = value; readingDetails = false
        }
    }
    private func processPurpose(_ row: ApplicationUsage) -> String {
        switch row.name.lowercased() {
        case "chronod": return model.t("macOS 小工具的時間軸服務，用來更新桌面與通知中心的小工具。", "A macOS widget timeline service that updates desktop and Notification Center widgets.")
        case "windowserver": return model.t("macOS 的畫面與視窗服務；顯示視窗、動畫及外接螢幕都會使用它。", "The macOS display and window service, used for windows, animations and connected displays.")
        case "mds", "mds_stores", "mdworker_shared": return model.t("Spotlight 搜尋索引服務，會在檔案變更後更新搜尋資料。", "Spotlight indexing services update the search index when files change.")
        case "launchd": return model.t("macOS 的程序與服務管理程式，負責依需要啟動背景工作。", "The macOS process and service manager starts background jobs when needed.")
        default:
            return row.appPath != nil
                ? model.t("這個 App 目前正在執行，用量包含可確認屬於它的背景程序。macOS 未提供可驗證的手動或自動啟動原因。", "This app is running. Usage includes background processes with a verified association. macOS has not provided a verifiable manual or automatic launch reason.")
                : model.t("這是一個獨立背景程序。下方可查看執行位置與上層程序；目前無法確認觸發它的具體原因。", "This is a separate background process. Its executable and parent are shown below; the specific launch trigger has not been verified.")
        }
    }
}
