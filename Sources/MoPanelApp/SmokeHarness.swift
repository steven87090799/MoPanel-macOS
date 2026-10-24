import SwiftUI
import AppKit
import MoPanelCore

/// An explicit test-launch mode. Normal launches never load these fixtures.
@MainActor enum SmokeHarness {
    static func run(_ model: AppModel, systemTools: SystemToolsController) async {
        let arguments = ProcessInfo.processInfo.arguments
        checkpoint("entered")
        if let error = model.testLaunchError {
            // An invalid manifest has no trusted report destination. Log failure
            // and stop without probing a CLI or writing an arbitrary file.
            await model.finishTesting()
            fputs("Invalid test launch: \(error)\n", stderr)
            exit(2)
        }
        if model.readOnlyBenchmarkRequested {
            guard let configuration = model.benchmarkConfiguration else {
                await model.finishTesting()
                fputs("Missing explicit read-only benchmark configuration\n", stderr)
                exit(2)
            }
            await realBenchmark(model, configuration: configuration)
            return
        }
        if let index = arguments.firstIndex(of: "--benchmark"), arguments.indices.contains(index + 1) {
            await benchmark(model, mode: arguments[index + 1]); return
        }
        var checks: [String: Bool] = [:]
        var failures: [String] = []
        try? await Task.sleep(for: .milliseconds(300))
        checks["window_created"] = NSApp.windows.contains { $0.isVisible && $0.contentView != nil }
        checkpoint("detect.begin")
        await model.detect()
        checkpoint("detect.end")
        checks["fixture_cli_detected"] = model.installation?.source == .fixture
        checks["fixture_resource_inside_app"] = model.installation?.executable.resolvingSymlinksInPath().path.hasPrefix(Bundle.main.bundleURL.resolvingSymlinksInPath().path + "/") == true
        guard checks["fixture_cli_detected"] == true, checks["fixture_resource_inside_app"] == true else {
            await finish(model, environmentKey: "MOPANEL_SMOKE_REPORT", report: ["success": false, "window_created": checks["window_created"] == true, "fixture_only": true, "checks": checks, "errors": [model.error ?? "Bundled fixture was not resolved safely."]], success: false)
            return
        }
        checks["public_contracts_compatible"] = model.installation?.compatibility.allowsDestructive == true && model.installation?.incompatible.isEmpty == true
        checkpoint("system_tools.begin")
        let toolsEvidence = await systemTools.runSafeSmokeTest()
        checkpoint("system_tools.end")
        checks["native_assertion_created_and_released"] = toolsEvidence.assertionCreated && toolsEvidence.assertionReadableBeforeRelease && toolsEvidence.assertionReleaseCode == 0 && toolsEvidence.assertionAbsentAfterRelease
        checks["native_clean_screen_windows_constructed_and_closed"] = toolsEvidence.screenCount > 0 && toolsEvidence.overlayWindowsCreated == toolsEvidence.screenCount && toolsEvidence.overlayWindowsClosed == toolsEvidence.overlayWindowsCreated
        checks["native_tools_no_input_interception_or_ejection"] = !toolsEvidence.overlayWasPresented && !toolsEvidence.inputWasIntercepted && !toolsEvidence.ejectWasCalled
        checks["native_doctor_metadata_read"] = toolsEvidence.doctorEntryCount > 0
        failures.append(contentsOf: toolsEvidence.errors)
        checkpoint("startup_mock.begin")
        let startupEvidence = await StartupController.runSafeSmokeTest()
        checkpoint("startup_mock.end")
        checks["startup_mock_enable_disable_readback"] = startupEvidence.inventoryCount == 1 && startupEvidence.enableVerifiedWithMock && startupEvidence.disableVerifiedWithMock
        checks["startup_mock_cancel_and_unknown_format"] = startupEvidence.cancelledReviewDidNotMutate && startupEvidence.unknownFormatDidNotMutate
        checks["startup_no_real_mutation_or_persistent_job"] = startupEvidence.realLaunchctlMutations == 0 && startupEvidence.persistentJobsCreated == 0
        failures.append(contentsOf: startupEvidence.errors)
        checkpoint("status_snapshot.begin")
        await model.takeSnapshot()
        checkpoint("status_snapshot.end")
        checks["status_decoded"] = model.status?.host == "fixture-only"
        if let error = model.error { failures.append(error) }
        checkpoint("app_inventory.begin")
        await model.loadApps()
        checkpoint("app_inventory.end")
        checks["app_inventory_decoded"] = !model.apps.isEmpty
        if let error = model.error { failures.append(error) }
        checkpoint("analyze.begin")
        await model.analyze(path: "/MoPanel-safe-fixture")
        checkpoint("analyze.end")
        checks["analyze_preserves_partial"] = model.analysis?.scanStatus == .partial && model.analysis?.entries.contains { $0.scanStatus == .unavailable && $0.measuredBytes == nil } == true
        if let error = model.error { failures.append(error) }
        checkpoint("history.begin")
        await model.loadHistory()
        checkpoint("history.end")
        checks["history_decoded"] = model.history != nil
        if let error = model.error { failures.append(error) }
        model.section = .dashboard
        model.windowActive = true
        checkpoint("watch.begin")
        model.startMonitoring()
        try? await Task.sleep(for: .milliseconds(2600))
        checks["watch_ndjson_received"] = model.trends.count >= 2
        model.section = .clean
        checks["watch_stopped_on_navigation"] = !model.monitoring
        checkpoint("watch.end")
        checkpoint("routes.begin")
        for section in AppSection.allCases {
            model.section = section
            try? await Task.sleep(for: .milliseconds(80))
        }
        // This loop checks route selection and window survival, not pixel or
        // accessibility correctness for every page. Button postconditions below
        // provide stronger evidence for their explicitly named flows only.
        checks["navigation_routes_selected_with_window_alive"] = NSApp.windows.contains { $0.isVisible }
        checkpoint("routes.end")
        checks["no_real_engine_selected"] = model.installation?.source == .fixture
        var nativeUIObject: Any = [:]
        if let mainWindow = NSApp.windows.first(where: { $0.isVisible && !$0.isSheet && $0.styleMask.contains(.titled) && $0.contentView != nil }) {
            checkpoint("native_ui.begin")
            let uiEvidence = await NativeUITestHarness.run(model: model, window: mainWindow)
            checkpoint("native_ui.end")
            checks["native_accessibility_button_flows"] = uiEvidence.passed
            nativeUIObject = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(uiEvidence))) ?? [:]
            failures.append(contentsOf: uiEvidence.errors)
        } else {
            checks["native_accessibility_button_flows"] = false
            failures.append("No explicit own-process main window was available for native button tests.")
        }
        let success = !checks.values.contains(false) && failures.isEmpty
        let encodedTools = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(toolsEvidence))) ?? [:]
        let encodedStartup = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(startupEvidence))) ?? [:]
        checkpoint("report.begin")
        await finish(model, environmentKey: "MOPANEL_SMOKE_REPORT", report: [
            "success": success, "window_created": checks["window_created"] == true,
            "fixture_only": true, "checks": checks, "errors": failures,
            "system_tools": encodedTools,
            "startup_mock": encodedStartup,
            "native_ui": nativeUIObject,
            "navigation_sections_selected": AppSection.allCases.map(\.rawValue),
            "note": "Native window and route selection survival, adapter, safe system API probes, private Startup mock and explicitly identified own-process accessibility button actions. Route selection alone does not prove every page rendered correctly. This does not verify every physical interaction, TCC permission, real cleanup, app update or hardware control."
        ], success: success, previewTools: systemTools)
    }

    /// Fixed stage names only. Diagnostic output is restricted to an explicit
    /// smoke launch, never terminal content, user paths or production actions.
    private static func checkpoint(_ stage: String) {
        guard Array(ProcessInfo.processInfo.arguments.dropFirst()) == ["--smoke-test"] else { return }
        fputs("[MoPanel smoke] \(stage)\n", stderr)
        fflush(stderr)
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

    private static func realBenchmark(_ model: AppModel, configuration: ReadOnlyBenchmark) async {
        model.section = .settings
        await model.detect()
        guard let cli = model.installation, cli.source != .fixture,
              cli.executable.path == configuration.cli.path, model.error == nil else {
            await finish(model, environmentKey: "MOPANEL_BENCHMARK_REPORT", report: [
                "mode": configuration.mode.rawValue, "fixture_only": false, "read_only_enforced": true,
                "completed": false, "error": model.error ?? "Prepared official benchmark CLI is unavailable."
            ], success: false)
            return
        }
        let started = Date()
        var scans = 0
        var scanIntervals: [[String: Any]] = []
        if configuration.mode == .monitor {
            model.section = .dashboard
            model.windowActive = true
            model.startMonitoring()
        }
        if configuration.mode == .scan {
            model.section = .analyze
            while Date().timeIntervalSince(started) < 12, !Task.isCancelled {
                let began = Date()
                await model.analyze(path: configuration.corpus.path)
                let ended = Date()
                guard model.error == nil, let scan = model.analysis else { break }
                guard !scan.overview, URL(fileURLWithPath: scan.path).resolvingSymlinksInPath().path == configuration.corpus.path,
                      scan.scanStatus == .complete, scan.totalFiles == Int64(configuration.corpusFileCount) else {
                    model.error = "Prepared flat corpus was not completely measured; partial or unrelated results are not accepted as benchmark success."
                    break
                }
                scans += 1
                scanIntervals.append([
                    "start_epoch": began.timeIntervalSince1970, "end_epoch": ended.timeIntervalSince1970,
                    "scan_status": scan.scanStatus.rawValue, "total_files": scan.totalFiles ?? 0,
                    "entry_count": scan.entries.count
                ])
                if scanIntervals.count >= 1024 { model.error = "Unexpected benchmark scan rate exceeded the bounded evidence limit."; break }
                await Task.yield()
            }
        } else { try? await Task.sleep(for: .seconds(12)) }
        let ended = Date()
        if Task.isCancelled, model.error == nil { model.error = "Benchmark was cancelled." }
        if configuration.mode == .monitor, model.trends.count < 2, model.error == nil { model.error = "Official status watch did not provide enough decoded samples." }
        if configuration.mode == .scan, scans == 0, model.error == nil { model.error = "No official scan completed." }
        let success = model.error == nil
        await finish(model, environmentKey: "MOPANEL_BENCHMARK_REPORT", report: [
            "mode": configuration.mode.rawValue, "fixture_only": false, "read_only_enforced": true, "completed": success,
            "started_at_epoch": started.timeIntervalSince1970, "ended_at_epoch": ended.timeIntervalSince1970,
            "duration_seconds": ended.timeIntervalSince(started), "scans": scans, "scan_intervals": scanIntervals,
            "watch_samples": model.trends.count, "process_alerts": false,
            "cli_path": cli.executable.path, "cli_version": cli.version, "cli_fingerprint": cli.fingerprint,
            "cli_source_tag": configuration.sourceTag, "cli_source_commit": configuration.sourceCommit,
            "corpus_path": configuration.corpus.path, "corpus_file_count": configuration.corpusFileCount,
            "corpus_logical_bytes": configuration.corpusLogicalBytes,
            "error": model.error ?? "",
            "scope": "Official read-only CLI plus native GUI; flat corpus with warm filesystem cache. This is not cleanup, uninstall, or slimming performance."
        ], success: success)
    }

    private static func finish(_ model: AppModel, environmentKey: String, report: [String: Any], success: Bool,
                               previewTools: SystemToolsController? = nil) async {
        if model.fixtureMode, ProcessInfo.processInfo.arguments == [ProcessInfo.processInfo.arguments[0], "--smoke-test"] {
            model.section = .dashboard
            // An explicit, bounded developer preview keeps this already-tested
            // fixture window available for manual visual review. Normal smoke
            // drivers remove this flag so their deadline remains unchanged.
            if let value = ProcessInfo.processInfo.environment["MOPANEL_SMOKE_PREVIEW_SECONDS"],
               let seconds = Int(value), (1...300).contains(seconds) {
                model.apps = []
                var previewWindow: NSWindow?
                if ProcessInfo.processInfo.environment["MOPANEL_SMOKE_PREVIEW_KIND"] == "menubar",
                   let previewTools {
                    let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 790),
                                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
                    panel.title = "MoPanel · Menu Bar Preview"
                    panel.isReleasedWhenClosed = false
                    panel.contentView = NSHostingView(rootView: MenuBarPanel()
                        .environmentObject(model).environmentObject(previewTools)
                        .preferredColorScheme(model.colorScheme))
                    panel.center()
                    panel.makeKeyAndOrderFront(nil)
                    previewWindow = panel
                }
                checkpoint("manual_preview.ready")
                try? await Task.sleep(for: .seconds(seconds))
                previewWindow?.close()
                model.section = .dashboard
            }
            try? await Task.sleep(for: .milliseconds(150))
            checkpoint("own_window_capture.begin")
            saveOwnWindowScreenshot()
            checkpoint("own_window_capture.end")
        }
        checkpoint("finish_testing.begin")
        await model.finishTesting()
        checkpoint("finish_testing.end")
        guard let path = ProcessInfo.processInfo.environment[environmentKey], path.hasPrefix("/") else {
            fputs("Missing test report destination\n", stderr); exit(2)
        }
        if model.readOnlyBenchmarkRequested {
            guard let configuration = model.benchmarkConfiguration,
                  URL(fileURLWithPath: path).resolvingSymlinksInPath().path == configuration.report.path,
                  configuration.report.deletingLastPathComponent().resolvingSymlinksInPath().path == configuration.sessionRoot.path else {
                fputs("Benchmark report destination changed; refusing to write\n", stderr); exit(2)
            }
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch { fputs("Cannot write test report: \(error)\n", stderr); exit(2) }
        checkpoint("report.written")
        exit(success ? 0 : 1)
    }

    /// Captures only our rendered content view. No desktop capture or Screen Recording permission.
    private static func saveOwnWindowScreenshot() {
        guard let path = ProcessInfo.processInfo.environment["MOPANEL_SMOKE_SCREENSHOT"], path.hasPrefix("/"),
              let view = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        do { try png.write(to: URL(fileURLWithPath: path), options: .atomic) }
        catch { fputs("Cannot save own-window smoke screenshot: \(error)\n", stderr) }
    }
}
