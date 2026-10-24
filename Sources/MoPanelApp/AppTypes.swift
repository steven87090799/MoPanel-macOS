import SwiftUI
import AppKit
import MoPanelCore

enum AppSection: String, CaseIterable, Identifiable {
    case dashboard, clean, uninstall, appUpdates, startup, optimize, analyze, purge, installer, slim, history, tools, settings
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .clean: return "sparkles"
        case .uninstall: return "square.grid.2x2"
        case .appUpdates: return "arrow.triangle.2.circlepath.circle"
        case .startup: return "power.circle"
        case .optimize: return "slider.horizontal.3"
        case .analyze: return "chart.pie"
        case .purge: return "hammer"
        case .installer: return "shippingbox"
        case .slim: return "square.stack.3d.up"
        case .history: return "clock.arrow.circlepath"
        case .tools: return "wrench.and.screwdriver"
        case .settings: return "gearshape"
        }
    }
    var zh: String {
        switch self {
        case .dashboard: return "系統總覽"
        case .clean: return "系統清理"
        case .uninstall: return "軟體卸載"
        case .appUpdates: return "App 更新"
        case .startup: return "啟動項目"
        case .optimize: return "系統最佳化"
        case .analyze: return "磁碟分析"
        case .purge: return "專案清理"
        case .installer: return "安裝檔管理"
        case .slim: return "App 瘦身"
        case .history: return "操作歷史"
        case .tools: return "系統工具"
        case .settings: return "設定"
        }
    }
    var en: String {
        switch self {
        case .appUpdates: return "App Updates"
        case .tools: return "System Tools"
        default: return rawValue.capitalized
        }
    }
    var command: MoleCommand? {
        switch self {
        case .dashboard: return .status
        case .settings, .tools, .appUpdates, .startup: return nil
        default: return MoleCommand(rawValue: rawValue)
        }
    }
}

enum InstallSource: String { case homebrew = "Homebrew", script = "Official installer", nix = "Nix", custom = "Custom / unknown", fixture = "Test fixture" }

struct CLIInstallation {
    let executable: URL
    let resolved: URL
    let version: String
    let versionOutput: String
    let source: InstallSource
    let resourceLocation: String?
    let fingerprint: String
    let help: [MoleCommand: String]
    let incompatible: [MoleCommand: String]
    let compatibility: CompatibilityReport
    var stableVersion: Bool { !version.lowercased().contains("nightly") && !version.lowercased().contains("main") }
}

struct ReleaseInfo: Decodable {
    let tagName: String
    let htmlUrl: URL
    let prerelease: Bool
    let draft: Bool
    let publishedAt: String?
}

struct PendingOperation: Identifiable {
    let id = UUID()
    let invocation: MoleInvocation
    let title: String
    let details: String
    var isRemoval: Bool { invocation.command == .remove && !invocation.isPreview }
}

struct TrendSample: Identifiable {
    let id = UUID()
    let date: Date
    let cpu: Double?
    let memory: Double?
    let diskRead: Double?
    let diskWrite: Double?
    let down: Double?
    let up: Double?
}

struct ActivityEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let command: String
    let outcome: String
}

enum DisplayFormat {
    static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .binary)
    }
    static func bytes(_ value: Int64?) -> String {
        guard let value, value >= 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .binary)
    }
    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f%%", value)
    }
    static func number(_ value: Double?, suffix: String) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f", value) + suffix
    }
}

struct GlassCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
    }
}

struct PageHeading: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 26, weight: .medium)).foregroundStyle(.teal)
                .frame(width: 48, height: 48).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.largeTitle.bold())
                Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }.padding(.bottom, 8)
    }
}

struct Notice: View {
    let text: String
    var warning = false
    var body: some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) }
            icon: { Image(systemName: warning ? "exclamationmark.shield" : "info.circle") }
            .font(.callout).foregroundStyle(warning ? Color.orange : Color.secondary)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(warning ? Color.orange.opacity(0.08) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}
