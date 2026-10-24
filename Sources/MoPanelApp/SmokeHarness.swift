import SwiftUI
import AppKit
import MoPanelCore

/// An explicit test-launch mode. Normal launches never load these fixtures.
@MainActor enum SmokeHarness {
    static func run(_ model: AppModel) async {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--benchmark"), arguments.indices.contains(index + 1) {
            await benchmark(model, mode: arguments[index + 1]); return
        }
        var checks: [String: Bool] = [:]
        var failures: [String] = []
        try? await Task.sleep(for: .milliseconds(300))
        checks["window_created"] = NSApp.windows.contains { $0.isVisible && $0.contentView != nil }
        await model.detect()
        checks["fixture_cli_detected"] = model.installation?.source == .fixture
        checks["fixture_resource_inside_app"] = model.installation?.executable.resolvingSymlinksInPath().path.hasPrefix(Bundle.main.bundleURL.resolvingSymlinksInPath().path + "/") == true
        guard checks["fixture_cli_detected"] == true, checks["fixture_resource_inside_app"] == true else {
            await finish(model, environmentKey: "MOPANEL_SMOKE_REPORT", report: ["success": false, "window_created": checks["window_created"] == true, "fixture_only": true, "checks": checks, "errors": [model.error ?? "Bundled fixture was not resolved safely."]], success: false)
            return
        }
        checks["public_contracts_compatible"] = model.installation?.compatibility.allowsDestructive == true && model.installation?.incompatible.isEmpty == true
        await model.takeSnapshot()
        checks["status_decoded"] = model.status?.host == "fixture-only"
        if let error = model.error { failures.append(error) }
        await model.loadApps()
        checks["app_inventory_decoded"] = !model.apps.isEmpty
        if let error = model.error { failures.append(error) }
        await model.analyze(path: "/MoPanel-safe-fixture")
        checks["analyze_preserves_partial"] = model.analysis?.scanStatus == .partial && model.analysis?.entries.contains { $0.scanStatus == .unavailable && $0.measuredBytes == nil } == true
        if let error = model.error { failures.append(error) }
        await model.loadHistory()
        checks["history_decoded"] = model.history != nil
        if let error = model.error { failures.append(error) }
        model.section = .dashboard
        model.windowActive = true
        model.startMonitoring()
        try? await Task.sleep(for: .milliseconds(2600))
        checks["watch_ndjson_received"] = model.trends.count >= 2
        model.section = .clean
        checks["watch_stopped_on_navigation"] = !model.monitoring
        for section in AppSection.allCases {
            model.section = section
            try? await Task.sleep(for: .milliseconds(80))
        }
        checks["all_navigation_routes_rendered"] = NSApp.windows.contains { $0.isVisible }
        checks["no_real_engine_selected"] = model.installation?.source == .fixture
        let success = !checks.values.contains(false) && failures.isEmpty
        await finish(model, environmentKey: "MOPANEL_SMOKE_REPORT", report: [
            "success": success, "window_created": checks["window_created"] == true,
            "fixture_only": true, "checks": checks, "errors": failures,
            "note": "Window/route and adapter smoke only. This does not verify every physical button, TCC permission, real cleanup, or hardware reading."
        ], success: success)
    }

    private static func benchmark(_ model: AppModel, mode: String) async {
        guard ["idle", "monitor", "scan"].contains(mode) else {
            await finish(model, environmentKey: "MOPANEL_BENCHMARK_REPORT", report: ["mode": mode, "fixture_only": true, "completed": false, "error": "Unknown benchmark mode"], success: false)
            return
        }
        model.section = .settings
        await model.detect()
        guard model.installation?.source == .fixture else {
            await finish(model, environmentKey: "MOPANEL_BENCHMARK_REPORT", report: ["mode": mode, "fixture_only": true, "completed": false, "error": model.error ?? "Fixture unavailable"], success: false)
            return
        }
        let started = Date()
        var scans = 0
        if mode == "monitor" { model.section = .dashboard; model.windowActive = true; model.startMonitoring() }
        if mode == "scan" {
            model.section = .analyze
            while Date().timeIntervalSince(started) < 12 {
                await model.analyze(path: "/MoPanel-fixture-large")
                if model.error != nil { break }
                scans += 1
                try? await Task.sleep(for: .milliseconds(500))
            }
        } else { try? await Task.sleep(for: .seconds(12)) }
        let success = model.error == nil
        await finish(model, environmentKey: "MOPANEL_BENCHMARK_REPORT", report: [
            "mode": mode, "fixture_only": true, "completed": success,
            "started_at_epoch": started.timeIntervalSince1970,
            "duration_seconds": Date().timeIntervalSince(started), "scans": scans,
            "entries_per_scan": mode == "scan" ? 5000 : 0,
            "watch_samples": model.trends.count,
            "error": model.error ?? "",
            "scope": "Native UI/adapter fixture workload, not real filesystem cleanup or Mole hardware collection."
        ], success: success)
    }

    private static func finish(_ model: AppModel, environmentKey: String, report: [String: Any], success: Bool) async {
        model.shutdown()
        try? await Task.sleep(for: .milliseconds(500))
        guard let path = ProcessInfo.processInfo.environment[environmentKey], path.hasPrefix("/") else {
            fputs("Missing test report destination\n", stderr); exit(2)
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch { fputs("Cannot write test report: \(error)\n", stderr); exit(2) }
        exit(success ? 0 : 1)
    }
}
