// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import MoPanelProcess

@MainActor final class EditorDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var textView: NSTextView!
    private var document: PurgePathsDocument?
    private var finished = false
    private let english = ProcessInfo.processInfo.environment["MOPANEL_LANGUAGE"] == "en"

    private func text(_ zh: String, _ en: String) -> String { english ? en : zh }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard CommandLine.arguments.count == 2 else {
            fatalErrorAlert(text("此編輯器只能由 Mole 的專案路徑設定開啟。", "Open this editor through Mole's project-path settings.")); return
        }
        do { document = try PurgePathsDocument(url: URL(fileURLWithPath: CommandLine.arguments[1])) }
        catch { fatalErrorAlert(error.localizedDescription); return }
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = text("MoPanel — 專案掃描路徑", "MoPanel — Project scan paths")
        window.delegate = self
        window.minSize = NSSize(width: 560, height: 360)
        let container = NSView(frame: window.contentLayoutRect)
        let heading = NSTextField(wrappingLabelWithString: text(
            "每行一個資料夾。支援 ~/；# 開頭為註解。留空會使用 Mole 預設路徑。儲存後由官方 CLI 重新載入。",
            "One directory per line. ~/ and # comments are supported. Leave empty for Mole's defaults. The official CLI reloads after saving."))
        heading.font = .systemFont(ofSize: 13)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 680, height: 360))
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.string = document?.originalText ?? ""
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.setAccessibilityLabel(text("專案路徑，一行一個資料夾", "Project paths, one directory per line"))
        scroll.documentView = textView
        let add = NSButton(title: text("加入資料夾…", "Add folder…"), target: self, action: #selector(addFolder))
        let cancel = NSButton(title: text("取消", "Cancel"), target: self, action: #selector(cancelEdit))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: text("儲存", "Save"), target: self, action: #selector(saveEdit))
        save.keyEquivalent = "\r"
        [add, cancel, save].forEach { $0.bezelStyle = .rounded }
        let buttons = NSStackView(views: [add, NSView(), cancel, save])
        buttons.orientation = .horizontal; buttons.spacing = 10
        for view in [heading, scroll, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            heading.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            heading.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -14),
            buttons.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18),
            buttons.heightAnchor.constraint(equalToConstant: 30)
        ])
        window.contentView = container
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window.makeFirstResponder(textView)
    }

    @objc private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = text("加入", "Add")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            var value = self.textView.string
            if !value.isEmpty && !value.hasSuffix("\n") { value += "\n" }
            for url in panel.urls {
                guard !url.path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { continue }
                value += url.path + "\n"
            }
            if value.utf8.count <= PurgePathsDocument.maximumBytes { self.textView.string = value }
            else { NSSound.beep() }
        }
    }

    @objc private func saveEdit() {
        guard let document else { return }
        var coordinationError: NSError?
        var saveError: Error?
        // Cooperating editors coordinate; a second fingerprint/data comparison
        // immediately before atomic rename also detects uncoordinated changes.
        NSFileCoordinator().coordinate(writingItemAt: document.url, options: .forReplacing, error: &coordinationError) { _ in
            do { try document.save(textView.string) } catch { saveError = error }
        }
        if let error = saveError ?? coordinationError {
            let alert = NSAlert()
            alert.messageText = text("無法儲存設定", "Could not save configuration")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: text("返回檢查", "Return to editor"))
            alert.beginSheetModal(for: window); return
        }
        finish(0)
    }

    @objc private func cancelEdit() { finish(1) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { finish(1); return false }
    private func finish(_ status: Int32) {
        guard !finished else { return }; finished = true
        // Nonzero cancellation propagates through Mole's set -e without falsely
        // printing "configuration updated" or writing the document.
        exit(status)
    }
    private func fatalErrorAlert(_ message: String) {
        NSApp.setActivationPolicy(.regular)
        let alert = NSAlert()
        alert.messageText = text("無法開啟專案路徑設定", "Cannot open project-path settings")
        alert.informativeText = message
        alert.runModal(); finish(1)
    }
}

// A synchronous executable starts on the main thread, but Swift 5 language
// mode does not infer MainActor for top-level main.swift code. Establish that
// isolation explicitly before constructing AppKit objects; do not dispatch an
// async task that would depend on a run loop we have not started yet.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = EditorDelegate()
    application.delegate = delegate
    // NSApplication.delegate is weak. Keep this delegate alive for the entire
    // synchronous AppKit event loop, including optimized release builds.
    withExtendedLifetime(delegate) {
        application.run()
    }
}
