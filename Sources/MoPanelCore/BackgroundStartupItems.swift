// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct BackgroundLoginHelper: Equatable, Sendable {
    public let name: String
    public let url: URL?
    public let enabled: Bool?
}

public struct BackgroundStartupItem: Identifiable, Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable { case login, backgroundApp, service }
    public let identifier: String
    public let name: String
    public let developer: String?
    public let userID: Int
    public let url: URL?
    public let executable: String?
    public let parentIdentifier: String?
    public let associatedAppURL: URL?
    public let bundleIdentifier: String?
    public let loginHelpers: [BackgroundLoginHelper]
    public let kind: Kind
    public let enabled: Bool?
    public let typeDescription: String
    public var id: String { "btm:\(userID):" + identifier }
    public var launchLabel: String { Self.untypedIdentifier(identifier) }
    public var isDaemon: Bool { typeDescription.lowercased().contains("daemon") }

    /// Metadata matching only. Report records never authorize a launchctl change.
    public func matchesPlist(url: URL, label: String?, scope: StartupScope) -> Bool {
        guard kind == .service, isDaemon == (scope == .systemDaemon) else { return false }
        if self.url?.standardizedFileURL == url.standardizedFileURL { return true }
        guard let label, label == launchLabel else { return false }
        // A home LaunchAgent and a shared LaunchAgent can have the same label.
        // A reported absolute registration path must remain in the same scope.
        if let path = self.url?.path {
            if path.hasPrefix("/Library/LaunchAgents/") { return scope == .sharedAgent }
            if path.hasPrefix("/Users/") && path.contains("/Library/LaunchAgents/") { return scope == .userAgent }
        }
        return true
    }

    fileprivate static func untypedIdentifier(_ value: String) -> String {
        guard let dot = value.firstIndex(of: "."), Int(value[..<dot]) != nil else { return value }
        return String(value[value.index(after: dot)...])
    }
}

/// Adapter for Apple's documented `sfltool dumpbtm` diagnostic command.
/// Parsed records are display metadata, never launchctl instructions.
public enum BackgroundStartupParser {
    private struct Record {
        let uid: Int
        let fields: [String: String]
        var identifier: String { fields["Identifier"] ?? "" }
        var type: String { (fields["Type"] ?? "").components(separatedBy: "(")[0].trimmingCharacters(in: .whitespaces).lowercased() }
        var key: String { "\(uid):" + identifier }
        var tokens: Set<String> {
            Set((fields["Disposition"] ?? "").lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
        }
        var launchEnabled: Bool? { state(positive: "enabled", negative: "disabled") }
        var allowed: Bool? { state(positive: "allowed", negative: "disallowed") }
        var enabled: Bool? {
            if launchEnabled == false || allowed == false { return false }
            return launchEnabled == true && allowed == true ? true : nil
        }
        private func state(positive: String, negative: String) -> Bool? {
            let yes = tokens.contains(positive), no = tokens.contains(negative)
            return yes == no ? nil : yes
        }
    }

    public static func parse(_ text: String, userID: UInt32) throws -> [BackgroundStartupItem] {
        guard text.utf8.count <= 2 * 1024 * 1024, text.contains("Records for UID") else { throw MoleError.invalidOutput("Unrecognized background-item report.") }
        var uid: Int?, fields: [String: String] = [:], records: [Record] = []
        var count = 0, hasCurrentUserSection = false
        func append() {
            defer { fields = [:] }
            guard let uid, uid == Int(userID) || uid == -2,
                  let identifier = fields["Identifier"], !identifier.isEmpty, identifier.utf8.count < 1024,
                  let name = fields["Name"], !name.isEmpty, fields["Type"] != nil else { return }
            records.append(Record(uid: uid, fields: fields))
        }
        for line in text.components(separatedBy: .newlines) {
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("Records for UID ") {
                append()
                uid = Int(value.dropFirst("Records for UID ".count).prefix { $0 == "-" || $0.isNumber })
                if uid == Int(userID) { hasCurrentUserSection = true }
            } else if value.hasPrefix("#"), value.hasSuffix(":"), Int(value.dropFirst().dropLast()) != nil {
                append(); count += 1
                guard count <= 10_000 else { throw MoleError.invalidOutput("Too many background-item records.") }
            } else if let colon = value.firstIndex(of: ":") {
                let key = String(value[..<colon])
                if ["Name", "Developer Name", "Type", "Disposition", "Identifier", "URL", "Executable Path", "Parent Identifier", "Bundle Identifier"].contains(key) {
                    guard fields[key] == nil else { throw MoleError.invalidOutput("Repeated background-item field.") }
                    fields[key] = String(value[value.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        append()
        guard count > 0, hasCurrentUserSection else { throw MoleError.invalidOutput("No recognizable background-item records for this user.") }

        let apps = records.filter { $0.type == "app" }
        var appIndex: [String: Record] = [:]
        for app in apps where appIndex[app.key] == nil { appIndex[app.key] = app }
        func parent(of record: Record) -> Record? {
            guard let identifier = record.fields["Parent Identifier"] else { return nil }
            return appIndex["\(record.uid):" + identifier] ?? appIndex["-2:" + identifier]
        }
        func appURL(_ record: Record) -> URL? { localURL(record.fields["URL"]) }
        func recordURL(_ record: Record) -> URL? { localURL(record.fields["URL"], base: parent(of: record).flatMap(appURL)) }
        var helpers: [String: [BackgroundLoginHelper]] = [:]
        for record in records where record.uid == Int(userID) && record.type == "login item" {
            // Embedded login helpers belong to their app's details, rather than
            // appearing as extra top-level login apps.
            if let owner = parent(of: record), let displayedOwner = appIndex["\(userID):" + owner.identifier] {
                helpers[displayedOwner.key, default: []].append(.init(name: record.fields["Name"]!, url: recordURL(record), enabled: record.enabled))
            }
        }
        let currentServices = Set(records.filter { $0.uid == Int(userID) && ["agent", "legacy agent"].contains($0.type) }
            .map { $0.identifier + "\n" + (recordURL($0)?.path ?? "") })
        var output: [BackgroundStartupItem] = [], seen = Set<String>()
        for record in records {
            let kind: BackgroundStartupItem.Kind
            switch record.type {
            case "app":
                // System/root app registrations supply parent metadata, not
                // additional apps in this user's login/background lists.
                guard record.uid == Int(userID) else { continue }
                kind = record.launchEnabled == true ? .login : .backgroundApp
            case "login item":
                guard record.uid == Int(userID) else { continue }
                if let owner = parent(of: record), appIndex["\(userID):" + owner.identifier] != nil { continue }
                kind = .login
            case "agent", "legacy agent":
                if record.uid == -2, currentServices.contains(record.identifier + "\n" + (recordURL(record)?.path ?? "")) { continue }
                kind = .service
            case "daemon", "legacy daemon": kind = .service
            default: continue
            }
            let owner = parent(of: record)
            let associated = record.type == "app" ? appURL(record) : owner.flatMap(appURL)
            let executable = localURL(record.fields["Executable Path"], base: associated)?.path
            let item = BackgroundStartupItem(identifier: record.identifier, name: record.fields["Name"]!,
                developer: nonempty(record.fields["Developer Name"]) ?? owner.flatMap { nonempty($0.fields["Developer Name"]) },
                userID: record.uid, url: recordURL(record), executable: executable,
                parentIdentifier: nonempty(record.fields["Parent Identifier"]), associatedAppURL: associated,
                bundleIdentifier: nonempty(record.fields["Bundle Identifier"]) ?? owner.flatMap { nonempty($0.fields["Bundle Identifier"]) },
                loginHelpers: helpers[record.key] ?? [], kind: kind,
                enabled: kind == .backgroundApp ? record.allowed : record.enabled, typeDescription: record.fields["Type"]!)
            if seen.insert(item.id).inserted { output.append(item) }
        }
        return output
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty, !["(null)", "null"].contains(value.lowercased()) else { return nil }
        return value
    }

    private static func localURL(_ value: String?, base: URL? = nil) -> URL? {
        guard let value = nonempty(value), !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !value.split(separator: "/").contains("..") else { return nil }
        if value.hasPrefix("/") { return URL(fileURLWithPath: value).standardizedFileURL }
        if value.hasPrefix("Contents/"), let base { return base.appendingPathComponent(value).standardizedFileURL }
        guard let url = URL(string: value), url.isFileURL,
              url.host == nil || url.host == "localhost", url.query == nil, url.fragment == nil,
              url.path.hasPrefix("/"), !url.path.split(separator: "/").contains("..") else { return nil }
        return url.standardizedFileURL
    }
}
