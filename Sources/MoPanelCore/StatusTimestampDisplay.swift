// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Formatters are actor-confined and reused across all monitoring consumers.
@MainActor public enum StatusTimestampDisplay {
    private static let fractionalInput: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let wholeInput = ISO8601DateFormatter()
    private static let chineseOutput = output(locale: "zh_TW")
    private static let englishOutput = output(locale: "en_US")

    private static func output(locale: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: locale)
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }

    public static func string(from value: String, language: String) -> String {
        if let date = fractionalInput.date(from: value) ?? wholeInput.date(from: value) {
            return (language == "en" ? englishOutput : chineseOutput).string(from: date)
        }
        // A fractional-precision change must not leak a raw timestamp into UI.
        let stem = String(value.prefix(19))
        let fields = stem.split(whereSeparator: { "-T:".contains($0) })
        guard fields.count == 6, fields[0].count == 4,
              let year = Int(fields[0]), (1...9999).contains(year),
              let month = Int(fields[1]), (1...12).contains(month),
              let day = Int(fields[2]), (1...31).contains(day),
              let hour = Int(fields[3]), (0...23).contains(hour),
              let minute = Int(fields[4]), (0...59).contains(minute),
              let second = Int(fields[5]), (0...59).contains(second) else { return "—" }
        return stem.replacingOccurrences(of: "T", with: " ")
            .replacingOccurrences(of: "-", with: language == "en" ? "-" : "/")
    }
}
