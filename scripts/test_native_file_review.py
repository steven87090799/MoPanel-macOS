#!/usr/bin/env python3
"""Run the production native review controller against nonce-owned macOS fixtures.

No installed user application, real app preferences or existing file is selected.
The only actual Trash moves are freshly created fake app/cache fixtures.
"""
import argparse
import json
import os
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
HARNESS = r'''
@main struct NativeReviewIntegration {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let nonce = "org.mopanel.disposable." + UUID().uuidString.lowercased()
        let appRoot = home.appendingPathComponent("Applications")
        let createdAppRoot = !fm.fileExists(atPath: appRoot.path)
        let app = appRoot.appendingPathComponent(nonce + ".app")
        let cache = home.appendingPathComponent("Library/Caches/" + nonce)
        let prefs = home.appendingPathComponent("Library/Preferences/" + nonce + ".plist")
        let info = app.appendingPathComponent("Contents/Info.plist")
        var receipts: [ReviewMoveReceipt] = []
        var checks: [String: Bool] = [:]
        func require(_ key: String, _ value: Bool) throws {
            checks[key] = value
            if !value { throw NSError(domain: "MoPanel.NativeReviewTest", code: 1, userInfo: [NSLocalizedDescriptionKey: key]) }
        }
        // Only exact random names created in this run may be removed, including
        // their confirmed system-returned Trash destinations.
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cache.path)
            for url in [app, cache, prefs] + receipts.map(\.trash) {
                if url.lastPathComponent.contains(nonce), fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
            }
            if createdAppRoot, (try? fm.contentsOfDirectory(atPath: appRoot.path).isEmpty) == true { try? fm.removeItem(at: appRoot) }
        }
        try require("nonce_paths_do_not_exist", [app, cache, prefs].allSatisfy { !fm.fileExists(atPath: $0.path) })
        try fm.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("MoPanel disposable cache".utf8).write(to: cache.appendingPathComponent("fixture.bin"), options: .withoutOverwriting)
        try Data("MoPanel disposable preference; keep unchecked".utf8).write(to: prefs, options: .withoutOverwriting)
        func writeID(_ id: String) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundleName": nonce, "CFBundlePackageType": "APPL"], format: .xml, options: 0)
            try data.write(to: info)
        }
        try writeID(nonce)
        func inventory(_ source: String = "app") throws -> InstalledApp {
            let data = try JSONSerialization.data(withJSONObject: ["name": nonce, "bundleId": nonce, "source": source, "uninstallName": nonce, "path": app.path, "size": "1 KB"])
            return try JSONDecoder().decode(InstalledApp.self, from: data)
        }
        let controller = FileReviewController()
        await controller.prepareApps([try inventory()])
        try require("app_cache_and_personal_file_discovered", Set(controller.files.map(\.id)) == Set([app.path, cache.path, prefs.path]))
        try require("recommended_app_and_cache_preselected", controller.selected == Set([app.path, cache.path]))
        try require("personal_data_unselected_and_keep_recommendation", controller.files.first { $0.id == prefs.path }?.recommended == false && !controller.selected.contains(prefs.path))
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: cache.path)
        await controller.prepareApps([try inventory()], force: true)
        try require("unreadable_cache_blocked_before_selection", controller.files.first { $0.id == cache.path }?.selectable == false && !controller.selected.contains(cache.path))
        try require("unreadable_capacity_not_reported_as_zero", controller.files.first { $0.id == cache.path }?.size == "大小未能讀取")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cache.path)
        await controller.prepareApps([try inventory()], force: true)
        controller.confirming = true
        await controller.execute()
        try require("disabled_test_controller_cannot_mutate", fm.fileExists(atPath: app.path) && fm.fileExists(atPath: cache.path))
        controller.allowsChanges = true
        controller.confirming = false
        await controller.execute()
        try require("no_confirmation_cannot_mutate", fm.fileExists(atPath: app.path) && fm.fileExists(atPath: cache.path))
        controller.selected = []; controller.confirming = true
        await controller.execute()
        try require("no_selection_cannot_mutate", fm.fileExists(atPath: app.path) && fm.fileExists(atPath: cache.path))
        controller.recommend()
        try writeID(nonce + ".changed")
        controller.confirming = true
        await controller.execute()
        try require("changed_bundle_identifier_blocks_both_app_and_related_files", controller.receipts.isEmpty && controller.errors.count == 2 && fm.fileExists(atPath: app.path) && fm.fileExists(atPath: cache.path))
        try writeID(nonce)
        await controller.prepareApps([try inventory("cask")], force: true)
        try require("package_manager_app_and_related_files_are_read_only", controller.files.allSatisfy { !$0.selectable } && controller.selected.isEmpty)
        await controller.prepareApps([try inventory()], force: true)
        controller.confirming = true
        await controller.execute()
        receipts = controller.receipts
        try require("two_confirmed_native_trash_moves", receipts.count == 2 && controller.errors.isEmpty)
        try require("selected_original_paths_absent", !fm.fileExists(atPath: app.path) && !fm.fileExists(atPath: cache.path))
        try require("unchecked_personal_preference_retained", fm.fileExists(atPath: prefs.path))
        try require("system_returned_trash_destinations_exist", receipts.allSatisfy { $0.trash.lastPathComponent.contains(nonce) && fm.fileExists(atPath: $0.trash.path) })
        try require("removed_results_remain_visible_and_retained_file_stays_in_review", controller.removedPaths == Set([app.path, cache.path]) && controller.files.map(\.id) == [prefs.path])
        try require("successful_run_has_no_unresolved_items", controller.lastRun?.moved == 2 && controller.lastRun?.hasUnresolvedItems == false && controller.progress == 1)
        // Re-create only the same nonce-owned fixture names. One item becomes
        // inaccessible after selection, so the production pre-execution check
        // must preserve it while accurately retaining the successful receipt.
        try fm.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try writeID(nonce)
        await controller.prepareApps([try inventory()], force: true)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: cache.path)
        controller.confirming = true
        await controller.execute()
        receipts += controller.receipts
        try require("partial_run_has_one_success_and_one_failure", controller.lastRun?.moved == 1 && controller.lastRun?.failed == 1 && controller.lastRun?.hasUnresolvedItems == true)
        try require("failed_item_not_selected_or_retried", controller.files.first { $0.id == cache.path }?.selectable == false && !controller.selected.contains(cache.path))
        try require("failed_item_kept_and_detailed_result_retained", fm.fileExists(atPath: cache.path) && controller.failures.count == 1 && controller.failures.first?.url.path == cache.path)
        try require("partial_run_progress_reaches_processed_plan", controller.progress == 1 && controller.lastRun?.unprocessed == 0)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cache.path)
        let report: [String: Any] = ["success": true, "checks": checks, "real_trash_moves": receipts.count, "user_files_changed": false,
                                    "scope": "Production FileReviewController; only nonce-owned fake .app/cache/preferences created in this run. Fixtures and their confirmed Trash destinations cleaned afterwards."]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()
    source = (ROOT / "Sources/MoPanelApp/FileReviewController.swift").read_text()
    marker = "\nstruct FileReviewView: View {"
    if source.count(marker) != 1:
        raise RuntimeError("Production controller boundary changed; update this test explicitly")
    build_args = ["xcrun", "swift", "build", "--build-system", os.environ.get("MOPANEL_SWIFT_BUILD_SYSTEM", "native"), "-c", "release", "--arch", "arm64", "--show-bin-path"]
    if os.environ.get("MOPANEL_SWIFT_SCRATCH_PATH"): build_args += ["--scratch-path", os.environ["MOPANEL_SWIFT_SCRATCH_PATH"]]
    binaries = pathlib.Path(subprocess.check_output(build_args, cwd=ROOT, text=True).strip())
    modules = binaries if (binaries / "MoPanelCore.swiftmodule").exists() else binaries / "Modules"
    objects = [binaries / "MoPanelCore.o"] if (binaries / "MoPanelCore.o").exists() else sorted((binaries / "MoPanelCore.build").glob("*.swift.o"))
    if not objects or not (modules / "MoPanelCore.swiftmodule").exists():
        raise RuntimeError("Build the release app first with the full Xcode environment")
    with tempfile.TemporaryDirectory(prefix="mopanel-native-review-") as temporary:
        directory = pathlib.Path(temporary)
        swift = directory / "NativeReviewIntegration.swift"
        swift.write_text(source.split(marker)[0] + "\n" + HARNESS)
        executable = directory / "NativeReviewIntegration"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-O", "-target", "arm64-apple-macos27.0", "-I", str(modules), str(swift), *map(str, objects), "-o", str(executable)], cwd=ROOT, check=True, timeout=120)
        outcome = subprocess.run([str(executable)], cwd=ROOT, text=True, capture_output=True, timeout=45)
        if outcome.returncode:
            raise RuntimeError(outcome.stderr[-4000:] or outcome.stdout[-4000:])
        report = json.loads(outcome.stdout)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps({"success": report["success"], "checks": len(report["checks"]), "real_trash_moves": report["real_trash_moves"], "report": str(args.output)}))

if __name__ == "__main__":
    main()
