// Read-only interval CPU/physical-footprint observer for one explicit MoPanel PID.
// Compile with: xcrun swiftc -O -parse-as-library scripts/measure_resources.swift -o build/measure-resources
import Foundation
import Darwin

struct ResourceProcess {
    let pid: Int32
    let parent: Int32
    let started: UInt64
    let cpu: UInt64
    let footprint: UInt64
    let path: String
}
func resourceProcesses() -> [Int32: ResourceProcess] {
    let capacity = min(max(Int(proc_listallpids(nil, 0)) + 128, 256), 16384)
    var pids = [Int32](repeating: 0, count: capacity)
    let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    guard count > 0 else { return [:] }
    var result: [Int32: ResourceProcess] = [:]
    for pid in pids.prefix(min(capacity, Int(count))) where pid > 0 {
        var info = proc_taskallinfo()
        guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, Int32(MemoryLayout<proc_taskallinfo>.stride)) == MemoryLayout<proc_taskallinfo>.stride,
              info.pbsd.pbi_uid == getuid() else { continue }
        var usage = rusage_info_v2()
        let rc = withUnsafeMutablePointer(to: &usage) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) } }
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { continue }
        result[pid] = ResourceProcess(pid: pid, parent: Int32(info.pbsd.pbi_ppid),
            started: info.pbsd.pbi_start_tvsec * 1_000_000 + info.pbsd.pbi_start_tvusec,
            cpu: info.ptinfo.pti_total_user + info.ptinfo.pti_total_system,
            footprint: rc == 0 ? usage.ri_phys_footprint : info.ptinfo.pti_resident_size, path: String(cString: bytes))
    }
    return result
}
@main struct ObserveMoPanelResources {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 6, let pid = Int32(args[1]), pid > 1, let duration = Double(args[2]),
              (5...3600).contains(duration), let interval = Double(args[3]), (1...30).contains(interval),
              args[4] == "--output", args[5].hasPrefix("/"), !FileManager.default.fileExists(atPath: args[5]) else {
            throw NSError(domain: "MoPanel.Observer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: observer PID DURATION_SECONDS INTERVAL_SECONDS --output ABSOLUTE_NEW_REPORT"])
        }
        var previous = resourceProcesses()
        guard let root = previous[pid], URL(fileURLWithPath: root.path).lastPathComponent == "MoPanel" else {
            throw NSError(domain: "MoPanel.Observer", code: 2, userInfo: [NSLocalizedDescriptionKey: "PID must identify this user's running MoPanel executable"])
        }
        let start = ProcessInfo.processInfo.systemUptime
        var lastTime = start
        var samples: [[String: Any]] = []
        var ended = "duration_reached"
        while ProcessInfo.processInfo.systemUptime - start < duration {
            try await Task.sleep(for: .seconds(min(interval, duration - (ProcessInfo.processInfo.systemUptime - start))))
            let now = ProcessInfo.processInfo.systemUptime
            let records = resourceProcesses()
            guard let current = records[pid], current.started == root.started, current.path == root.path else { ended = "root_exited_or_identity_changed"; break }
            var included: Set<Int32> = [pid]
            while true {
                let children = Set(records.values.filter { included.contains($0.parent) }.map(\.pid))
                let oldCount = included.count; included.formUnion(children)
                if oldCount == included.count { break }
            }
            let elapsed = now - lastTime
            var cpu = 0.0, footprint: UInt64 = 0
            var processes: [[String: Any]] = []
            for id in included.sorted() {
                guard let process = records[id] else { continue }
                var percentage = 0.0
                if let old = previous[id], old.started == process.started, process.cpu >= old.cpu {
                    percentage = Double(process.cpu - old.cpu) / 1e9 / elapsed * 100
                }
                cpu += percentage; footprint += process.footprint
                processes.append(["pid": id, "name": URL(fileURLWithPath: process.path).lastPathComponent,
                                  "cpu_percent": percentage, "physical_footprint_bytes": process.footprint])
            }
            samples.append(["elapsed_seconds": now - start, "interval_seconds": elapsed, "cpu_percent": cpu,
                            "physical_footprint_bytes": footprint, "root_physical_footprint_bytes": current.footprint,
                            "process_count": included.count, "processes": processes])
            previous = records; lastTime = now
        }
        let cpus = samples.compactMap { $0["cpu_percent"] as? Double }
        let memory = samples.compactMap { $0["physical_footprint_bytes"] as? UInt64 }
        let report: [String: Any] = ["pid": pid, "executable": root.path, "completed": ended == "duration_reached", "stop_reason": ended,
            "requested_duration_seconds": duration, "duration_seconds": lastTime - start, "sample_count": samples.count,
            "cpu_mean_percent": cpus.isEmpty ? 0 : cpus.reduce(0, +) / Double(cpus.count), "cpu_peak_percent": cpus.max() ?? 0,
            "physical_footprint_first_bytes": memory.first ?? 0, "physical_footprint_last_bytes": memory.last ?? 0,
            "physical_footprint_peak_bytes": memory.max() ?? 0, "samples": samples,
            "method": "Public libproc task CPU nanosecond deltas over monotonic intervals; physical footprint; exact root identity and current-user descendants.",
            "limitations": "Children that exit between samples may be missed. New PIDs need a second sample for CPU deltas. Summed footprints can include shared accounting; this is not Energy Impact or a proof of no leaks."]
        let output = URL(fileURLWithPath: args[5])
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .withoutOverwriting)
        print(String(format: "CPU mean %.3f%%, peak %.3f%%; footprint %.1f → %.1f MiB (%d samples)", cpus.isEmpty ? 0 : cpus.reduce(0,+) / Double(cpus.count), cpus.max() ?? 0,
            Double(memory.first ?? 0) / 1048576, Double(memory.last ?? 0) / 1048576, samples.count))
    }
}
