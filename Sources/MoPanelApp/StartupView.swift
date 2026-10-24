// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import MoPanelCore

struct StartupView: View {
    @ObservedObject var controller: StartupController
    let language: String
    var operationInProgress = false
    @State private var search = ""
    @State private var scope = "all"
    @State private var onlyManageable = false
    private func t(_ zh: String, _ en: String) -> String { language == "en" ? en : zh }
    private var visible: [StartupRow] {
        controller.rows.filter { row in
            (scope == "all" || row.item.scope.rawValue == scope) && (!onlyManageable || controller.canReview(row)) &&
            (search.isEmpty || [row.item.url.path, row.item.snapshot?.label ?? "", row.item.snapshot?.executable ?? ""].contains(where: { $0.localizedCaseInsensitiveContains(search) }))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Label(t("啟動與背景項目", "Startup and Background Items"), systemImage: "power.circle").font(.largeTitle.bold())
                    Text(t("MoPanel 新實作 · 只管理已驗證屬於目前使用者的第三方 LaunchAgent；其他項目交由系統設定。", "MoPanel implementation · Manages verified own-user third-party LaunchAgents; other items remain in System Settings.")).foregroundStyle(.secondary)
                }
                HStack {
                    Button(t("讀取／重新整理", "Read / Refresh")) { Task { await controller.refresh() } }.buttonStyle(.borderedProminent)
                        .disabled(controller.isBusy || operationInProgress)
                    Button(t("開啟登入項目系統設定", "Open Login Items Settings")) { controller.openLoginItemsSettings() }
                    Spacer()
                    if controller.isBusy {
                        ProgressView(value: controller.progress).frame(width: 120)
                        Button(t("停止", "Stop")) { controller.cancel() }
                    }
                }
                Text(t("這個清單只讀取 ~/Library/LaunchAgents、/Library/LaunchAgents 與 /Library/LaunchDaemons 的 plist 中繼資料，不包含私人背景項目資料庫。未列出的 Login Items 請在系統設定管理。", "Reads bounded plist metadata from ~/Library/LaunchAgents, /Library/LaunchAgents and /Library/LaunchDaemons. It does not read private background-item databases. Manage other Login Items in System Settings.")).font(.callout).foregroundStyle(.secondary)
                HStack {
                    TextField(t("搜尋標籤、執行檔或路徑", "Search label, executable or path"), text: $search).textFieldStyle(.roundedBorder)
                    Picker(t("來源", "Source"), selection: $scope) {
                        Text(t("全部", "All")).tag("all")
                        ForEach(StartupScope.allCases, id: \.rawValue) { value in Text(scopeTitle(value)).tag(value.rawValue) }
                    }.frame(width: 210)
                    Toggle(t("僅可管理", "Manageable only"), isOn: $onlyManageable).toggleStyle(.checkbox)
                }
                if !controller.statusMessage.isEmpty { Text(controller.statusMessage).font(.callout) }
                ForEach(controller.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                if !controller.hasLoaded {
                    ContentUnavailableView(t("尚未讀取啟動項目", "No Startup Inventory"), systemImage: "power.circle", description: Text(t("按「讀取」開始；不會自動啟用、停用或執行任何工作。", "Read metadata to begin. Nothing is automatically enabled, disabled or executed.")))
                } else if visible.isEmpty {
                    ContentUnavailableView(t("沒有符合的項目", "No Matching Items"), systemImage: "line.3.horizontal.decrease.circle", description: Text(t("部分項目只能由系統設定管理；未知狀態不會當成已停用。", "Some items are managed only by System Settings. Unknown state is never treated as disabled.")))
                }
                LazyVStack(spacing: 12) { ForEach(visible) { row in rowView(row) } }
            }.padding(26)
        }
        .onAppear { controller.language = language }
        .onChange(of: language) { _, value in controller.language = value }
        .onDisappear { controller.cancel() }
        .sheet(item: $controller.pendingPlan) { plan in confirmation(plan) }
        .alert(t("啟動項目作業未完成", "Startup Operation Incomplete"), isPresented: Binding(get: { controller.errorMessage != nil }, set: { if !$0 { controller.errorMessage = nil } })) {
            Button(t("關閉", "Close")) { controller.errorMessage = nil }
        } message: { Text(controller.errorMessage ?? "") }
    }

    private func rowView(_ row: StartupRow) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Image(systemName: row.item.scope == .systemDaemon ? "gearshape.2" : "app.badge").font(.title2).foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.item.snapshot?.label ?? row.item.url.lastPathComponent).font(.headline).textSelection(.enabled)
                        Text(row.item.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Text(scopeTitle(row.item.scope)).font(.caption)
                    }
                    Spacer()
                    Button(t("Finder", "Finder")) { controller.reveal(row) }
                }
                if let snapshot = row.item.snapshot {
                    LabeledContent(t("執行檔", "Executable"), value: snapshot.executable ?? t("未知", "Unknown")).font(.callout).textSelection(.enabled)
                    HStack {
                        Label(overrideTitle(row.override), systemImage: "power")
                        Spacer()
                        Text(loadTitle(row.loadState))
                    }.font(.callout)
                    if row.override == .absent {
                        Text(t("launchctl 未設此標籤的啟動覆寫；plist 的 Disabled：", "No explicit launchctl override; plist Disabled: ") + (snapshot.plistDisabled.map(String.init) ?? t("未設定", "not set"))).font(.caption).foregroundStyle(.secondary)
                    }
                    if !snapshot.arguments.isEmpty {
                        DisclosureGroup(t("顯示 ProgramArguments", "Show ProgramArguments")) {
                            Text(snapshot.arguments.enumerated().map { "[\($0.offset)] \($0.element)" }.joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    let reasons = snapshot.guardReasons + (row.duplicateLabel ? [.duplicateLabel] : [])
                    ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
                        Label(reasonTitle(reason), systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                    }
                    if case .unknown(let reason) = row.loadState { Text(t("尚未驗證：", "Not verified: ") + reason).font(.caption).foregroundStyle(.orange) }
                    HStack {
                        Button(t("重新檢查狀態", "Recheck State")) { Task { await controller.inspectState(id: row.id) } }
                            .disabled(controller.isBusy || operationInProgress)
                        Spacer()
                        if snapshot.canManageMetadata && !row.duplicateLabel {
                            Button(t("預覽停用…", "Review Disable…")) { Task { await controller.prepareChange(id: row.id, enable: false) } }
                                .disabled(!controller.canReview(row) || controller.isBusy || operationInProgress)
                            Button(t("預覽啟用…", "Review Enable…")) { Task { await controller.prepareChange(id: row.id, enable: true) } }
                                .disabled(!controller.canReview(row) || controller.isBusy || operationInProgress)
                        } else {
                            Button(t("系統設定中管理", "Manage in System Settings")) { controller.openLoginItemsSettings() }
                        }
                    }
                } else { Text(row.item.error ?? t("無法安全解析此檔案。", "This file could not be safely parsed.")).font(.callout).foregroundStyle(.orange) }
            }.padding(10)
        }
    }

    private func confirmation(_ plan: StartupCommandPlan) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(plan.enable ? t("啟用此背景項目？", "Enable this background item?") : t("停用此背景項目？", "Disable this background item?")).font(.title2.bold())
            Text(plan.snapshot.label ?? "").font(.headline).textSelection(.enabled)
            Text(plan.snapshot.url.path).font(.callout).textSelection(.enabled)
            Text(plan.snapshot.executable ?? "").font(.caption.monospaced()).textSelection(.enabled)
            Text(plan.enable
                 ? t("會為目前使用者設定啟用覆寫；若尚未載入，會交給 launchd 載入。這可能立刻執行該 App 或供應商程式，也可能於下次登入或觸發條件成立時執行。", "Sets an enabled override for your user and loads the job if needed. This can run the app/vendor's code immediately or at a later login or trigger.")
                 : t("會為目前使用者設定停用覆寫，並要求 launchd 移出已載入的工作。背景功能可能中斷；不刪除 plist、不強制殺程序，也不取得管理員權限。", "Sets a disabled override for your user and asks launchd to remove a loaded job. Background functionality may stop. No plist deletion, force-kill or administrator access."))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(plan.commands.enumerated()), id: \.offset) { index, arguments in
                    Text("\(index + 1). launchctl " + arguments.map { String(reflecting: $0) }.joined(separator: " ")).font(.caption.monospaced())
                }
            }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            Text(t("確認後會再次驗證檔案身分、內容與載入範圍；如果發生變動會停止。取消不能保證還原已完成的步驟。", "Confirmation rechecks file identity, content and loaded-service scope. Changes stop the operation. Cancellation cannot undo completed steps.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(t("取消", "Cancel")) { controller.pendingPlan = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(plan.enable ? t("確認啟用", "Confirm Enable") : t("確認停用", "Confirm Disable")) {
                    Task { await controller.applyPendingChange() }
                }.buttonStyle(.borderedProminent).disabled(controller.isBusy || operationInProgress)
            }
        }.padding(26).frame(width: 650)
    }

    private func scopeTitle(_ scope: StartupScope) -> String {
        switch scope {
        case .userAgent: return t("目前使用者 LaunchAgent", "Own-user LaunchAgent")
        case .sharedAgent: return t("共用 LaunchAgent（唯讀）", "Shared LaunchAgent (read-only)")
        case .systemDaemon: return t("LaunchDaemon（唯讀）", "LaunchDaemon (read-only)")
        }
    }
    private func overrideTitle(_ value: StartupOverride?) -> String {
        switch value {
        case .enabled: return t("啟動覆寫：啟用", "Override: enabled")
        case .disabled: return t("啟動覆寫：停用", "Override: disabled")
        case .absent: return t("啟動覆寫：未設定", "Override: not set")
        case nil: return t("啟動覆寫：未知", "Override: unknown")
        }
    }
    private func loadTitle(_ state: StartupLoadState) -> String {
        switch state {
        case .loaded(let service): return t("已載入 · ", "Loaded · ") + service.state + (service.pid.map { " · PID \($0)" } ?? "")
        case .notLoaded: return t("未載入（已確認）", "Not loaded (verified)")
        case .unknown: return t("載入狀態未知", "Loaded state unknown")
        }
    }
    private func reasonTitle(_ reason: StartupGuardReason) -> String {
        switch reason {
        case .readOnlyScope: return t("這個來源只提供唯讀資訊。", "This source is read-only.")
        case .ownership: return t("檔案或目錄不屬於目前使用者。", "File or directory is not owned by the current user.")
        case .writableByOthers: return t("其他使用者可能改寫此設定，停用原生變更。", "Other users can write this configuration; native changes are blocked.")
        case .protectedApple: return t("Apple 項目受保護。", "Apple items are protected.")
        case .protectedBuho: return t("Buho 相關項目不由 MoPanel 變更。", "MoPanel does not change Buho-related items.")
        case .invalidLabel: return t("標籤無法安全對應到 launchctl。", "The label cannot safely identify a launchctl target.")
        case .invalidProgram: return t("執行檔路徑不明或不是完整路徑。", "Executable path is ambiguous or not absolute.")
        case .missingExecutable: return t("找不到可執行的程式。", "Executable is missing or unavailable.")
        case .symbolicExecutable: return t("執行檔路徑含 symbolic link，僅供檢視。", "Executable path contains a symbolic link; view only.")
        case .privilegedConfiguration: return t("含使用者、群組或根目錄覆寫，僅供檢視。", "User, group or root-directory overrides are view-only.")
        case .duplicateLabel: return t("同一使用者範圍有重複標籤，無法唯一對應。", "Duplicate label in this user domain; target is ambiguous.")
        case .unknownState: return t("狀態尚未驗證。", "State is not verified.")
        case .staleSnapshot: return t("設定已變更，請重新整理。", "Configuration changed; refresh required.")
        }
    }
}
