import Foundation

public struct OperationProgressEntry: Identifiable, Sendable {
    public enum State: String, Sendable { case completed, skipped, failed, working }
    public let id = UUID()
    public let text: String
    public let state: State
}

/// Human-facing progress only. These text entries never authorize file operations.
public struct OperationProgressSummary {
    private var pending = Data()
    public private(set) var entries: [OperationProgressEntry] = []
    public var pendingText: String { TerminalText.plain(String(decoding: pending, as: UTF8.self)) }
    public init() {}
    public mutating func append(_ data: Data) {
        for byte in data {
            if byte == 10 || byte == 13 { flush() }
            else if pending.count < 8192 { pending.append(byte) }
        }
    }
    public mutating func finish() { flush() }
    private mutating func flush() {
        defer { pending.removeAll(keepingCapacity: true) }
        let line = TerminalText.plain(String(decoding: pending, as: UTF8.self)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        let lower = line.lowercased()
        let state: OperationProgressEntry.State
        if lower.hasPrefix("failed") || line.hasPrefix("✗") || line.hasPrefix("✘") || lower.contains("permission denied") || lower.contains("authentication failure") || lower.hasPrefix("error:") { state = .failed }
        else if line.hasPrefix("⚠") || lower.contains("skipped") || lower.hasPrefix("skip ") { state = .skipped }
        else if line.hasPrefix("✓") || line.hasPrefix("✔") || lower.hasPrefix("would remove") || lower.hasPrefix("would delete") || lower.hasPrefix("cleaned ") || lower.hasPrefix("removed ") { state = .completed }
        else if line.hasPrefix("▶") || line.hasPrefix("→") || lower.hasPrefix("scanning ") || lower.hasPrefix("checking ") { state = .working }
        else { return }
        let text = String(line.prefix(300))
        guard entries.last?.text != text else { return }
        entries.append(OperationProgressEntry(text: text, state: state))
        if entries.count > 100 { entries.removeFirst(entries.count - 100) }
    }
}
