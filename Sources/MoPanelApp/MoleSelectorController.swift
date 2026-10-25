import SwiftUI
import MoPanelCore

/// Drives only the known Mole selector via acknowledged arrow/Space input.
/// It never turns a displayed label into a filesystem action or a menu number.
@MainActor final class MoleSelectorController: ObservableObject {
    @Published private(set) var screen: MoleSelectionScreen?
    @Published private(set) var confirmation: String?
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    @Published private(set) var reviewed: [String: Bool] = [:]
    private var task: Task<Void, Never>?
    private var sender: ((Data) -> Void)?
    private var generation = UUID()
    private var enabled = false

    func reset() {
        task?.cancel(); task = nil; screen = nil; confirmation = nil
        busy = false; reviewed = [:]; sender = nil; enabled = false; generation = UUID(); message = ""
    }
    func update(_ lines: [String], command: MoleCommand, enabled: Bool, send: @escaping (Data) -> Void) {
        self.enabled = enabled; sender = enabled ? send : nil
        guard enabled else { screen = nil; confirmation = nil; task?.cancel(); return }
        screen = MoleSelectionScreen.parse(lines, command: command)
        if let screen {
            confirmation = nil
            for row in screen.rows where reviewed.count < 1000 || reviewed[row.text] != nil { reviewed[row.text] = row.selected }
            return
        }
        let prefix: String
        switch command { case .installer: prefix = "➤ Delete "; case .slim: prefix = "➤ Slim "; case .purge: prefix = "➤ Remove "; default: confirmation = nil; return }
        let nonempty = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        confirmation = nil
        if let start = nonempty.lastIndex(where: { $0.hasPrefix(prefix) }) {
            let prompt = nonempty[start...].joined(separator: " ")
            if prompt.utf8.count < 1200, prompt.contains("Enter confirm"), prompt.hasSuffix("ESC cancel:") { confirmation = prompt }
        }
    }
    func suspend() { enabled = false; task?.cancel(); busy = false }
    func toggle(_ target: MoleSelectionScreen.Row) {
        guard enabled, !busy, let original = screen, original.rows.contains(target), let send = sender else { return }
        let token = generation
        busy = true; message = ""
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.busy = false; self.task = nil } }
            do {
                for _ in 0..<64 {
                    try Task.checkCancellation()
                    guard self.enabled, self.generation == token, let current = self.screen,
                          current.title == original.title,
                          current.rows.map(\.text) == original.rows.map(\.text),
                          let cursor = current.rows.firstIndex(where: \.focused),
                          let destination = current.rows.firstIndex(where: { $0.text == target.text }),
                          current.rows[destination].selected == target.selected else { throw SelectorError.changed }
                    if cursor == destination {
                        send(Data([32]))
                        try await self.waitFor { self.screen?.rows.first(where: { $0.text == target.text })?.selected == !target.selected }
                        return
                    }
                    let expected = current.rows[cursor + (cursor < destination ? 1 : -1)].text
                    send(Data(cursor < destination ? [27, 91, 66] : [27, 91, 65]))
                    try await self.waitFor { self.screen?.focused?.text == expected }
                }
                throw SelectorError.changed
            } catch is CancellationError { }
            catch { if self.generation == token { self.message = "選單已改變或沒有回應，已停止送出按鍵。請重試或展開詳細資訊。" } }
        }
    }
    func navigate(down: Bool) {
        guard enabled, !busy, screen != nil else { return }
        sender?(Data(down ? [27, 91, 66] : [27, 91, 65]))
    }
    func submitSelection() {
        guard enabled, !busy, screen != nil else { return }
        sender?(Data([13])); screen = nil
    }
    func confirm() {
        guard enabled, !busy, confirmation != nil else { return }
        sender?(Data([13])); confirmation = nil
    }
    func cancelConfirmation() {
        guard enabled, !busy, confirmation != nil else { return }
        sender?(Data([27])); confirmation = nil
    }
    private func waitFor(_ ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            try Task.checkCancellation()
            guard enabled else { throw SelectorError.changed }
            if ready() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw SelectorError.changed
    }
    private enum SelectorError: Error { case changed }
}

struct MoleSelectorView: View {
    @ObservedObject var controller: MoleSelectorController
    let language: String
    let running: Bool
    let preview: Bool
    var showsActions = true
    var listHeight: CGFloat? = 200
    @State private var resultsExpanded = false
    @State private var details = Set<String>()
    private func t(_ zh: String, _ en: String) -> String { language == "en" ? en : zh }
    var body: some View {
        if let screen = controller.screen, running {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(t("選擇要處理的項目", "Choose Items to Process")).font(.title3.bold())
                    Spacer()
                    Text(t("目前清單已選 ", "Selected in this list: ") + "\(screen.rows.filter(\.selected).count)/\(screen.rows.count)")
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
                Text(t("已保留 Mole 的預選項目；取消勾選即可保留。", "Mole's initial selection is preserved. Uncheck any item to keep it.")).font(.caption).foregroundStyle(.secondary)
                if let listHeight { ScrollView { selectionRows(screen) }.frame(maxHeight: listHeight) }
                else { selectionRows(screen) }
                if showsActions { HStack { Spacer(); MoleSelectorActions(controller: controller, language: language, preview: preview) } }
                DisclosureGroup(t("掃描範圍與原始資訊", "Scan Scope and Original Information")) { Text(screen.title).font(.caption).textSelection(.enabled) }
            }
        } else if let confirmation = controller.confirmation, running {
            VStack(alignment: .leading, spacing: 12) {
                Text(preview ? t("檢查選取範圍", "Review Selected Scope") : t("準備開始", "Ready to Start")).font(.title3.bold())
                Text(confirmation).font(.callout).textSelection(.enabled)
                if !preview { Text(t("這項操作由 Mole 執行；清理會永久移除已確認的項目。", "Mole executes this operation; confirmed cleanup items are permanently removed.")).font(.caption).foregroundStyle(.orange) }
                if showsActions { HStack { Button(t("取消", "Cancel")) { controller.cancelConfirmation() }; Spacer(); MoleSelectorActions(controller: controller, language: language, preview: preview) } }
            }.padding(16).moPanelGlass(cornerRadius: 16)
        }
        if !controller.message.isEmpty { Text(controller.message).font(.caption).foregroundStyle(.orange) }
        if !running, !controller.reviewed.isEmpty {
            DisclosureGroup(t("本次選取紀錄", "Selection Record") + " · \(controller.reviewed.count)", isExpanded: $resultsExpanded) {
                ScrollView {
                    ForEach(controller.reviewed.keys.sorted(), id: \.self) { item in
                        Label(item, systemImage: controller.reviewed[item] == true ? "checkmark.circle" : "minus.circle").font(.caption).textSelection(.enabled)
                    }
                }.frame(maxHeight: 180)
                Text(t("此處是選取紀錄；實際結果以上方執行摘要為準。", "This records selection; see the operation summary for actual results.")).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    private func selectionRows(_ screen: MoleSelectionScreen) -> some View {
        LazyVStack(spacing: 8) {
            ForEach(screen.rows) { row in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Toggle(isOn: Binding(get: { row.selected }, set: { _ in controller.toggle(row) })) {
                            Text(row.text).font(.callout.weight(.medium)).lineLimit(2)
                        }.toggleStyle(.checkbox).disabled(controller.busy)
                        Spacer(minLength: 8)
                        Button { if details.contains(row.id) { details.remove(row.id) } else { details.insert(row.id) } } label: { Image(systemName: "info.circle") }
                            .buttonStyle(.plain).accessibilityLabel(t("查看 ", "Details for ") + row.text)
                    }
                    if details.contains(row.id) { Text(row.text).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
                }.padding(14).moPanelGlass(cornerRadius: 14)
            }
        }
    }
}

struct MoleSelectorActions: View {
    @ObservedObject var controller: MoleSelectorController
    let language: String
    let preview: Bool
    private func t(_ zh: String, _ en: String) -> String { language == "en" ? en : zh }
    var body: some View {
        HStack(spacing: 12) {
            if controller.screen != nil {
                Button(t("上一列", "Previous Row")) { controller.navigate(down: false) }
                Button(t("下一列／更多項目", "Next Row / More Items")) { controller.navigate(down: true) }
                Button(t("下一步", "Next")) { controller.submitSelection() }.buttonStyle(.borderedProminent)
            } else if controller.confirmation != nil {
                Button(preview ? t("顯示結果", "Show Results") : t("開始執行", "Start")) { controller.confirm() }.buttonStyle(.borderedProminent)
            }
        }.disabled(controller.busy)
    }
}
