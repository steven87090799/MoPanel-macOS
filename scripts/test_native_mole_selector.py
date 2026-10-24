#!/usr/bin/env python3
"""Exercise the production selector controller with an acknowledged fake Mole.
No real CLI, keyboard injection or file operations are performed.
"""
import argparse
import json
import os
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
HARNESS = r'''
@MainActor final class FakeMole {
    weak var controller: MoleSelectorController?
    var selected = [true, false]
    var cursor = 0
    var responds = true
    var bytes: [[UInt8]] = []
    func lines() -> [String] {
        ["Select apps to slim  \(selected.filter { $0 }.count)/2 selected", "",
         (cursor == 0 ? "➤ " : "  ") + (selected[0] ? "● " : "○ ") + "Editor · 120 MB",
         (cursor == 1 ? "➤ " : "  ") + (selected[1] ? "● " : "○ ") + "Browser · 80 MB",
         "", "↑↓ | Space Select | Enter Save | Q Cancel"]
    }
    func receive(_ data: Data) {
        let value = Array(data); bytes.append(value)
        guard responds else { return }
        if value == [27, 91, 66] { cursor = min(cursor + 1, 1) }
        if value == [27, 91, 65] { cursor = max(cursor - 1, 0) }
        if value == [32] { selected[cursor].toggle() }
        DispatchQueue.main.async { [weak self] in self?.publish() }
    }
    func publish() { controller?.update(lines(), command: .slim, enabled: true, send: { [weak self] in self?.receive($0) }) }
}
@main struct SelectorIntegration {
    @MainActor static func main() async throws {
        var checks: [String: Bool] = [:]
        func require(_ key: String, _ value: Bool) throws {
            checks[key] = value
            if !value { throw NSError(domain: "MoPanel.SelectorTest", code: 1, userInfo: [NSLocalizedDescriptionKey: key]) }
        }
        func settled(_ controller: MoleSelectorController) async throws {
            let deadline = Date().addingTimeInterval(3)
            while controller.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            try require("operation_settles_within_deadline", !controller.busy)
        }
        let controller = MoleSelectorController(), fake = FakeMole()
        fake.controller = controller; fake.publish()
        try require("actual_mole_defaults_projected", controller.screen?.rows.map(\.selected) == [true, false])
        controller.toggle(controller.screen!.rows[1]); try await settled(controller)
        try require("cursor_acknowledged_before_space", fake.bytes == [[27, 91, 66], [32]] && fake.selected == [true, true])
        try require("selection_read_back_from_mole", controller.screen?.rows.map(\.selected) == [true, true] && controller.reviewed.count == 2)
        fake.cursor = 0; fake.bytes = []; fake.responds = false; fake.publish()
        controller.toggle(controller.screen!.rows[1]); try await settled(controller)
        try require("missing_ack_never_sends_space_or_return", fake.bytes == [[27, 91, 66]] && !controller.message.isEmpty)
        controller.update(["Unknown menu"], command: .slim, enabled: true, send: { fake.receive($0) })
        let before = fake.bytes.count
        controller.submitSelection(); controller.confirm(); controller.cancelConfirmation()
        try require("unknown_screen_sends_no_actions", fake.bytes.count == before)
        controller.update(["➤ Slim 2 apps, 200 MB Enter confirm, ESC cancel:"], command: .slim, enabled: true, send: { fake.receive($0) })
        try require("known_final_confirmation_recognized", controller.confirmation != nil)
        controller.confirm()
        try require("explicit_confirmation_sends_exact_return", fake.bytes.last == [13] && controller.confirmation == nil)
        controller.reset(); fake.bytes = []; fake.responds = true; fake.cursor = 0; fake.publish()
        let row = controller.screen!.rows[0]
        controller.suspend(); controller.toggle(row); controller.submitSelection()
        try require("expanded_terminal_suspends_native_actions", fake.bytes.isEmpty)
        controller.update(fake.lines(), command: .slim, enabled: false, send: { fake.receive($0) })
        try require("unsupported_version_has_no_native_menu", controller.screen == nil && controller.confirmation == nil)
        controller.reset()
        try require("new_operation_discards_old_selection", controller.reviewed.isEmpty && !controller.busy)
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["success": true, "checks": checks, "real_cli_called": false], options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
'''

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()
    source = (ROOT / "Sources/MoPanelApp/MoleSelectorController.swift").read_text()
    marker = "\nstruct MoleSelectorView: View {"
    if source.count(marker) != 1:
        raise RuntimeError("Controller boundary changed; update the test explicitly")
    build_args = ["xcrun", "swift", "build", "--build-system", os.environ.get("MOPANEL_SWIFT_BUILD_SYSTEM", "native"), "-c", "release", "--arch", "arm64", "--show-bin-path"]
    if os.environ.get("MOPANEL_SWIFT_SCRATCH_PATH"): build_args += ["--scratch-path", os.environ["MOPANEL_SWIFT_SCRATCH_PATH"]]
    binaries = pathlib.Path(subprocess.check_output(build_args, cwd=ROOT, text=True).strip())
    modules = binaries if (binaries / "MoPanelCore.swiftmodule").exists() else binaries / "Modules"
    objects = [binaries / "MoPanelCore.o"] if (binaries / "MoPanelCore.o").exists() else sorted((binaries / "MoPanelCore.build").glob("*.swift.o"))
    if not objects:
        raise RuntimeError("Build release ARM64 first")
    with tempfile.TemporaryDirectory(prefix="mopanel-selector-test-") as temporary:
        directory = pathlib.Path(temporary)
        swift = directory / "SelectorIntegration.swift"
        swift.write_text(source.split(marker)[0] + "\n" + HARNESS)
        executable = directory / "SelectorIntegration"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-O", "-target", "arm64-apple-macos27.0", "-I", str(modules), str(swift), *map(str, objects), "-o", str(executable)], cwd=ROOT, check=True, timeout=120)
        completed = subprocess.run([str(executable)], capture_output=True, text=True, check=True, timeout=15)
        report = json.loads(completed.stdout)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps({"success": report["success"], "checks": len(report["checks"]), "report": str(args.output)}))

if __name__ == "__main__": main()
