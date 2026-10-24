import AppKit
import Foundation
import MoPanelCore

extension AppModel {
    /// Only output emitted by the child process is exported. Keyboard input is
    /// never recorded. A truncated capture is explicitly labelled incomplete.
    func exportOperationOutput() {
        guard let result = operationResult else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MoPanel-operation.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let summary = [
            "MoPanel operation output",
            "Command: " + operationCommand,
            "Exit: \(result.exitCode)",
            "Cancelled: \(result.cancelled)",
            "Timed out: \(result.timedOut)",
            "Output truncated: \(result.outputTruncated)",
            "",
            "--- Standard output / PTY output ---",
            TerminalText.plain(result.stdoutText),
            "",
            "--- Standard error ---",
            TerminalText.plain(result.stderrText)
        ].joined(separator: "\n")
        do { try summary.write(to: url, atomically: true, encoding: .utf8) }
        catch { self.error = error.localizedDescription }
    }
}
