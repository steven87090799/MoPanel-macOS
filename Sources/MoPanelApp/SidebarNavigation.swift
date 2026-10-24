import SwiftUI
import AppKit

/// A fixed icon rail and a sliding text drawer. Labels keep their full layout
/// while the outer edge moves; glyphs never scale or reflow during the slide.
struct SidebarNavigation: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var isCompact: Bool
    @FocusState private var focusedSection: AppSection?
    @State private var hoveringToggle = false

    private var width: CGFloat { isCompact ? 72 : 230 }
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    NativeActionButton(model.t(isCompact ? "展開側邊欄" : "收合側邊欄",
                                               isCompact ? "Expand Sidebar" : "Collapse Sidebar"),
                                       identifier: "mopanel.sidebar.toggle", systemImage: "sidebar.left",
                                       appearance: .icon, showsFocusRing: false) {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) { isCompact.toggle() }
                    }
                    .frame(width: 30, height: 30)
                    .background(.primary.opacity(hoveringToggle ? 0.08 : 0.035),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .onHover { hoveringToggle = $0 }
                    .help(model.t(isCompact ? "展開側邊欄" : "收合側邊欄",
                                  isCompact ? "Expand Sidebar" : "Collapse Sidebar"))
                    .focusEffectDisabled()
                    .position(x: isCompact ? 36 : 201, y: 21)
                }.frame(height: 42)
                HStack(spacing: 0) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable().interpolation(.high).scaledToFit()
                        .frame(width: 28, height: 28)
                        .frame(width: 52)
                        .accessibilityHidden(true)
                    drawerText {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("MoPanel").font(.title2.bold()).lineLimit(1)
                            Text(model.t("非官方原生介面", "Unofficial native interface"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }.frame(width: 210, height: 56, alignment: .leading)
                    .frame(width: width - 20, alignment: .leading).clipped().padding(.horizontal, 10)
            }.frame(height: 110, alignment: .top)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(AppSection.allCases) { section in
                        SidebarNavigationRow(title: model.t(section.zh, section.en), symbol: section.symbol,
                                             isCompact: isCompact, isSelected: model.section == section,
                                             identifier: "mopanel.sidebar.route." + section.rawValue) {
                            focusedSection = section
                            model.section = section
                        }
                        .focused($focusedSection, equals: section)
                    }
                }.padding(.horizontal, 10).padding(.vertical, 4)
            }
            .onMoveCommand { direction in
                guard direction == .up || direction == .down,
                      let index = AppSection.allCases.firstIndex(of: focusedSection ?? model.section) else { return }
                let next = min(max(index + (direction == .up ? -1 : 1), 0), AppSection.allCases.count - 1)
                focusedSection = AppSection.allCases[next]
                model.section = AppSection.allCases[next]
            }

            HStack(spacing: 0) {
                Image(systemName: model.installation == nil ? "circle.dashed" : "checkmark.circle")
                    .font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 52)
                drawerText {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.installation.map { "Mole \($0.version)" } ?? model.t("尚未連接 CLI", "CLI not connected"))
                            .font(.caption.weight(.medium)).lineLimit(1)
                        Text(model.t("清理由官方 CLI 執行", "Powered by the official CLI"))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }.frame(width: 210, height: 74, alignment: .leading)
                .frame(width: width - 20, alignment: .leading).clipped().padding(.horizontal, 10)
                .help(model.installation.map { "Mole \($0.version)" } ?? model.t("尚未連接 CLI", "CLI not connected"))
        }
        .frame(width: width).frame(maxHeight: .infinity)
        .background(SidebarMaterial().accessibilityHidden(true))
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.t("導覽列", "Navigation"))
        .accessibilityIdentifier("mopanel.sidebar")
    }

    private func drawerText<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content().frame(width: 158, alignment: .leading)
            .offset(x: isCompact ? -18 : 0).opacity(isCompact ? 0 : 1)
            .frame(width: 158, alignment: .leading).clipped()
            .accessibilityHidden(isCompact)
    }
}

private struct SidebarNavigationRow: View {
    let title: String
    let symbol: String
    let isCompact: Bool
    let isSelected: Bool
    let identifier: String
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Image(systemName: symbol).font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isSelected ? MoPanelTheme.accent : Color.secondary)
                    .frame(width: 52)
                Text(title).font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(.primary).lineLimit(1).frame(width: 158, alignment: .leading)
                    .offset(x: isCompact ? -18 : 0).opacity(isCompact ? 0 : 1)
                    .frame(width: 158, alignment: .leading).clipped()
                    .accessibilityHidden(isCompact)
            }
            .frame(width: 210, height: 36, alignment: .leading)
            .frame(width: isCompact ? 52 : 210, alignment: .leading)
            .clipped()
            .background(.primary.opacity(isSelected ? 0.09 : hovered ? 0.045 : 0),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(MoPanelTheme.accent.opacity(isSelected ? 0.2 : 0), lineWidth: 0.7)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(SidebarNavigationButtonStyle())
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
        .focusEffectDisabled()
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = SidebarSurfaceView()
        view.identifier = NSUserInterfaceItemIdentifier("mopanel.sidebar.surface")
        view.blendingMode = .withinWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = context.environment.accessibilityReduceTransparency ? .windowBackground : .sidebar
    }
}

private final class SidebarSurfaceView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}

private struct SidebarNavigationButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
