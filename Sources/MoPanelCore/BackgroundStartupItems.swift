// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct BackgroundStartupItem: Identifiable, Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable { case login, backgroundApp, service }
    public let identifier: String
    public let name: String
    public let developer: String?
    public let userID: Int
    public let url: URL?
    public let executable: String?
    public let parentIdentifier: String?
    public let kind: Kind
    public let enabled: Bool?
    public let typeDescription: String
    public var id: String { "btm:\(userID):" + identifier }
    public var launchLabel: String {
        guard let dot = identifier.firstIndex(of: "."), Int(identifier[..<dot]) != nil else { return identifier }
        return String(identifier[identifier.index(after: dot)...])
    }
}

/// Adapter for Apple's documented `sfltool dumpbtm` diagnostic command.
/// Parsed records are display metadata, never launchctl instructions.
public enum BackgroundStartupParser {
    public static func parse(_ text: String, userID: UInt32) throws -> [BackgroundStartupItem] {
        guard text.utf8.count <= 2 * 1024 * 1024, text.contains("Records for UID") else { throw MoleError.invalidOutput("Unrecognized background-item report.") }
        var uid: Int?, fields: [String: String] = [:], output: [BackgroundStartupItem] = [], seen = Set<String>()
        var records = 0
        func append() {
            defer { fields = [:] }
            guard let uid, uid == Int(userID) || uid == -2, let identifier = fields["Identifier"],
                  !identifier.isEmpty, identifier.utf8.count < 1024,
                  let type = fields["Type"], let name = fields["Name"], !name.isEmpty else { return }
            let typeName = type.lowercased()
            guard !typeName.contains("developer") else { return }
            let disposition = fields["Disposition"]?.lowercased() ?? ""
            let tokens = Set(disposition.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
            let kind: BackgroundStartupItem.Kind
            if typeName.contains("agent") || typeName.contains("daemon") { kind = .service }
            else if typeName.contains("login") { kind = .login }
            else if typeName.hasPrefix("app ") || typeName == "app" { kind = tokens.contains("visible") ? .backgroundApp : .login }
            else { return }
            let enabled: Bool? = tokens.contains("disabled") || tokens.contains("disallowed") ? false
                : tokens.contains("enabled") && tokens.contains("allowed") ? true : nil
            let url = fields["URL"].flatMap(URL.init(string:)).flatMap { url -> URL? in
                guard url.isFileURL, url.host == nil || url.host == "localhost", url.query == nil, url.fragment == nil else { return nil }
                return url.standardizedFileURL
            }
            let item = BackgroundStartupItem(identifier: identifier, name: name, developer: fields["Developer Name"], userID: uid,
                url: url, executable: fields["Executable Path"], parentIdentifier: fields["Parent Identifier"], kind: kind,
                enabled: enabled, typeDescription: type)
            if seen.insert(item.id).inserted { output.append(item) }
        }
        for line in text.components(separatedBy: .newlines) {
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("Records for UID ") {
                append()
                uid = Int(value.dropFirst("Records for UID ".count).prefix { $0 == "-" || $0.isNumber })
            } else if value.hasPrefix("#"), value.hasSuffix(":"), Int(value.dropFirst().dropLast()) != nil {
                append(); records += 1
                guard records <= 10_000 else { throw MoleError.invalidOutput("Too many background-item records.") }
            } else if let colon = value.firstIndex(of: ":") {
                let key = String(value[..<colon])
                if ["Name", "Developer Name", "Type", "Disposition", "Identifier", "URL", "Executable Path", "Parent Identifier"].contains(key) {
                    guard fields[key] == nil else { throw MoleError.invalidOutput("Repeated background-item field.") }
                    fields[key] = String(value[value.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        append()
        guard records > 0 else { throw MoleError.invalidOutput("No recognizable background-item records.") }
        return output
    }
}
