// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

/// Visible AppKit controls used in both normal and fixture launches. Explicit
/// native accessibility identifiers keep primary actions discoverable without
/// relying on SwiftUI's virtual accessibility-node materialization.
@MainActor struct NativeActionButton: NSViewRepresentable {
    enum Appearance { case standard, prominent, warning, icon }
    enum Shortcut { case cancel, defaultAction }

    let title: String
    let identifier: String
    let systemImage: String?
    let appearance: Appearance
    let destructive: Bool
    let shortcut: Shortcut?
    let showsFocusRing: Bool
    let action: () -> Void

    init(_ title: String, identifier: String, systemImage: String? = nil,
         appearance: Appearance = .standard, destructive: Bool = false,
         shortcut: Shortcut? = nil, showsFocusRing: Bool = true,
         action: @escaping () -> Void) {
        self.title = title
        self.identifier = identifier
        self.systemImage = systemImage
        self.appearance = appearance
        self.destructive = destructive
        self.shortcut = shortcut
        self.showsFocusRing = showsFocusRing
        self.action = action
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.activate(_:)))
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .rounded
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.target = context.coordinator
        button.action = #selector(Coordinator.activate(_:))
        button.title = appearance == .icon ? "" : title
        button.isEnabled = context.environment.isEnabled
        button.controlSize = nativeControlSize(context.environment.controlSize)
        button.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: button.controlSize))
        button.isBordered = appearance != .icon
        button.state = .off
        button.hasDestructiveAction = destructive
        button.bezelColor = appearance == .prominent ? MoPanelTheme.nativeAccent : appearance == .warning ? .systemOrange : nil
        button.contentTintColor = appearance == .prominent ? MoPanelTheme.nativeAccentText : appearance == .icon ? .labelColor : nil
        button.focusRingType = showsFocusRing ? .default : .none
        button.image = systemImage.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: appearance == .icon ? title : nil) }
        button.imagePosition = appearance == .icon ? .imageOnly : button.image == nil ? .noImage : .imageLeading
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(title)
        // AppKit can expose the button's cell as the actionable AX element
        // while treating its control view as an ignored container. Keep the
        // same production identity on that real cell; do not change its role,
        // enabled state, ownership, frame, or standard press implementation.
        button.cell?.setAccessibilityIdentifier(identifier)
        button.cell?.setAccessibilityLabel(title)
        button.keyEquivalent = shortcut == .cancel ? "\u{1b}" : shortcut == .defaultAction ? "\r" : ""
        button.keyEquivalentModifierMask = []
        button.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        let size = nsView.intrinsicContentSize
        return CGSize(width: max(appearance == .icon ? 24 : 1, size.width), height: max(24, size.height))
    }

    static func dismantleNSView(_ button: NSButton, coordinator: Coordinator) {
        button.target = nil
        button.action = nil
        coordinator.action = {}
    }

    @MainActor final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func activate(_ sender: NSButton) {
            guard sender.isEnabled else { return }
            action()
            sender.state = .off
        }
    }
}

@MainActor struct NativeAcknowledgementToggle: NSViewRepresentable {
    let title: String
    let identifier: String
    @Binding var isOn: Bool

    init(_ title: String, identifier: String, isOn: Binding<Bool>) {
        self.title = title
        self.identifier = identifier
        _isOn = isOn
    }

    func makeCoordinator() -> Coordinator { Coordinator(isOn: $isOn) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: context.coordinator, action: #selector(Coordinator.toggle(_:)))
        button.allowsMixedState = false
        button.alignment = .left
        button.cell?.wraps = true
        button.cell?.isScrollable = false
        button.cell?.lineBreakMode = .byWordWrapping
        button.setContentHuggingPriority(.required, for: .vertical)
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.isOn = $isOn
        button.target = context.coordinator
        button.action = #selector(Coordinator.toggle(_:))
        button.title = title
        button.isEnabled = context.environment.isEnabled
        button.controlSize = nativeControlSize(context.environment.controlSize)
        button.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: button.controlSize))
        button.state = isOn ? .on : .off
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(title)
        button.cell?.setAccessibilityIdentifier(identifier)
        button.cell?.setAccessibilityLabel(title)
        button.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        let ideal = nsView.intrinsicContentSize
        guard let proposedWidth = proposal.width, proposedWidth.isFinite, proposedWidth > 0 else { return ideal }
        let width = min(max(1, ideal.width), proposedWidth)
        let measured = nsView.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)) ?? ideal
        return CGSize(width: width, height: max(24, measured.height))
    }

    static func dismantleNSView(_ button: NSButton, coordinator: Coordinator) {
        button.target = nil
        button.action = nil
        coordinator.isOn = .constant(false)
    }

    @MainActor final class Coordinator: NSObject {
        var isOn: Binding<Bool>
        init(isOn: Binding<Bool>) { self.isOn = isOn }
        @objc func toggle(_ sender: NSButton) {
            guard sender.isEnabled else { return }
            isOn.wrappedValue = sender.state == .on
        }
    }
}

private func nativeControlSize(_ size: SwiftUI.ControlSize) -> NSControl.ControlSize {
    switch size {
    case .mini: return .mini
    case .small: return .small
    case .regular: return .regular
    case .large, .extraLarge: return .large
    @unknown default: return .regular
    }
}
