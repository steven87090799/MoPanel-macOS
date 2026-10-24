import SwiftUI
import MoPanelCore

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var limit = 50
    @State private var filter = "all"
    private var sessions: [HistorySession] {
        (model.history?.sessions ?? []).filter { item in
            (search.isEmpty || item.command.localizedCaseInsensitiveContains(search) || item.startedAt.contains(search) || item.runId.localizedCaseInsensitiveContains(search)) &&
            (filter == "all" || (filter == "failed" && (item.actions.failed > 0 || item.failedTasks > 0)) || (filter == "incomplete" && (!item.isComplete || !item.isUnambiguous)))
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeading(title: model.t("每次作業都有跡可循", "Understand every operation"), subtitle: model.t("讀取官方操作紀錄；不完整與歸屬不明的紀錄不會當成成功執行。", "Reads official logs without treating incomplete or ambiguous sessions as successful runs."), symbol: "clock.arrow.circlepath")
                HStack {
                    TextField(model.t("搜尋指令、日期或 Run ID", "Search command, date or run ID"), text: $search).textFieldStyle(.roundedBorder)
                    Picker(model.t("篩選", "Filter"), selection: $filter) {
                        Text(model.t("全部", "All")).tag("all")
                        Text(model.t("失敗", "Failures")).tag("failed")
                        Text(model.t("不完整／不明確", "Incomplete / Ambiguous")).tag("incomplete")
                    }.frame(width: 180)
                    Picker(model.t("筆數", "Limit"), selection: $limit) { ForEach([20, 50, 100, 200], id: \.self) { Text(String($0)).tag($0) } }.frame(width: 105)
                    Button(model.t("讀取歷史", "Load History")) { Task { await model.loadHistory(limit: limit) } }.buttonStyle(.borderedProminent).disabled(!model.canStart)
                }
                if let history = model.history {
                    DisclosureGroup(model.t("更多紀錄與原始輸出", "More Records and Raw Output")) {
                    HStack {
                        Button(model.t("原始操作日誌", "Operation Log")) { model.reveal(history.logs.operations) }
                        Button(model.t("原始刪除日誌", "Deletion Log")) { model.reveal(history.logs.deletions) }
                        Button(model.t("官方文字報表", "Official Text Report")) { model.request(.history, options: [.historyLimit(limit)]) }.disabled(!model.canStart)
                        Button(model.t("官方 JSON", "Official JSON")) { model.request(.history, options: [.json, .historyLimit(limit)]) }.disabled(!model.canStart)
                    }
                    }
                    LazyVStack(spacing: 12) {
                        ForEach(Array(sessions.enumerated()), id: \.offset) { _, item in
                            GroupBox {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack {
                                        Label(item.command.capitalized, systemImage: item.isComplete && item.isUnambiguous ? "doc.text" : "exclamationmark.circle").font(.headline)
                                        Spacer()
                                        Text(DisplayFormat.timestamp(item.startedAt, language: model.language)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                        Text(item.size).font(.headline.monospacedDigit())
                                    }
                                    if !item.isComplete { Notice(text: model.t("沒有結束標記：可能中斷或尚未完成，不能認定全部成功。", "No end marker was recorded. This run may be interrupted or incomplete."), warning: true) }
                                    if !item.isUnambiguous {
                                        Notice(text: model.t("歸屬方式：", "Attribution: ") + item.attribution + model.t("。以下是日誌記錄的計數，無法可靠分配為單次作業結果。", ". Recorded counts cannot be reliably attributed to a single run."), warning: true)
                                    }
                                    HStack(spacing: 20) {
                                        count(model.t("永久移除", "Removed"), item.actions.removed)
                                        count(model.t("移至垃圾桶", "Trashed"), item.actions.trashed)
                                        count(model.t("略過", "Skipped"), item.actions.skipped)
                                        count(model.t("失敗", "Failed"), item.actions.failed)
                                        count(model.t("重建", "Rebuilt"), item.actions.rebuilt)
                                        count(model.t("其他", "Other"), item.actions.other)
                                    }
                                    DisclosureGroup(model.t("紀錄細節", "Record Details")) {
                                        VStack(alignment: .leading, spacing: 7) {
                                            LabeledContent("Run ID", value: item.runId.isEmpty ? model.t("未提供", "Unavailable") : item.runId)
                                            LabeledContent(model.t("結束時間", "Ended"), value: item.endedAt.isEmpty ? model.t("未記錄", "Not recorded") : item.endedAt)
                                            LabeledContent(model.t("日誌動作數", "Logged Operations"), value: String(item.operationCount))
                                            LabeledContent(model.t("失敗工作數", "Failed Tasks"), value: String(item.failedTasks))
                                            if let items = item.items { LabeledContent(model.t("官方項目數", "Official Item Count"), value: String(items)) }
                                        }.font(.callout).textSelection(.enabled).padding(.top, 8)
                                    }
                                }.padding(10)
                            }
                        }
                    }
                    if sessions.isEmpty { ContentUnavailableView(model.t("沒有符合的歷史紀錄", "No Matching History"), systemImage: "clock") }
                    if !history.deletions.isEmpty {
                        DisclosureGroup(model.t("檔案層級紀錄（不自動歸入上方作業）", "File Records (not automatically attributed to sessions)")) {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(Array(history.deletions.filter { search.isEmpty || $0.path.localizedCaseInsensitiveContains(search) || $0.status.localizedCaseInsensitiveContains(search) }.enumerated()), id: \.offset) { _, entry in
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack { Text(entry.timestamp).foregroundStyle(.secondary); Spacer(); Text(entry.mode + " · " + entry.status) }.font(.caption)
                                        Text(entry.path).font(.callout.monospaced()).textSelection(.enabled)
                                        Text(entry.sizeKb.map { DisplayFormat.bytes($0 <= Int64.max / 1024 ? $0 * 1024 : nil) } ?? model.t("容量未記錄", "Size not recorded")).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Divider()
                                }
                            }.padding(12)
                        }
                    }
                    Notice(text: model.t("容量與計數保留官方原值。詳細錯誤若未出現在 JSON，請從原始日誌確認；MoPanel 不會自行推測原因。", "Sizes and counts preserve Mole's original values. If JSON omits detailed errors, inspect the original logs; MoPanel does not infer a cause."))
                } else { ContentUnavailableView(model.t("讀取既有紀錄", "Read Existing Logs"), systemImage: "clock", description: Text(model.t("歷史來自 Mole 本機日誌，不需掃描或刪除任何檔案。", "History comes from local Mole logs without scanning or deleting files."))) }
            }.padding(26)
        }
    }
    private func count(_ title: String, _ value: Int) -> some View { VStack(alignment: .leading, spacing: 4) { Text(String(value)).font(.title3.monospacedDigit()); Text(title).font(.caption).foregroundStyle(.secondary) } }
}
