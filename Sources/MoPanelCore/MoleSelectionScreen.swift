import Foundation

/// Projection of the known V1.62 terminal selector, never a file deletion plan.
/// Actions still go to Mole, which owns selection and final path validation.
public struct MoleSelectionScreen: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public let line: Int
        public let text: String
        public let selected: Bool
        public let focused: Bool
        public var id: String { text }
    }
    public let title: String
    public let rows: [Row]
    public var focused: Row? { rows.first(where: \.focused) }
    public static func supports(command: MoleCommand, version: String) -> Bool {
        [.installer, .slim, .purge].contains(command) && version.trimmingCharacters(in: CharacterSet(charactersIn: "vV")) == "1.62.0"
    }
    public static func parse(_ lines: [String], command: MoleCommand) -> Self? {
        let prefix: String
        switch command {
        case .installer: prefix = "Select Installers to Remove"
        case .slim: prefix = "Select apps to slim"
        case .purge: prefix = "Select Artifacts to Purge"
        default: return nil
        }
        guard lines.count <= 80, lines.joined().utf8.count <= 32_768,
              let header = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix) }),
              let footer = lines.lastIndex(where: { $0.contains("Space Select") }),
              header < footer, lines[footer...].joined(separator: " ").contains("Enter "),
              lines[footer...].joined(separator: " ").contains("Q ") else { return nil }
        var rows: [Row] = []
        for index in (header + 1)..<footer {
            var text = lines[index].trimmingCharacters(in: .whitespaces)
            let focused = text.hasPrefix("➤ ")
            if focused { text = String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            guard text.hasPrefix("○ ") || text.hasPrefix("● ") else { continue }
            let selected = text.hasPrefix("● ")
            let label = String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, label.utf8.count <= 2048,
                  !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            rows.append(Row(line: index, text: label, selected: selected, focused: focused))
        }
        guard !rows.isEmpty, rows.count <= 64, rows.filter(\.focused).count == 1,
              Set(rows.map(\.text)).count == rows.count else { return nil }
        return Self(title: lines[header].trimmingCharacters(in: .whitespaces), rows: rows)
    }
}
