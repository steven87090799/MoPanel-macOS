// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import MoPanelCore
import MoPanelProcess

/// A user-requested diagnostic only. Apple's launchctl manual describes blame
/// as the most proximate reason, not a full history or a production contract.
@MainActor enum ProcessLaunchReasonReader {
    static func read(_ details: ProcessDetails) async -> ProcessLaunchEvidence? {
        do {
            let listing = try await ProcessRunner.capture(.init(executable: URL(fileURLWithPath: "/bin/launchctl"),
                arguments: ["list"], environment: ["LC_ALL": "C", "LANG": "C"], timeout: 3, outputLimit: 1024 * 1024))
            guard listing.succeeded, !listing.outputTruncated,
                  let label = ProcessLaunchEvidence.serviceLabel(in: String(decoding: listing.stdout, as: UTF8.self), pid: details.pid) else { return nil }
            let result = try await ProcessRunner.capture(.init(executable: URL(fileURLWithPath: "/bin/launchctl"),
                arguments: ["blame", "gui/\(getuid())/" + label], environment: ["LC_ALL": "C", "LANG": "C"], timeout: 3, outputLimit: 4096))
            guard result.succeeded, !result.outputTruncated, result.stderr.isEmpty,
                  let fresh = ProcessDetailsReader.read(pid: details.pid), fresh.startedAt == details.startedAt,
                  fresh.executable == details.executable else { return nil }
            let reason = TerminalText.plain(String(decoding: result.stdout, as: UTF8.self)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reason.isEmpty, reason.utf8.count <= 1024 else { return nil }
            return ProcessLaunchEvidence(service: label, reason: reason)
        } catch { return nil }
    }
}
