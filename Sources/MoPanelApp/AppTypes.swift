import SwiftUI
import AppKit
import MoPanelCore

enum AppSection: String, CaseIterable, Identifiable {
    case dashboard, clean, uninstall, appUpdates, startup, optimize, analyze, purge, worktrees, installer, slim, history, tools, settings
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
        case .worktrees: return "arrow.triangle.branch"
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
        case .worktrees: return "Git 工作目錄"
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
        case .worktrees: return "Git Worktrees"
        case .tools: return "System Tools"
        default: return rawValue.capitalized
        }
    }
    var command: MoleCommand? {
        switch self {
        case .dashboard: return .status
        case .settings, .tools, .appUpdates, .startup, .worktrees: return nil
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
    var gpu: Double? = nil
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
    @MainActor static func timestamp(_ value: String, language: String) -> String {
        StatusTimestampDisplay.string(from: value, language: language)
    }
}

struct MoPanelGlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            content
                .background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay { shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1) }
        } else {
            content.glassEffect(.regular.interactive(), in: shape)
        }
    }
}

extension View {
    func moPanelGlass(cornerRadius: CGFloat) -> some View {
        modifier(MoPanelGlassSurface(cornerRadius: cornerRadius))
    }
}

struct GlassCard<Content: View>: View {
    private let minHeight: CGFloat?
    private let content: Content

    init(minHeight: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.minHeight = minHeight
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .moPanelGlass(cornerRadius: 20)
    }
}

struct MoPanelGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label.font(.headline)
            configuration.content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .moPanelGlass(cornerRadius: 18)
    }
}

struct PageHeading: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 26, weight: .medium)).foregroundStyle(MoPanelTheme.accent)
                .frame(width: 48, height: 48).moPanelGlass(cornerRadius: 14)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(.largeTitle, design: .rounded).weight(.bold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
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
            .background(warning ? Color.orange.opacity(0.08) : MoPanelTheme.accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(warning ? Color.orange.opacity(0.65) : MoPanelTheme.accent.opacity(0.45))
                    .frame(width: 3)
                    .padding(.vertical, 8)
            }
    }
}
