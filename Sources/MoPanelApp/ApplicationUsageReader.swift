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
    @State private var sortByCPU = false
    @State private var showAll = false
    @State private var search = ""
    @State private var expanded: String?
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
            }
            if !compact { TextField(model.t("搜尋程式", "Search apps"), text: $search).textFieldStyle(.roundedBorder) }
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 7) {
                    Button { expanded = expanded == row.id ? nil : row.id } label: {
                        HStack(spacing: 8) {
                            if !compact { AppIcon(path: row.appPath ?? row.id, size: 26) }
                            Text(row.name).font(.callout.weight(.medium)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(DisplayFormat.bytes(row.memory)).frame(width: compact ? 70 : 100, alignment: .trailing)
                            Text(row.cpu.map { String(format: "%.1f%%", $0) } ?? "…").frame(width: compact ? 50 : 65, alignment: .trailing)
                        }.font(.caption).monospacedDigit().contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if expanded == row.id {
                        Text("PID \(row.pid) · \(row.processCount) " + model.t("個程序", "processes")).font(.caption).foregroundStyle(.secondary)
                        if let path = row.appPath { Text(path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }
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
}
