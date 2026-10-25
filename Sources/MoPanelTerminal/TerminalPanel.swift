// SPDX-License-Identifier: GPL-3.0-or-later
#if os(macOS)
import AppKit
import SwiftUI
import SwiftTerm
import MoPanelProcess

/// Native terminal fallback. It executes one already-selected official command,
/// never an interactive shell. The user controls Mole's own selection/confirmation.
public struct TerminalPanel: View {
    @ObservedObject private var session: ManagedProcess
    private let english: Bool
    private let engineName: String
    private let isVisible: Bool
    private let minimumTerminalHeight: CGFloat
    private let onScreen: (([String]) -> Void)?
    public init(session: ManagedProcess, english: Bool = false, engineName: String = "Mole",
                isVisible: Bool = true, minimumTerminalHeight: CGFloat = 340, onScreen: (([String]) -> Void)? = nil) {
        self.session = session; self.english = english; self.engineName = engineName
        self.isVisible = isVisible; self.minimumTerminalHeight = minimumTerminalHeight; self.onScreen = onScreen
    }
    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label(english ? "Official \(engineName) interactive session" : "官方 \(engineName) 互動介面", systemImage: "terminal")
                    .font(.headline)
                Spacer()
                if session.running {
                    ProgressView().controlSize(.small)
                    Button(english ? "Stop" : "停止", role: .destructive) { session.cancel() }
                        .keyboardShortcut(".", modifiers: .command)
                } else if let code = session.exitCode {
                    Text(code == 0 ? (english ? "Completed" : "已完成") : "Exit \(code)")
                        .foregroundStyle(code == 0 ? .secondary : .primary)
                }
            }.padding(12)
            Divider()
            NativeTerminal(session: session, engineName: engineName, isVisible: isVisible, onScreen: onScreen)
                .frame(minWidth: 600, minHeight: minimumTerminalHeight)
                .accessibilityLabel(english ? "\(engineName) terminal. Use arrow keys, Space, and Return." : "\(engineName) 終端。使用方向鍵、空白鍵及 Return 操作。")
            Divider()
            HStack(spacing: 8) {
                key(english ? "Up" : "上", bytes: [27, 91, 65])
                key(english ? "Down" : "下", bytes: [27, 91, 66])
                key(english ? "Select (Space)" : "選取（空白鍵）", bytes: [32])
                key(english ? "Return" : "確認（Return）", bytes: [13])
                key("Esc", bytes: [27])
                Spacer()
                Text(english ? "Read \(engineName)'s prompt before confirming. Passwords are not recorded." : "請先閱讀 \(engineName) 提示再確認。密碼不會被記錄。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(10)
        }
    }
    private func key(_ title: String, bytes: [UInt8]) -> some View {
        Button(title) { session.send(Data(bytes)) }.disabled(!session.running)
    }
}

private struct NativeTerminal: NSViewRepresentable {
    @ObservedObject var session: ManagedProcess
    let engineName: String
    let isVisible: Bool
    let onScreen: (([String]) -> Void)?
    func makeCoordinator() -> Coordinator { Coordinator(session: session) }
    func makeNSView(context: Context) -> TerminalView {
        let options = TerminalOptions(cols: 110, rows: 32, cursorStyle: .steadyBlock, scrollback: 500,
                                      enableSixelReported: false, kittyImageCacheLimitBytes: 0)
        let view = TerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 13, weight: .regular), options: options)
        view.terminalDelegate = context.coordinator
        view.configureNativeColors()
        view.optionAsMetaKey = false
        view.allowMouseReporting = false
        view.isHidden = !isVisible
        view.setAccessibilityLabel("\(engineName) interactive terminal")
        view.identifier = NSUserInterfaceItemIdentifier("mopanel.terminal.viewport")
        context.coordinator.view = view
        context.coordinator.onScreen = onScreen
        let coordinator = context.coordinator
        session.onOutput = { [weak view, weak coordinator] data in
            view?.feed(byteArray: Array(data)[...]); coordinator?.screenChanged()
        }
        DispatchQueue.main.async { [weak view] in
            guard let view, !view.isHidden else { return }; view.window?.makeFirstResponder(view)
        }
        return view
    }
    func updateNSView(_ nsView: TerminalView, context: Context) {
        context.coordinator.onScreen = onScreen
        let visibilityChanged = nsView.isHidden == isVisible
        let becameVisible = nsView.isHidden && isVisible
        nsView.isHidden = !isVisible
        if visibilityChanged { context.coordinator.screenChanged() }
        if becameVisible {
            session.resize(columns: context.coordinator.columns, rows: context.coordinator.rows)
            DispatchQueue.main.async { [weak nsView] in
                guard let nsView, !nsView.isHidden else { return }
                nsView.window?.makeFirstResponder(nsView)
            }
        }
        // Folded terminals keep their bounded screen and consume PTY output,
        // but are hidden at the AppKit level so output does not draw the view.
    }
    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        coordinator.screenTask?.cancel()
        coordinator.session.onOutput = nil
        // Removing the whole operation panel stops its child. Folding details
        // keeps this representable mounted and never reaches dismantleNSView.
        coordinator.session.cancel()
        nsView.terminalDelegate = nil
    }

    @MainActor final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        let session: ManagedProcess
        weak var view: TerminalView?
        var columns = 110
        var rows = 32
        var onScreen: (([String]) -> Void)?
        var screenTask: Task<Void, Never>?
        func screenChanged() {
            guard onScreen != nil else { return }
            screenTask?.cancel()
            screenTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
                guard let self, let terminal = self.view?.getTerminal() else { return }
                self.onScreen?((0..<min(terminal.rows, 80)).map { terminal.getLine(row: $0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true) ?? "" })
            }
        }
        init(session: ManagedProcess) { self.session = session }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            columns = newCols; rows = newRows
            if !source.isHidden { session.resize(columns: newCols, rows: newRows) }
        }
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            // Large pastes and multi-line paste automation are unnecessary for Mole.
            guard data.count <= 16384 else { NSSound.beep(); return }
            session.send(Data(data))
        }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            // CLI output cannot cause arbitrary URL-scheme or file launches.
            guard let url = URL(string: link), url.scheme == "https",
                  let host = url.host, ["github.com", "mole.fit", "brew.sh", "docs.brew.sh"].contains(host) else { return }
            NSWorkspace.shared.open(url)
        }
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func bell(source: TerminalView) { NSSound.beep() }
    }
}
#endif
