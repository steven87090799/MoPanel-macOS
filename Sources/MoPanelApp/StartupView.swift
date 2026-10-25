// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit
import MoPanelCore

struct StartupView: View {
    @ObservedObject var controller: StartupController
    let language: String
    var operationInProgress = false
    @State private var search = ""
    @State private var scope = "all"
    @State private var onlyManageable = false
    @State private var expandedRows = Set<String>()
    private func t(_ zh: String, _ en: String) -> String { language == "en" ? en : zh }
    private var visible: [StartupRow] {
        controller.rows.filter { row in
            (scope == "all" || row.item.scope.rawValue == scope) && (!onlyManageable || controller.canReview(row)) &&
            (search.isEmpty || [displayName(row), row.item.url.path, row.item.snapshot?.label ?? "", row.item.snapshot?.executable ?? ""].contains(where: { $0.localizedCaseInsensitiveContains(search) }))
        }
    }

    private var extraServices: [BackgroundStartupItem] {
        controller.backgroundItems.filter { item in
            guard item.kind == .service, controller.plistRow(matching: item) == nil, matchesSearch(item), !onlyManageable else { return false }
            let serviceScope: StartupScope = item.isDaemon ? .systemDaemon : (item.url?.path.hasPrefix("/Library/LaunchAgents/") == true ? .sharedAgent : .userAgent)
            return scope == "all" || scope == serviceScope.rawValue
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: t("啟動與背景項目", "Startup and Background Items"), subtitle: t("檢視登入時啟動與背景服務。點選項目可查看詳細資料。", "Review startup and background services. Select an item for details."), symbol: "power.circle") {
                    Button(t("讀取／重新整理", "Read / Refresh")) { Task { await controller.refresh() } }.buttonStyle(.borderedProminent)
                        .disabled(controller.isBusy || operationInProgress)
                }
                HStack {
                    Button(t("開啟登入項目系統設定", "Open Login Items Settings")) { controller.openLoginItemsSettings() }
                    Spacer()
                    if controller.isBusy {
                        ProgressView(value: controller.progress).frame(width: 120)
                        Button(t("停止", "Stop")) { controller.cancel() }
                    }
                }
                DisclosureGroup(t("更多選項與清單來源", "More Options and Sources")) {
                Text(t("分別讀取 macOS 的登入／背景登錄資料，以及使用者與系統背景服務設定檔；同一服務不重複計數。系統管理的項目可到系統設定調整。", "Reads macOS login/background registrations and user/system service configuration files. A service is counted once. System-managed entries can be changed in System Settings.")).font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button(t("重讀登入與背景 App", "Reload Login and Background Apps")) { Task { await controller.refreshBackgroundItems() } }.disabled(controller.isBusy || operationInProgress)
                    Button(t("匯入系統清單…", "Import System Report…")) { controller.importBackgroundItems() }.disabled(controller.isBusy || operationInProgress)
                }
                ExecutionCommandView(command: "sfltool dumpbtm")
                HStack {
                    TextField(t("搜尋 App、服務或路徑", "Search app, service or path"), text: $search).textFieldStyle(.roundedBorder)
                    Picker(t("服務範圍", "Service scope"), selection: $scope) {
                        Text(t("全部", "All")).tag("all")
                        ForEach(StartupScope.allCases, id: \.rawValue) { value in Text(scopeTitle(value)).tag(value.rawValue) }
                    }.frame(width: 210)
                    Toggle(t("僅可管理", "Manageable only"), isOn: $onlyManageable).toggleStyle(.checkbox)
                }
                }
                if !controller.statusMessage.isEmpty { Text(controller.statusMessage).font(.callout) }
                if let date = controller.backgroundReadAt {
                    Text((controller.backgroundIsImported ? t("系統清單快照 · ", "Imported system snapshot · ") : t("系統清單 · ", "System list · ")) + date.formatted(date: .abbreviated, time: .standard))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let problem = controller.backgroundReadError { Text(problem).font(.caption).foregroundStyle(.secondary) }
                ForEach(controller.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                if !controller.hasLoaded {
                    ContentUnavailableView(t("尚未讀取啟動項目", "No Startup Inventory"), systemImage: "power.circle", description: Text(t("按「讀取」開始；不會自動啟用、停用或執行任何工作。", "Read metadata to begin. Nothing is automatically enabled, disabled or executed.")))
                } else if visible.isEmpty && extraServices.isEmpty && !controller.backgroundItems.contains(where: { $0.kind != .service && matchesSearch($0) && !onlyManageable }) {
                    ContentUnavailableView(t("沒有符合的項目", "No Matching Items"), systemImage: "line.3.horizontal.decrease.circle", description: Text(t("部分項目只能由系統設定管理；未知狀態不會當成已停用。", "Some items are managed only by System Settings. Unknown state is never treated as disabled.")))
                }
                if !onlyManageable {
                    backgroundSection(.login, title: t("登入時啟動", "Open at Login"))
                    backgroundSection(.backgroundApp, title: t("允許在背景執行", "Allow in Background"))
                }
                VStack(alignment: .leading, spacing: 12) {
                    let extra = extraServices
                    Text(t("背景服務", "Background Services") + " · \(visible.count + extra.count)").font(.headline)
                    LazyVStack(spacing: 8) {
                        ForEach(visible) { row in rowView(row) }
                        ForEach(extra) { item in backgroundRow(item) }
                    }
                }
            }.padding(26)
        }
        .task { controller.language = language; if !controller.hasLoaded { await controller.refresh() } }
        .onChange(of: language) { _, value in controller.language = value }
        .onDisappear { controller.cancel() }
        .safeAreaInset(edge: .bottom) { if let plan = controller.pendingPlan { confirmation(plan).moPanelGlass(cornerRadius: 18).padding(12) } }
        .alert(t("啟動項目作業未完成", "Startup Operation Incomplete"), isPresented: Binding(get: { controller.errorMessage != nil }, set: { if !$0 { controller.errorMessage = nil } })) {
            Button(t("關閉", "Close")) { controller.errorMessage = nil }
        } message: { Text(controller.errorMessage ?? "") }
    }

    private func matchesSearch(_ item: BackgroundStartupItem) -> Bool {
        search.isEmpty || [item.name, item.identifier, item.developer ?? "", item.url?.path ?? ""].contains { $0.localizedCaseInsensitiveContains(search) }
    }

    private func backgroundSection(_ kind: BackgroundStartupItem.Kind, title: String) -> some View {
        let items = controller.backgroundItems.filter { $0.kind == kind && matchesSearch($0) }
        return VStack(alignment: .leading, spacing: 10) {
            Text(title + (controller.backgroundReadAt != nil ? " · \(items.count)" : "")).font(.headline)
            if controller.backgroundReadAt == nil {
                HStack {
                    Text(t("尚未讀取完整系統清單", "Complete system list has not been read")).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button(t("在系統設定查看", "View in System Settings")) { controller.openLoginItemsSettings() }
                }.padding(14).moPanelGlass(cornerRadius: 14)
            } else if items.isEmpty {
                Text(t("沒有符合的項目", "No matching items")).font(.callout).foregroundStyle(.secondary)
            } else { LazyVStack(spacing: 8) { ForEach(items) { item in backgroundRow(item) } } }
        }
    }

    private func backgroundRow(_ item: BackgroundStartupItem) -> some View {
        let path = appPath(item)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button { toggleExpanded(item.id) } label: {
                    HStack(spacing: 12) {
                        AppIcon(path: path ?? item.url?.path ?? "")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).font(.headline)
                            Text(item.developer ?? (item.kind == .service ? t("背景服務", "Background service") : "App")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                Text(item.enabled.map { $0 ? (item.kind == .backgroundApp ? t("已允許", "Allowed") : t("已啟用", "Enabled")) : (item.kind == .backgroundApp ? t("未允許", "Not allowed") : t("已停用", "Disabled")) } ?? t("狀態待確認", "State unknown"))
                    .font(.caption).foregroundStyle(item.enabled == true ? MoPanelTheme.positive : Color.secondary)
                Button { toggleExpanded(item.id) } label: { Image(systemName: "info.circle") }.buttonStyle(.plain)
                    .accessibilityLabel(t("查看 ", "Details for ") + item.name)
                Button(t("系統設定", "System Settings")) { controller.openLoginItemsSettings() }.buttonStyle(.borderless)
                    .help(t("在 macOS 登入項目設定調整這個項目", "Manage this item in macOS Login Items settings"))
            }
            if expandedRows.contains(item.id) {
                Text(item.kind == .login ? t("登入 Mac 時可自動開啟；由 macOS 登入項目設定管理。", "May open automatically when you log in. Managed by macOS Login Items.") : item.kind == .service ? t("提供 App 的背景功能，依登入、排程或需求啟動；已啟用不代表現在正在執行。", "Provides app background features at login, on a schedule or on demand. Enabled does not mean currently running.") : t("允許這個 App 的背景功能執行，不代表它現在正在使用 CPU。由系統設定管理。", "Allows this app's background features; it does not mean it is currently using CPU. Managed in System Settings."))
                    .font(.callout).foregroundStyle(.secondary)
                if let url = item.url { Text(url.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
                if let executable = item.executable { LabeledContent(t("執行檔", "Executable"), value: executable).font(.caption).textSelection(.enabled) }
                LabeledContent(t("識別碼", "Identifier"), value: item.launchLabel).font(.caption)
                if item.kind == .service {
                    LabeledContent(t("範圍", "Scope"), value: item.isDaemon ? t("系統背景服務", "System service") : t("使用者背景服務", "User service")).font(.caption)
                }
                ForEach(Array(item.loginHelpers.enumerated()), id: \.offset) { _, helper in
                    LabeledContent(helper.name, value: helper.enabled.map { $0 ? t("登入輔助程式：已啟用", "Login helper: enabled") : t("登入輔助程式：已停用", "Login helper: disabled") } ?? t("登入輔助程式：狀態待確認", "Login helper: state unknown")).font(.caption)
                }
                if let date = controller.backgroundReadAt { Text(t("清單更新於 ", "Report updated ") + date.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary) }
                Text(t("查看資料使用 sfltool dumpbtm；此處不會修改登錄資料。", "Read using sfltool dumpbtm. Registration data is not changed here.")).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(14).moPanelGlass(cornerRadius: 14)
    }

    private func toggleExpanded(_ id: String) {
        if expandedRows.contains(id) { expandedRows.remove(id) } else { expandedRows.insert(id) }
    }

    private func rowView(_ row: StartupRow) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button {
                        if expandedRows.contains(row.id) { expandedRows.remove(row.id) } else { expandedRows.insert(row.id) }
                    } label: {
                        HStack(spacing: 12) {
                            AppIcon(path: appPath(row) ?? row.item.url.path)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(displayName(row)).font(.headline)
                                Text(row.item.scope == .systemDaemon ? t("系統背景服務", "System service") : t("登入與背景服務", "Startup and background service")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Button { toggleExpanded(row.id) } label: { Image(systemName: "info.circle") }.buttonStyle(.plain)
                        .accessibilityLabel(t("查看 ", "Details for ") + displayName(row))
                    if controller.canReview(row), let enabled = enabled(row) {
                        Toggle("", isOn: Binding(get: { enabled }, set: { value in Task { await controller.prepareChange(id: row.id, enable: value) } }))
                            .toggleStyle(.switch).labelsHidden().disabled(controller.isBusy || operationInProgress)
                            .help(t("啟用或停用", "Enable or disable"))
                    } else {
                        Button(enabled(row).map { $0 ? t("已啟用", "Enabled") : t("已停用", "Disabled") } ?? t("查看狀態", "View state")) {
                            expandedRows.insert(row.id)
                            Task { await controller.inspectState(id: row.id) }
                        }.buttonStyle(.borderless).disabled(controller.isBusy)
                    }
                }
                if expandedRows.contains(row.id) {
                Text(row.item.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button(t("在 Finder 中顯示", "Show in Finder")) { controller.reveal(row) }
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
                }
            }.padding(10)
        }
    }

    private func appPath(_ row: StartupRow) -> String? {
        if let item = controller.backgroundItem(matching: row), let path = appPath(item) { return path }
        return associatedApp(row.item.snapshot?.executable ?? "", identifier: row.item.snapshot?.label ?? "")
    }
    private func appPath(_ item: BackgroundStartupItem) -> String? {
        for path in [item.associatedAppURL?.path, item.executable, item.url?.path].compactMap({ $0 }) {
            if let app = associatedApp(path, identifier: item.bundleIdentifier ?? item.launchLabel) { return app }
        }
        return associatedApp("", identifier: item.bundleIdentifier ?? item.launchLabel)
    }
    private func associatedApp(_ path: String, identifier: String) -> String? {
        var app: String?
        if let range = path.range(of: ".app/") { app = String(path[..<range.lowerBound]) + ".app" }
        else if path.hasSuffix(".app") { app = path }
        // Reports can retain a no-longer-present registration path. Resolve the
        // current app through Launch Services rather than inventing a home path.
        if let app, FileManager.default.fileExists(atPath: app) { return app }
        var candidate = identifier
        for _ in 0..<8 {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate) { return url.path }
            guard let dot = candidate.lastIndex(of: ".") else { break }
            candidate = String(candidate[..<dot])
        }
        return nil
    }
    private func displayName(_ row: StartupRow) -> String {
        if let item = controller.backgroundItem(matching: row) { return item.name }
        if let path = appPath(row), let bundle = Bundle(path: path) {
            return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
        return row.item.snapshot?.executable.map { URL(fileURLWithPath: $0).lastPathComponent } ?? row.item.snapshot?.label ?? row.item.url.deletingPathExtension().lastPathComponent
    }
    private func enabled(_ row: StartupRow) -> Bool? {
        guard row.loadState.isVerified else { return nil }
        switch row.override {
        case .enabled: return true
        case .disabled: return false
        case .absent: return !(row.item.snapshot?.plistDisabled ?? false)
        case nil: return nil
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
        }.padding(20).frame(maxWidth: .infinity)
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
