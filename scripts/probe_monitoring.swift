// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@main struct MonitoringProbe {
    struct Failure: Error { let reason: String }
    @MainActor static var checks: [[String: Any]] = []
    @MainActor static func require(_ condition: Bool, _ reason: String) throws {
        if !condition { throw Failure(reason: reason) }
    }
    @MainActor static func check(_ name: String, body: () async throws -> [String: Any]) async {
        do {
            var result = try await body()
            result["name"] = name; result["passed"] = true
            checks.append(result)
        } catch { checks.append(["name": name, "passed": false, "error": String(describing: error)]) }
    }
    @MainActor static func main() async throws {
        guard let helper = ProcessInfo.processInfo.environment["MOPANEL_GUARDIAN"] else { throw Failure(reason: "Missing helper") }
        await check("stream-diagnostics-bounded-without-cancelling") {
            let session = ManagedProcess(helperURL: URL(fileURLWithPath: helper))
            var observed = 0
            session.onError = { observed += $0.count }
            try session.start(request: ProcessRequest(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "/usr/bin/head -c 131072 /dev/zero >&2; printf STREAM-END >&2; printf complete"],
                timeout: 5, outputLimit: 2048, retainsOutput: false))
            let result = await session.wait()
            try require(result.succeeded && observed == 131082, "Collector stopped or dropped delivery: exit=\(result.exitCode), truncated=\(result.outputTruncated), observed=\(observed)")
            try require(result.stderr.count <= 2048 && String(decoding: result.stderr.suffix(10), as: UTF8.self) == "STREAM-END", "Diagnostic tail is not bounded/current")
            try require(result.stdout.isEmpty, "Stream retained snapshots")
            return ["delivered_stderr_bytes": observed, "retained_stderr_bytes": result.stderr.count, "retained_stdout_bytes": result.stdout.count]
        }
        if CommandLine.arguments.last != "stream" {
            await check("capture-stderr-limit-still-cancels") {
                let result = try await ProcessRunner.capture(ProcessRequest(executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "/usr/bin/yes warning >&2"], timeout: 5, outputLimit: 2048), helperURL: URL(fileURLWithPath: helper))
                try require(!result.succeeded && result.outputTruncated && result.stderr.count == 2048, "Capture bounds were weakened")
                return ["retained_stderr_bytes": result.stderr.count]
            }
            await check("preference-persistence-and-normalization") {
                let domain = "MoPanel.Probe.\(UUID().uuidString)"
                guard let defaults = UserDefaults(suiteName: domain) else { throw Failure(reason: "No isolated defaults") }
                defer { defaults.removePersistentDomain(forName: domain) }
                try require(MonitoringPreferences(defaults: defaults) == MonitoringPreferences(), "Missing defaults changed behavior")
                let settings = MonitoringPreferences(interval: 1, menuBarInterval: 30, processAlerts: false, processCPUThreshold: 0, processCPUWindow: 60)
                settings.save(to: defaults)
                try require(MonitoringPreferences(defaults: defaults) == settings, "Settings did not round trip")
                try require(MonitoringPreferences(interval: -1, menuBarInterval: 0, processCPUThreshold: .nan, processCPUWindow: 0) == MonitoringPreferences(), "Invalid saved values escaped normalization")
                return [:]
            }
            await check("sleep-pause-and-adaptive-demand") {
                let settings = MonitoringPreferences(interval: 1, menuBarInterval: 10)
                try require(settings.watchOptions(dashboardVisible: false, lowPowerMode: true).interval == 10, "Menu bar sampled too fast")
                try require(settings.watchOptions(dashboardVisible: true, lowPowerMode: true).interval == 5, "Low Power Mode ignored")
                for menu in [true, false] { for dashboard in [true, false] {
                    try require(!MonitoringDemand.isNeeded(dashboardSelected: dashboard, windowActive: true, menuBarEnabled: menu, paused: false, shuttingDown: false, systemSleeping: true), "Sleeping collector still demanded")
                    try require(!MonitoringDemand.isNeeded(dashboardSelected: dashboard, windowActive: true, menuBarEnabled: menu, paused: true, shuttingDown: false), "Wake cleared explicit pause")
                } }
                return [:]
            }
            await check("timestamp-format-and-cache-cost") {
                let raw = "2026-10-24T18:23:53.772457+08:00"
                let utc = "2026-10-24T10:23:53.772457Z"
                for language in ["zh-Hant", "en"] {
                    let output = StatusTimestampDisplay.string(from: raw, language: language)
                    try require(output == StatusTimestampDisplay.string(from: utc, language: language), "Timestamp lost its timezone")
                    try require(output.contains("2026") && !output.contains(".772457") && !output.contains("+08:00"), "Timestamp remained machine-oriented")
                }
                try require(StatusTimestampDisplay.string(from: "not-a-date", language: "zh-Hant") == "—", "Malformed data leaked into UI")
                let iterations = 2000
                var sink = 0
                let before = DispatchTime.now().uptimeNanoseconds
                for _ in 0..<iterations { autoreleasepool { sink += uncachedTimestamp(raw).count } }
                let middle = DispatchTime.now().uptimeNanoseconds
                for _ in 0..<iterations { autoreleasepool { sink += StatusTimestampDisplay.string(from: raw, language: "zh-Hant").count } }
                let after = DispatchTime.now().uptimeNanoseconds
                return ["iterations": iterations, "uncached_seconds": Double(middle - before) / 1e9,
                        "cached_seconds": Double(after - middle) / 1e9, "output_characters": sink,
                        "scope": "formatter microbenchmark, not App CPU/RSS/Energy"]
            }
        }
        let report: [String: Any] = ["checks": checks, "passed": checks.allSatisfy { $0["passed"] as? Bool == true },
                                    "platform": ProcessInfo.processInfo.operatingSystemVersionString]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        if checks.contains(where: { $0["passed"] as? Bool != true }) { exit(1) }
    }
    @MainActor static func uncachedTimestamp(_ value: String) -> String {
        let input = ISO8601DateFormatter()
        input.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = input.date(from: value) else { return value }
        let output = DateFormatter()
        output.locale = Locale(identifier: "zh_TW"); output.calendar = Calendar(identifier: .gregorian)
        output.timeZone = .current; output.dateStyle = .medium; output.timeStyle = .medium
        return output.string(from: date)
    }
}
