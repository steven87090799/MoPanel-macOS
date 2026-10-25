import AppKit
import SwiftUI
import MoPanelProcess
import MoPanelTerminal

/// The read-only status TUI owns one terminal viewport in one resizable window.
/// It never shares its output consumer with the folded maintenance panel.
@MainActor final class OfficialDashboardWindowController: NSWindowController, NSWindowDelegate {
    let session: ManagedProcess
    var onClose: (() -> Void)?

    init(session: ManagedProcess, english: Bool, command: String, colorScheme: ColorScheme?) {
        self.session = session
        let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 1000)
        let size = NSSize(width: min(1440, max(900, available.width * 0.92)),
                          height: min(960, max(620, available.height * 0.9)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = english ? "Mole · Live Dashboard" : "Mole · 即時儀表板"
        window.identifier = NSUserInterfaceItemIdentifier("MoPanel.officialDashboard")
        window.minSize = NSSize(width: 900, height: 620)
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView:
            OfficialDashboardView(session: session, english: english, command: command)
                .preferredColorScheme(colorScheme))
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func present() {
        window?.deminiaturize(nil)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        session.cancel()
        // Release the terminal screen and its output callback when closed.
        window?.contentView = nil
        onClose?()
        onClose = nil
    }
}

private struct OfficialDashboardView: View {
    @ObservedObject var session: ManagedProcess
    let english: Bool
    let command: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(command).font(.caption.monospaced()).textSelection(.enabled)
                Spacer()
                Text(english ? "Press Q to leave · Resize or use the green button for full screen" : "按 Q 離開 · 可調整大小或按綠色按鈕進入全螢幕")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(12)
            Divider()
            TerminalPanel(session: session, english: english, minimumTerminalHeight: 450)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let failure = session.failure {
                Text(failure).font(.caption).foregroundStyle(.orange)
                    .textSelection(.enabled).padding(10)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
