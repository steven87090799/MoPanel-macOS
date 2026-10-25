import AppKit
import SwiftUI

enum MoPanelTheme {
    static let nativeAccent = NSColor(name: "MoPanelAccent") { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.86, green: 0.72, blue: 0.48, alpha: 1)
        }
        return NSColor(srgbRed: 0.48, green: 0.34, blue: 0.15, alpha: 1)
    }
    static let nativeAccentText = NSColor(name: "MoPanelAccentText") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .white
    }
    static let accent = Color(nsColor: nativeAccent)
    static let positive = Color(nsColor: NSColor(name: "MoPanelPositive") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.43, green: 0.69, blue: 0.54, alpha: 1)
            : NSColor(srgbRed: 0.18, green: 0.42, blue: 0.27, alpha: 1)
    })
    static let chartSecondary = Color(red: 0.43, green: 0.55, blue: 0.78)
}

/// Static lighting gives the glass a backdrop without an always-running animation.
struct MoPanelBackdrop: View {
    var translucent = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ZStack {
            if translucent && !reduceTransparency {
                Rectangle().fill(.ultraThinMaterial)
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
            if !reduceTransparency {
                RadialGradient(colors: [MoPanelTheme.accent.opacity(colorScheme == .dark ? 0.15 : 0.07), .clear],
                               center: .topLeading, startRadius: 0, endRadius: 680)
                RadialGradient(colors: [MoPanelTheme.chartSecondary.opacity(colorScheme == .dark ? 0.11 : 0.055), .clear],
                               center: .bottomTrailing, startRadius: 0, endRadius: 720)
                LinearGradient(colors: [.white.opacity(colorScheme == .dark ? 0.025 : 0.12), .clear],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
