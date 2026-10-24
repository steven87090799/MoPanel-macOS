import AppKit
import Foundation
import MoPanelCore

extension AppModel {
    /// Noninteractive output can be exported. Interactive terminal content is
    /// deliberately not retained; its export is an execution summary, not a log.
    func exportOperationOutput() {
        guard let result = operationResult else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = operationIsInteractive ? "MoPanel-execution-summary.txt" : "MoPanel-operation-output.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let summary = [
            operationIsInteractive ? "MoPanel execution summary (interactive content not retained)" : "MoPanel captured operation output",
            "Command: " + operationCommand,
            "Exit: \(result.exitCode)",
            "Cancelled: \(result.cancelled)",
            "Timed out: \(result.timedOut)",
            "Output truncated: \(result.outputTruncated)",
            "Interactive terminal: \(operationIsInteractive)",
            operationIsInteractive ? "The terminal transcript is not stored by MoPanel. This file contains exit state and captured guardian diagnostics only. History shows logs that Mole itself provides; those logs may also be incomplete." : "Only child output is captured. Keyboard input is never logged.",
            "",
            operationIsInteractive ? "--- Interactive output: not retained ---" : "--- Standard output ---",
            operationIsInteractive ? "" : TerminalText.plain(result.stdoutText),
            "",
            "--- Standard error ---",
            TerminalText.plain(result.stderrText)
        ].joined(separator: "\n")
        do { try summary.write(to: url, atomically: true, encoding: .utf8) }
        catch { self.error = error.localizedDescription }
    }
}
