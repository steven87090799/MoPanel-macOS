// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(Darwin)
import Darwin

public struct ProcessDetails: Sendable {
    public let pid: Int32
    public let parentPID: Int32
    public let parentName: String?
    public let executable: String
    public let startedAt: Date
    public let threads: Int
    public let openFiles: Int?
    public let bytesRead: UInt64?
    public let bytesWritten: UInt64?
    public let collectedAt: Date
}

/// On-demand metadata, with no collector, timer, command-line/environment dump,
/// launchctl mutation or signal sent to a process.
public enum ProcessDetailsReader {
    public static func read(pid: Int32, expectedAppPath: String? = nil) -> ProcessDetails? {
        guard pid > 0 else { return nil }
        var info = proc_taskallinfo()
        let size = MemoryLayout<proc_taskallinfo>.stride
        guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, Int32(size)) == size,
              info.pbsd.pbi_uid == getuid(), let executable = path(pid) else { return nil }
        if let expectedAppPath {
            let root = URL(fileURLWithPath: expectedAppPath).resolvingSymlinksInPath().path
            let actual = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
            guard actual.hasPrefix(root + "/") else { return nil }
        }
        let fdBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        var usage = rusage_info_v2()
        let usageCode = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        // A PID may be reused during the read. Require the same start identity.
        var fresh = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &fresh, Int32(MemoryLayout<proc_bsdinfo>.stride)) == MemoryLayout<proc_bsdinfo>.stride,
              fresh.pbi_uid == info.pbsd.pbi_uid, fresh.pbi_start_tvsec == info.pbsd.pbi_start_tvsec,
              fresh.pbi_start_tvusec == info.pbsd.pbi_start_tvusec, path(pid) == executable else { return nil }
        return ProcessDetails(pid: pid, parentPID: Int32(info.pbsd.pbi_ppid),
            parentName: path(Int32(info.pbsd.pbi_ppid)).map { URL(fileURLWithPath: $0).lastPathComponent }, executable: executable,
            startedAt: Date(timeIntervalSince1970: Double(info.pbsd.pbi_start_tvsec) + Double(info.pbsd.pbi_start_tvusec) / 1_000_000),
            threads: Int(info.ptinfo.pti_threadnum), openFiles: fdBytes > 0 ? Int(fdBytes) / MemoryLayout<proc_fdinfo>.stride : nil,
            bytesRead: usageCode == 0 ? usage.ri_diskio_bytesread : nil, bytesWritten: usageCode == 0 ? usage.ri_diskio_byteswritten : nil,
            collectedAt: Date())
    }
    private static func path(_ pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
        return String(cString: bytes)
    }
}
#endif
