#!/usr/bin/env python3
"""Check the production app CPU reader against POSIX child CPU time.
Runs one disposable yes process for two seconds, discarding all output.
"""
import argparse
import json
import os
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
HARNESS = r'''
@main struct CPUCounterProbe {
    static func seconds(_ usage: rusage) -> Double {
        Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
    static func main() async throws {
        var before = rusage(); getrusage(RUSAGE_CHILDREN, &before)
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        let began = ProcessInfo.processInfo.systemUptime
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        let identity = ProcessApplicationIdentity(pid: child.processIdentifier, name: "MoPanel disposable CPU fixture", path: "/MoPanel-disposable-cpu-fixture.app", bundleID: nil)
        let reader = ApplicationUsageReader()
        _ = reader.read(apps: [identity])
        try await Task.sleep(for: .seconds(2))
        let measured = reader.read(apps: [identity]).first { $0.pid == child.processIdentifier }?.cpu
        child.terminate(); child.waitUntilExit()
        let wall = ProcessInfo.processInfo.systemUptime - began
        var after = rusage(); getrusage(RUSAGE_CHILDREN, &after)
        let reference = (seconds(after) - seconds(before)) / wall * 100
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        let checks = ["native_sample_exists": measured != nil,
                      "known_busy_child_has_meaningful_usage": (measured ?? 0) > 40,
                      "matches_independent_posix_child_cpu_time": abs((measured ?? -1000) - reference) < 15]
        let report: [String: Any] = ["success": checks.values.allSatisfy { $0 }, "checks": checks,
            "native_cpu_percent": measured ?? -1, "posix_reference_cpu_percent": reference,
            "mach_timebase_numerator": timebase.numer, "mach_timebase_denominator": timebase.denom,
            "duration_seconds": wall, "fixture_child_reaped": !child.isRunning, "user_files_changed": false]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        if checks.values.contains(false) { exit(1) }
    }
}
'''

def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--output', required=True, type=pathlib.Path); args = parser.parse_args()
    build = ['xcrun', 'swift', 'build', '--build-system', os.environ.get('MOPANEL_SWIFT_BUILD_SYSTEM', 'native'), '-c', 'release', '--arch', 'arm64', '--show-bin-path']
    if os.environ.get('MOPANEL_SWIFT_SCRATCH_PATH'): build += ['--scratch-path', os.environ['MOPANEL_SWIFT_SCRATCH_PATH']]
    binary = pathlib.Path(subprocess.check_output(build, cwd=ROOT, text=True).strip())
    modules = binary if (binary / 'MoPanelCore.swiftmodule').exists() else binary / 'Modules'
    objects = [binary / 'MoPanelCore.o'] if (binary / 'MoPanelCore.o').exists() else sorted((binary / 'MoPanelCore.build').glob('*.swift.o'))
    source = (ROOT / 'Sources/MoPanelApp/ApplicationUsageReader.swift').read_text()
    marker = '\nstruct ApplicationUsageList: View {'
    if source.count(marker) != 1: raise RuntimeError('Production reader boundary changed')
    with tempfile.TemporaryDirectory(prefix='mopanel-cpu-probe-') as temporary:
        directory = pathlib.Path(temporary); swift = directory / 'Probe.swift'; executable = directory / 'Probe'
        swift.write_text(source.split(marker)[0] + '\n' + HARNESS)
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-O', '-target', 'arm64-apple-macos27.0', '-I', str(modules), str(swift), *map(str, objects), '-o', str(executable)], check=True, timeout=120)
        result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=15)
        if not result.stdout: raise RuntimeError(result.stderr[-3000:])
        report = json.loads(result.stdout); args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + '\n'); print(json.dumps(report))
        if result.returncode or not report['success']: raise RuntimeError('Native CPU probe did not pass')

if __name__ == '__main__': main()
