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
    @State private var resultsExpanded = true
    private func t(_ zh: String, _ en: String) -> String { language == "en" ? en : zh }
    var body: some View {
        if let screen = controller.screen, running {
            VStack(alignment: .leading, spacing: 10) {
                Text(t("勾選要處理的項目", "Choose Items to Process")).font(.headline)
                Text(t("清單與預選由 Mole 提供。選取後按繼續，還可檢查最後確認。", "Mole supplies the list and initial selection. Continue to its final review.")).font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        ForEach(screen.rows) { row in
                            Toggle(isOn: Binding(get: { row.selected }, set: { _ in controller.toggle(row) })) {
                                Text(row.text).font(.callout).textSelection(.enabled)
                            }.toggleStyle(.checkbox).disabled(controller.busy)
                        }
                    }
                }.frame(maxHeight: 200)
                HStack {
                    Button(t("往上", "Previous")) { controller.navigate(down: false) }
                    Button(t("往下查看更多", "Next")) { controller.navigate(down: true) }
                    Spacer()
                    Button(t("繼續", "Continue")) { controller.submitSelection() }.buttonStyle(.borderedProminent)
                }.disabled(controller.busy)
                DisclosureGroup(t("清單狀態", "Selection Status")) { Text(screen.title).font(.caption).textSelection(.enabled) }
            }
        } else if let confirmation = controller.confirmation, running {
            VStack(alignment: .leading, spacing: 10) {
                Text(preview ? t("確認這次預覽範圍", "Confirm Preview Scope") : t("確認執行範圍", "Confirm Operation Scope")).font(.headline)
                Text(confirmation).font(.callout).textSelection(.enabled)
                if !preview { Text(t("Mole 將執行選取範圍；清理可能永久刪除。", "Mole will process the selection; cleanup may permanently delete files.")).font(.caption).foregroundStyle(.orange) }
                HStack {
                    Button(t("取消", "Cancel")) { controller.cancelConfirmation() }
                    Spacer()
                    Button(preview ? t("顯示預覽結果", "Show Preview Results") : t("確認開始", "Confirm and Start")) { controller.confirm() }.buttonStyle(.borderedProminent)
                }
            }
        }
        if !controller.message.isEmpty { Text(controller.message).font(.caption).foregroundStyle(.orange) }
        if !running, !controller.reviewed.isEmpty {
            DisclosureGroup(t("本次查看與選取的項目", "Items Reviewed in This Session"), isExpanded: $resultsExpanded) {
                ScrollView {
                    ForEach(controller.reviewed.keys.sorted(), id: \.self) { item in
                        Label(item, systemImage: controller.reviewed[item] == true ? "checkmark.circle" : "minus.circle").font(.caption).textSelection(.enabled)
                    }
                }.frame(maxHeight: 180)
                Text(t("這是選取紀錄；實際處理結果以上方 Mole 回報為準。", "This records selection; Mole's results above describe actual processing.")).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
