import Foundation

/// Display-only conversion of human sizes. Never used to authorize a removal
/// or report exact disk space reclaimed.
public struct ReviewSizeEstimate: Equatable, Sendable {
    public let bytes: Int64
    public let lowerBound: Bool
    private static let expression = try? NSRegularExpression(pattern: #"^\s*(至少\s*|>=\s*)?([0-9]+(?:\.[0-9]+)?)\s*(B|BYTE|BYTES|KB|MB|GB|TB|KIB|MIB|GIB|TIB)\s*$"#, options: .caseInsensitive)
    public static func parse(_ text: String) -> Self? {
        guard let expression,
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let numberRange = Range(match.range(at: 2), in: text), let number = Double(text[numberRange]),
              let unitRange = Range(match.range(at: 3), in: text) else { return nil }
        let unit = text[unitRange].uppercased()
        let power: Double
        switch unit { case "KB", "KIB": power = 1; case "MB", "MIB": power = 2; case "GB", "GIB": power = 3; case "TB", "TIB": power = 4; default: power = 0 }
        let bytes = number * pow(1024, power)
        guard bytes.isFinite, bytes >= 0, bytes < Double(Int64.max) else { return nil }
        return Self(bytes: Int64(bytes), lowerBound: match.range(at: 1).location != NSNotFound)
    }
}
