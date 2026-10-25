import SwiftUI
import MoPanelCore

struct AICleanupView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var controller: FileReviewController
    let onBack: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Button(model.t("返回系統清理", "Back to System Cleanup"), systemImage: "chevron.left", action: onBack)
                    .buttonStyle(.borderless).disabled(controller.busy || controller.preparing)
                PageHeader(title: model.t("AI 清理", "AI Cleanup"),
                    subtitle: model.t("整理可重建快取，保留對話、登入、設定與模型。", "Clear rebuildable caches while retaining conversations, sign-in, settings and models."), symbol: "moon.stars") {
                    NativeActionButton(model.t("掃描 AI 資料", "Scan AI Data"), identifier: "mopanel.ai.scan", systemImage: "magnifyingglass", appearance: .prominent) {
                        guard !model.isTestLaunch else { return }
                        Task {
                            guard model.canStart else { return }
                            await controller.scanAICaches()
                        }
                    }.disabled(!model.canStart || model.isTestLaunch || controller.preparing)
                }
                if controller.cleanupScanInProgress {
                    ProgressView(model.t("正在檢查 AI 工具的快取位置…", "Checking AI tool cache locations…"))
                } else if let run = controller.lastRun, !run.hasUnresolvedItems {
                    Label(model.t("清理成功 · 已將 \(run.moved) 項移至垃圾桶", "Cleanup complete · \(run.moved) items moved to Trash"), systemImage: "checkmark.circle.fill")
                        .font(.title2.bold()).foregroundStyle(MoPanelTheme.positive)
                } else if controller.sourceDate != nil || !controller.errors.isEmpty {
                    FileReviewView(controller: controller, language: model.language, operationInProgress: model.hasRunningOperation)
                } else {
                    Text(model.t("按右上角掃描，再勾選要清理的快取。工具仍在執行時，相關項目會先保留。", "Scan at the top right, then choose caches to clear. Data used by a running tool is retained."))
                        .foregroundStyle(.secondary)
                }
                DisclosureGroup(model.t("支援範圍與更多資訊", "Supported Tools and Details")) {
                    Text(model.t("Claude、Codex 桌面版、Cursor、Windsurf、Qoder 與 OpenCode 的指定快取位置。只在按下掃描時檢查，不在背景持續掃描。舊對話、舊 CLI 版本及工具整包移除尚未納入此頁。", "Fixed cache locations for Claude, Codex Desktop, Cursor, Windsurf, Qoder and OpenCode. Scans run only when requested. Old sessions, CLI versions and whole-tool removal are outside this page's scope."))
                        .font(.callout).foregroundStyle(.secondary)
                    Text(model.t("掃描：macOS 檔案 API，沒有 CLI 指令。清理：NSWorkspace.recycle，可從垃圾桶還原。", "Scan: macOS file APIs, with no CLI command. Cleanup: NSWorkspace.recycle, recoverable from Trash."))
                        .font(.caption).textSelection(.enabled)
                }
                GroupBox(model.t("工作副本管理", "Worktree Management")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(model.t("AI 任務可能建立同一專案的額外工作副本。Git 工作目錄可檢查這些副本；有未提交修改或無法確認安全的內容會保留。", "AI tasks may create extra working copies of a project. Git Worktrees checks them and protects uncommitted or unverifiable work."))
                            .foregroundStyle(.secondary)
                        Button(model.t("管理 Git 工作副本", "Manage Git Worktrees")) { model.section = .worktrees }
                            .disabled(controller.busy || controller.preparing)
                    }.padding(10)
                }
            }.padding(26)
        }.safeAreaInset(edge: .bottom, spacing: 0) {
            if !controller.files.isEmpty && !controller.preparing {
                FileReviewActionBar(controller: controller, language: model.language, operationInProgress: model.hasRunningOperation)
            }
        }
    }
}
