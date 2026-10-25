#!/usr/bin/env python3
"""Verify production native byte counters with one small public README fetch.
No configuration changes; report interface names/rates, never IP addresses.
"""
import argparse
import json
import os
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
HARNESS = r'''
import SystemConfiguration
@main struct NativeNetworkProbe {
    static func main() async throws {
        let reader = NativeNetworkReader()
        let first = reader.read()
        let request = Process(); request.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        request.arguments = ["--fail", "--location", "--max-time", "10", "--silent", "--output", "/dev/null", "https://raw.githubusercontent.com/steven87090799/MoPanel-macOS/codex/product-readiness-audit/README.md"]
        try request.run(); request.waitUntilExit()
        guard request.terminationStatus == 0 else { throw NSError(domain: "MoPanel.NetworkTest", code: 1) }
        try await Task.sleep(for: .seconds(1))
        let samples = reader.read()
        let store = SCDynamicStoreCreate(nil, "MoPanel network test" as CFString, nil, nil)
        let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        let ipv6 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv6" as CFString) as? [String: Any]
        let primary = ipv4?["PrimaryInterface"] as? String ?? ipv6?["PrimaryInterface"] as? String
        let active = samples.first { $0.name == primary }
        reader.reset()
        let checks = ["first_sample_establishes_baseline": first.isEmpty,
                      "active_primary_interface_present_with_address": active != nil && active?.ip?.isEmpty == false,
                      "known_request_produces_actual_incoming_bytes": (active?.rxRateMbs ?? 0) > 0,
                      "pause_reset_discards_old_counter_baseline": reader.read().isEmpty]
        let report: [String: Any] = ["success": checks.values.allSatisfy { $0 }, "checks": checks,
            "primary_interface": primary ?? "", "sample_interfaces": samples.map { ["name": $0.name, "down_mb_s": $0.rxRateMbs, "up_mb_s": $0.txRateMbs, "has_ip": $0.ip?.isEmpty == false] as [String: Any] },
            "network_activity": "One bounded fetch of this public repository README, discarded to /dev/null", "configuration_changed": false]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        if checks.values.contains(false) { exit(1) }
    }
}
'''

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True, type=pathlib.Path)
    args = parser.parse_args()
    build = ['xcrun', 'swift', 'build', '--build-system', os.environ.get('MOPANEL_SWIFT_BUILD_SYSTEM', 'native'), '-c', 'release', '--arch', 'arm64', '--show-bin-path']
    if os.environ.get('MOPANEL_SWIFT_SCRATCH_PATH'): build += ['--scratch-path', os.environ['MOPANEL_SWIFT_SCRATCH_PATH']]
    binary = pathlib.Path(subprocess.check_output(build, cwd=ROOT, text=True).strip())
    modules = binary if (binary / 'MoPanelCore.swiftmodule').exists() else binary / 'Modules'
    objects = [binary / 'MoPanelCore.o'] if (binary / 'MoPanelCore.o').exists() else sorted((binary / 'MoPanelCore.build').glob('*.swift.o'))
    with tempfile.TemporaryDirectory(prefix='mopanel-network-probe-') as temporary:
        directory = pathlib.Path(temporary); swift = directory / 'Probe.swift'; executable = directory / 'Probe'
        swift.write_text((ROOT / 'Sources/MoPanelApp/NativeNetworkReader.swift').read_text() + '\n' + HARNESS)
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-O', '-target', 'arm64-apple-macos27.0', '-I', str(modules), str(swift), *map(str, objects), '-o', str(executable)], check=True, timeout=120)
        result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=20)
        if not result.stdout: raise RuntimeError(result.stderr[-3000:])
        report = json.loads(result.stdout)
        args.output.parent.mkdir(parents=True, exist_ok=True); args.output.write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps({'success': report['success'], 'checks': len(report['checks']), 'primary_interface': report['primary_interface']}))
        if result.returncode or not report['success']: raise RuntimeError('Native network probe did not pass; see saved report')

if __name__ == '__main__': main()
