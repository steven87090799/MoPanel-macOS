// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import MoPanelCore

struct GitWorktreeView: View {
    @StateObject private var controller: GitWorktreeController
    let language: String
    var operationInProgress: Bool
    @State private var search = ""
    @State private var onlyRemovable = false

    init(controller: GitWorktreeController, language: String, operationInProgress: Bool = false) {
        _controller = StateObject(wrappedValue: controller)
        self.language = language; self.operationInProgress = operationInProgress
    }
    init(language: String, helperURL: URL? = nil, operationInProgress: Bool = false) {
        _controller = StateObject(wrappedValue: GitWorktreeController(language: language, helperURL: helperURL))
        self.language = language; self.operationInProgress = operationInProgress
    }
    private func t(_ zh: String, _ en: String) -> String { language == "en" ? en : zh }
    private var disabled: Bool { controller.isBusy || operationInProgress || !controller.actionsAllowed }
    private var filtered: [GitWorktreeRow] {
        controller.rows.filter { row in
            (!onlyRemovable || row.canRemove) && (search.isEmpty || (row.entry.path + " " + (row.entry.branch ?? "") + " " + (row.entry.head ?? "")).localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if controller.isBusy {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(controller.activity).font(.callout)
                        Spacer()
                        Button(t("要求停止", "Request Stop")) { controller.requestCancellation() }
                            .disabled(controller.cancellationRequested)
                    }.padding(14).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                if !controller.lastOutcome.isEmpty {
                    GroupBox(t("上次操作結果", "Last Operation Outcome")) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(controller.lastOutcome).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            if let reference = controller.lastRecoveryReference {
                                Button(t("複製復原 ref", "Copy Recovery Ref")) { controller.copyReference(reference) }
                                    .disabled(!controller.actionsAllowed)
                            }
                        }.padding(8)
                    }
                }
                HStack {
                    TextField(t("搜尋路徑、分支或 HEAD", "Search paths, branches or HEAD"), text: $search).textFieldStyle(.roundedBorder)
                    Toggle(t("只顯示可預覽移除", "Only removable candidates"), isOn: $onlyRemovable)
                }
                worktrees
                recovery
            }.padding(26)
        }
        .onAppear { if controller.language != language { controller.language = language } }
        .onChange(of: language) { _, value in if controller.language != value { controller.language = value } }
        .onDisappear { controller.cancelReadOnly() }
        .sheet(item: $controller.pendingRemoval) { plan in
            GitRemovalConfirmation(controller: controller, plan: plan, language: language, operationInProgress: operationInProgress)
        }
        .sheet(item: $controller.pendingRestore) { plan in
            GitRestoreConfirmation(controller: controller, plan: plan, language: language, operationInProgress: operationInProgress)
        }
        .alert(t("Git Worktree 操作無法完成", "Git Worktree Operation Could Not Finish"),
               isPresented: Binding(get: { controller.errorMessage != nil }, set: { if !$0 { controller.errorMessage = nil } })) {
            Button(t("關閉", "Close")) { controller.errorMessage = nil }
        } message: { Text(controller.errorMessage ?? "") }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            PageHeader(title: t("Git 工作目錄", "Git Worktrees"),
                        subtitle: t("只檢查你選擇的倉庫。保護主目錄、未提交內容與無法驗證的狀態；移除前保留復原分支，不使用 force。", "Inspects only your selected repository. Main, modified and unverifiable worktrees stay protected. A recovery branch is retained before removal; force is never used."), symbol: "arrow.triangle.branch") {
                Button(t("重新掃描", "Scan Again")) { Task { await controller.refresh() } }
                    .buttonStyle(.borderedProminent).disabled(disabled || controller.selectedRepository == nil)
                    .accessibilityIdentifier("mopanel.worktrees.scan")
            }
            HStack {
                Button(t("選擇倉庫…", "Choose Repository…")) { controller.chooseRepository() }.disabled(disabled)
                    .accessibilityIdentifier("mopanel.worktrees.choose")
                Spacer()
            }
            Text(t("工作目錄是同一專案的額外工作副本，例如 AI 為不同任務建立的副本。掃描後可查看是否有修改、是否能安全移除。", "A worktree is an extra working copy of the same project, such as one created for an AI task. Scan to inspect changes and removal eligibility."))
                .font(.callout).foregroundStyle(.secondary)
            if let repository = controller.selectedRepository { Text(repository.path).font(.caption.monospaced()).textSelection(.enabled) }
            if let path = controller.gitPath { DisclosureGroup(t("Git 工具詳細資訊", "Git Tool Details")) { Text((controller.gitVersion ?? "Git") + " · " + path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) } }
            if operationInProgress { Text(t("其他作業執行中，暫停 Git 操作。", "Git actions are paused while another operation is running.")).foregroundStyle(.orange) }
            if !controller.actionsAllowed { Text(t("測試／效能模式不會存取真實 Git 倉庫。", "Test and benchmark launches do not access real Git repositories.")).foregroundStyle(.orange) }
        }
    }
    private var worktrees: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label(t("工作目錄與保護檢查", "Worktrees and Protection Checks"), systemImage: "folder.badge.gearshape").font(.title2.bold())
                if filtered.isEmpty {
                    ContentUnavailableView(controller.hasLoaded ? t("沒有符合條件的工作目錄", "No Matching Worktrees") : t("選擇 Git 倉庫以開始", "Choose a Git Repository"),
                                           systemImage: "arrow.triangle.branch",
                                           description: Text(controller.hasLoaded ? t("可調整搜尋或篩選；受保護項目不會被默默略過。", "Adjust the search or filter. Protected entries are not silently omitted.") : t("只在你要求時掃描，不進行背景搜尋或自動清理。", "Scans run only when requested. There is no background search or automatic cleanup.")))
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { row in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: row.canRemove ? "folder" : "lock.shield").foregroundStyle(row.canRemove ? Color.accentColor : Color.secondary).font(.title2)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(URL(fileURLWithPath: row.entry.path).lastPathComponent).font(.headline)
                                    Text(row.entry.branch ?? (row.entry.bare ? "bare" : "detached HEAD")).font(.caption.monospaced())
                                    Text(row.entry.path).font(.caption.monospaced()).textSelection(.enabled)

                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Button("Finder") { controller.reveal(row.entry.path) }.disabled(!controller.actionsAllowed)
                                Button(t("移除預覽…", "Preview Removal…")) { Task { await controller.prepareRemoval(row) } }
                                    .disabled(disabled || !row.canRemove)
                            }
                            DisclosureGroup(t("詳細資訊與保護原因", "Details and Protection Reasons")) {
                            if let head = row.entry.head { Text("HEAD: " + head).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
                            ForEach(row.protection, id: \.self) { reason in
                                Label(reason.explanation(language: language), systemImage: "shield").font(.caption).foregroundStyle(.secondary)
                            }
                            if let reason = row.entry.lockReason, !reason.isEmpty { Text(t("鎖定原因：", "Lock reason: ") + reason).font(.caption).textSelection(.enabled) }
                            if let reason = row.entry.pruneReason, !reason.isEmpty { Text(t("Git 原因：", "Git reason: ") + reason).font(.caption).textSelection(.enabled) }
                            if let detail = row.detail { Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                            if row.canRemove {
                                Text(t("目前通過檢查。確認前與執行前會再次驗證；這不是 Git 原生 dry-run。",
                                       "Currently passes checks. State is revalidated before review and execution; this is not a Git-provided dry run.")).font(.caption).foregroundStyle(.secondary)
                            }
                            }
                        }.padding(.vertical, 13)
                        Divider()
                    }
                }
            }.padding(12)
        }
    }
    private var recovery: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label(t("保留分支與重建", "Retained Branches and Reconstruction"), systemImage: "arrow.uturn.backward.circle").font(.title2.bold())
                Text(t("復原點是原倉庫內的本地分支，依賴原倉庫與物件資料仍存在；不是獨立備份，也不保存未提交／已忽略內容、完整 reflog、ACL 或延伸屬性。重新掃描可找回 mopanel-recovery 命名空間內的 UUID 分支。",
                       "Recovery points are local branches in the original repository and depend on its object data. They are not independent backups and do not preserve uncommitted/ignored content, the full reflog, ACLs or extended attributes. Scanning finds UUID branches in the mopanel-recovery namespace.")).font(.callout)
                Text(t("每次 Git 呼叫停用 hooks、fsmonitor、全域／系統設定、自動維護與 lazy fetch；不執行自訂 filter 或下載缺少物件。特殊配置會受保護。",
                       "Each Git call disables hooks, fsmonitor, global/system configuration, automatic maintenance and lazy fetching. Custom filters and missing-object downloads are not run. Special configurations are protected.")).font(.caption).foregroundStyle(.secondary)
                if controller.recoveryPoints.isEmpty { Text(t("目前清單中沒有可辨識的保留分支。", "No recognized retained branches are in the current inventory.")).foregroundStyle(.secondary) }
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(controller.recoveryPoints) { point in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(point.branchName).font(.headline.monospaced()).textSelection(.enabled)
                                Text("HEAD: " + point.head).font(.caption.monospaced()).textSelection(.enabled)
                                if let path = point.checkedOutPath {
                                    Text(t("此分支已在以下工作目錄使用：", "This branch is already checked out at: ") + path).font(.caption).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Button(t("複製 ref", "Copy Ref")) { controller.copyReference(point.reference) }.disabled(!controller.actionsAllowed)
                            Button(t("重建工作目錄…", "Rebuild Worktree…")) { controller.chooseRestoreDestination(point) }
                                .disabled(disabled || point.checkedOutPath != nil)
                        }
                    }
                }
            }.padding(12)
        }
    }
}

private struct GitRemovalConfirmation: View {
    @ObservedObject var controller: GitWorktreeController
    let plan: GitWorktreeRemovalPlan
    let language: String
    let operationInProgress: Bool
    @State private var acknowledged = false
    private func t(_ zh: String, _ en: String) -> String { language == "en" ? en : zh }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(t("確認 Git 工作目錄移除", "Confirm Git Worktree Removal"), systemImage: "exclamationmark.shield").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(plan.proof.canonicalPath).font(.body.monospaced()).textSelection(.enabled)
                    Text("HEAD: " + (plan.proof.entry.head ?? "")).font(.caption.monospaced()).textSelection(.enabled)
                    Text(plan.proof.entry.branch ?? "detached HEAD").font(.caption.monospaced())
                    Text(t("先建立保留分支：", "First create the retained branch: "))
                    Text(plan.recoveryReference).font(.caption.monospaced()).textSelection(.enabled)
                    Text(t("將由 git worktree remove 永久移除這個工作目錄及其工作目錄中繼資料，不經垃圾桶、不使用 force。原分支與保留分支仍留在原倉庫；復原分支只保留已提交的 Git 內容，不是獨立備份。",
                           "git worktree remove permanently removes this worktree and its worktree metadata. It does not use Trash or force. The original and recovery branches remain in the original repository. The recovery branch retains committed Git contents; it is not an independent backup."))
                    Text(t("請先關閉使用此目錄的編輯器、終端與建置。MoPanel 會重驗 HEAD、路徑身分、dirty、untracked、ignored、submodule、私有紀錄及歷史可達性；Git 的檔案檢查與移除不是對外部寫入的原子交易。",
                           "First close editors, terminals and builds using this directory. MoPanel rechecks HEAD, path identity, dirty/untracked/ignored content, submodules, private state and history reachability. Git's checks and removal are not an atomic transaction against external writes."))
                    Text(t("若取消或失敗，可能已部分變更；保留分支不會自動刪除，也不會自動 rm 剩餘來源。", "Cancellation or failure may leave partial changes. The retained branch is not deleted automatically, and leftover source files are never manually removed.")).foregroundStyle(.secondary)
                }
            }.frame(maxHeight: 360)
            Toggle(t("我已停止此目錄的工作，並理解永久移除與復原點的限制。", "I stopped work in this directory and understand permanent removal and the recovery point's limits."), isOn: $acknowledged)
            HStack {
                Button(t("取消", "Cancel"), role: .cancel) { controller.cancelReview() }
                Spacer()
                Button(t("保留分支並移除", "Retain Branch and Remove"), role: .destructive) { Task { await controller.confirmRemoval(plan) } }
                    .buttonStyle(.borderedProminent).disabled(!acknowledged || controller.isBusy || operationInProgress)
            }
        }.padding(24).frame(width: 660)
    }
}

private struct GitRestoreConfirmation: View {
    @ObservedObject var controller: GitWorktreeController
    let plan: GitWorktreeRestorePlan
    let language: String
    let operationInProgress: Bool
    @State private var acknowledged = false
    private func t(_ zh: String, _ en: String) -> String { language == "en" ? en : zh }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(t("確認由分支重建", "Confirm Reconstruction from Branch"), systemImage: "arrow.uturn.backward.circle").font(.title2.bold())
            Text(plan.recovery.reference).font(.caption.monospaced()).textSelection(.enabled)
            Text("HEAD: " + plan.recovery.head).font(.caption.monospaced()).textSelection(.enabled)
            Text(t("新工作目錄：", "New worktree: ")).font(.headline)
            Text(plan.destination).font(.body.monospaced()).textSelection(.enabled)
            Text(t("將執行 git worktree add，從此分支建立新工作目錄，不使用 force、不覆寫現有位置。hooks 與自訂 filter 不執行，也不下載缺少物件。完成後驗證 HEAD、追蹤內容及乾淨狀態。",
                   "git worktree add will create a new worktree from this branch, without force or overwriting an existing path. Hooks and custom filters are not run, and missing objects are not downloaded. HEAD, tracked entries and clean state are verified afterwards."))
            Text(t("這會還原 Git 已提交內容，不是完整檔案系統備份復原。分支與物件必須仍在原倉庫；失敗或取消後，可能留下部分目的地，MoPanel 不會自動刪除。",
                   "This reconstructs committed Git contents, not a complete filesystem backup. The branch and objects must remain in the original repository. A failed or cancelled attempt may leave a partial destination, which MoPanel does not delete automatically.")).foregroundStyle(.secondary)
            Toggle(t("確認在這個新位置重建已提交內容。", "Reconstruct committed contents at this new location."), isOn: $acknowledged)
            HStack {
                Button(t("取消", "Cancel"), role: .cancel) { controller.cancelReview() }
                Spacer()
                Button(t("確認重建", "Rebuild Worktree")) { Task { await controller.confirmRestore(plan) } }
                    .buttonStyle(.borderedProminent).disabled(!acknowledged || controller.isBusy || operationInProgress)
            }
        }.padding(24).frame(width: 640)
    }
}
