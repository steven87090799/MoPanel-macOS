// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI
import MoPanelCore
import MoPanelProcess
import MoPanelTerminal

struct AppUpdatesView: View {
    @StateObject private var controller: AppUpdatesController
    let language: String
    var operationInProgress: Bool
    @State private var search = ""
    @State private var onlyAvailable = false
    @State private var refreshConfirmation = false

    init(language: String, helperURL: URL? = nil, operationInProgress: Bool = false) {
        _controller = StateObject(wrappedValue: AppUpdatesController(language: language, helperURL: helperURL))
        self.language = language; self.operationInProgress = operationInProgress
    }
    init(controller: AppUpdatesController, language: String, operationInProgress: Bool = false) {
        _controller = StateObject(wrappedValue: controller)
        self.language = language; self.operationInProgress = operationInProgress
    }
    private func t(_ zh: String, _ en: String) -> String { language == "en" ? en : zh }
    private var locked: Bool { controller.isBusy || operationInProgress || !controller.actionsAllowed }
    private var casks: [BrewUpdateItem] {
        controller.items.filter { item in
            (!onlyAvailable || item.outdated != nil) && (search.isEmpty || (item.installed.title + " " + item.id + " " + item.installed.applicationPaths.joined(separator: " ")).localizedCaseInsensitiveContains(search))
        }
    }
    private var localApps: [LocalUpdateApp] {
        controller.localApps.filter { search.isEmpty || ($0.name + " " + $0.url.path).localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if controller.isBusy {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(controller.activity).font(.callout)
                            Spacer()
                            if controller.operationSession?.running == true {
                                Button(t("查看更新作業", "Show Update Operation")) { controller.showOperation = true }
                            } else { Button(t("取消", "Cancel")) { controller.cancelReadOnly() } }
                        }
                        ProgressView().progressViewStyle(.linear)
                        if !controller.activityCommand.isEmpty { ExecutionCommandView(command: controller.activityCommand) }
                        else { Text(t("使用 macOS 原生 API，沒有 CLI 指令。", "Uses native macOS APIs; no CLI command.")).font(.caption).foregroundStyle(.secondary) }
                    }.padding(14).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                if !controller.lastOutcome.isEmpty { Text(controller.lastOutcome).font(.callout).textSelection(.enabled) }
                HStack {
                    TextField(t("搜尋 App、cask 或路徑", "Search apps, casks or paths"), text: $search)
                        .textFieldStyle(.roundedBorder)
                    Toggle(t("只顯示 Homebrew 可用版本", "Only Homebrew version differences"), isOn: $onlyAvailable)
                }
                homebrewSection
                localSection
            }.padding(26)
        }
        .onAppear { controller.language = language }
        .onChange(of: language) { _, value in controller.language = value }
        .onDisappear { controller.cancelReadOnly() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let preview = controller.pendingPreview {
                ScrollView {
                    AppUpdateConfirmationView(controller: controller, preview: preview, language: language).id(preview.id)
                }.frame(maxHeight: 360).padding(.horizontal, 16).padding(.bottom, 12)
            }
        }
        .alert(t("更新 Homebrew 程式與索引？", "Update Homebrew and its metadata?"), isPresented: $refreshConfirmation) {
            Button(t("取消", "Cancel"), role: .cancel) {}
            Button(t("確認更新 Homebrew", "Update Homebrew")) { Task { await controller.refreshMetadataAfterConfirmation() } }
        } message: {
            Text(t("將執行 brew update，透過目前安裝的 Homebrew 更新 Homebrew 本身、已加入的 tap 與套件索引，可能進行 Homebrew 資料遷移。這一步不會由 MoPanel 呼叫 App 升級；完成後請重新檢查版本。", "Runs brew update through the installed Homebrew. It updates Homebrew itself, existing taps and package metadata, and may run Homebrew migrations. MoPanel does not invoke app upgrades in this step. Check versions again afterwards."))
        }
        .alert(t("App 更新無法完成", "App Updates Could Not Finish"), isPresented: Binding(get: { controller.errorMessage != nil }, set: { if !$0 { controller.errorMessage = nil } })) {
            Button(t("關閉", "Close")) { controller.errorMessage = nil }
        } message: { Text(controller.errorMessage ?? "") }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(t("App 更新", "App Updates"), systemImage: "arrow.triangle.2.circlepath.circle").font(.largeTitle.bold())
            Text(t("先檢查可用更新，再選擇要更新的 App。", "Check available updates, then choose apps to update.")).foregroundStyle(.secondary)
            DisclosureGroup(t("更多資訊", "More Information")) {
            Text(t("不自動檢查或更新。Homebrew 版本來自你目前的索引；其他 App 僅辨識本機更新來源，不會上傳 App 清單、讀取帳號憑證或抓取任意安裝檔。", "No automatic checks or updates. Homebrew versions come from your current metadata. Other apps are identified locally; MoPanel does not upload the app inventory, read account credentials or fetch arbitrary installers.")).font(.callout)
            }
            if operationInProgress { Text(t("其他作業執行中，暫停 App 更新操作。", "App update actions are paused while another operation is running.")).foregroundStyle(.orange) }
            if !controller.actionsAllowed { Text(t("測試模式：真實更新與外部啟動已停用。", "Test mode: real updates and external launches are disabled.")).foregroundStyle(.orange) }
        }
    }

    private var homebrewSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Homebrew Casks", systemImage: "shippingbox").font(.title2.bold())
                    Spacer()
                    Button(t("選擇 Homebrew…", "Choose Homebrew…")) { controller.chooseHomebrew() }.disabled(locked)
                    Button(t("檢查更新", "Check Updates")) { Task { await controller.checkHomebrew() } }
                        .buttonStyle(.borderedProminent).disabled(locked)
                }
                if let path = controller.homebrewPath {
                    Text((controller.homebrewVersion ?? "Homebrew") + " · " + path).font(.caption.monospaced()).textSelection(.enabled)
                }
                HStack {
                    if let checked = controller.lastChecked {
                        Text(t("檢查時間：", "Checked: ") + checked.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(t("更新 Homebrew 與索引…", "Update Homebrew and Metadata…")) { refreshConfirmation = true }
                        .disabled(locked || !controller.canRefreshMetadata)
                }
                Text(t("檢查時停用 Homebrew 自動更新與遙測；Homebrew 首次缺少快取時仍可能自行下載公開中繼資料。需要新索引時，請明確確認上方更新操作。", "Homebrew auto-update and analytics are disabled during checks. Homebrew may still fetch public metadata if its cache is missing. Explicitly confirm the metadata update above when you want fresh indexes.")).font(.caption).foregroundStyle(.secondary)
                if controller.lastChecked != nil && !controller.canUpgrade {
                    Text(t("目前 Homebrew 的安全更新參數未通過驗證，僅提供版本資訊。", "The installed Homebrew has not passed the safe upgrade argument checks; version information remains available.")).foregroundStyle(.orange)
                }
                if casks.isEmpty {
                    ContentUnavailableView(controller.lastChecked == nil ? t("尚未檢查 Homebrew", "Homebrew Has Not Been Checked") : t("沒有符合條件的 cask", "No Matching Casks"), systemImage: "shippingbox", description: Text(controller.lastChecked == nil ? t("按檢查更新，讀取已安裝 cask 與官方 JSON 版本資訊。", "Check updates to read installed casks and Homebrew JSON version information.") : t("可調整搜尋或篩選。這不代表其他更新來源的 App 都已是最新版。", "Adjust the search or filter. This does not mean apps from other update sources are current.")))
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(casks) { item in
                            caskRow(item)
                            Divider()
                        }
                    }
                }
                Text(t("直接升級支援：官方 homebrew/cask、可驗證 checksum、一般 App／連結 artifact，且沒有套件相依或自訂安裝／卸載腳本。預覽前還會讀取安裝時的 JSON 配方與收據；舊版 Ruby、缺失、歧義、變更或不安全的卸載紀錄都會停止直接更新。其他 cask 仍列出版本，交由原 App 或 Homebrew 自行處理。MoPanel 不加入 --force、--zap、--no-quarantine 或全體升級。", "Direct upgrades support official homebrew/cask entries with a checksum, ordinary app/link artifacts, and no package dependencies or custom install/uninstall hooks. Before previewing, the installed JSON recipe and receipt are checked too. Legacy Ruby, missing, ambiguous, changed or unsafe uninstall records block direct updates. Other casks still show versions for handling in the app or Homebrew. MoPanel never adds --force, --zap, --no-quarantine or upgrade-all.")).font(.caption).foregroundStyle(.secondary)
            }.padding(12)
        }
    }

    private func caskRow(_ item: BrewUpdateItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "app.gift").font(.title2).foregroundStyle(MoPanelTheme.accent).frame(width: 30)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(item.installed.title).font(.headline)
                    Text(stateTitle(item.state)).font(.caption).foregroundStyle(item.state == .available ? MoPanelTheme.accent : Color.secondary)
                }
                Text(t("已安裝：", "Installed: ") + (item.installed.installed ?? t("未確認", "Unconfirmed")) + "  →  " + t("索引版本：", "Metadata version: ") + item.installed.version).font(.callout.monospaced())
                Text((item.installed.tap ?? t("未知來源", "Unknown source")) + " · " + item.id).font(.caption).foregroundStyle(.secondary)
                if item.installed.applicationPaths.isEmpty {
                    Text(t("Homebrew 未提供可確認的 App 目標路徑。", "Homebrew did not provide a confirmed app target path.")).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(item.installed.applicationPaths, id: \.self) { path in
                    HStack {
                        Text(path).font(.caption.monospaced()).textSelection(.enabled)
                        Button(t("Finder 顯示", "Show in Finder")) { controller.reveal(path) }.buttonStyle(.link).disabled(!controller.actionsAllowed)
                    }
                }
                if item.state == .unsupported {
                    Text(t("未滿足直接更新的安全條件；不會執行自訂安裝器或猜測目標。請使用原 App 更新入口。", "Direct-update safety conditions are not met. No custom installer runs or guessed target is used; use the app's own updater.")).font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if item.state == .available {
                Button(t("預覽更新…", "Preview Update…")) { Task { await controller.prepareUpdate(item) } }
                    .disabled(locked || !controller.canUpgrade)
            }
        }.padding(.vertical, 12)
    }

    private var localSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(t("其他 App 的更新入口", "Other App Update Sources"), systemImage: "square.stack.3d.up").font(.title2.bold())
                    Spacer()
                    Button(t("開啟 App Store", "Open App Store")) { controller.openAppStore() }.disabled(locked)
                    Button(t("讀取本機 App", "Read Local Apps")) { Task { await controller.scanLocalApplications() } }.disabled(locked)
                }
                Text(t("App Store：開啟後選擇側邊欄「更新」，由 Apple 顯示及確認可用版本。這裡不讀取 Apple 帳號或偽造 App Store 更新數量。", "App Store: choose Updates in its sidebar after opening; Apple displays and confirms available versions. This view does not access your Apple Account or invent App Store update counts.")).font(.callout)
                Text(t("Sparkle：只讀取已安裝 App 的 SUFeedURL。通過本機簽章檢查且不含帳密或 query 的 HTTPS URL 可顯示；不抓取 feed、不執行其中的安裝檔，也不宣稱已查到最新版本。", "Sparkle: reads the installed app's SUFeedURL. An HTTPS URL without credentials or query data is displayed only after a local signature check. Feeds and installers are not fetched, and no latest version is claimed.")).font(.caption).foregroundStyle(.secondary)
                if localApps.isEmpty {
                    Text(controller.localInventoryLoaded ? t("沒有符合搜尋的本機 App。", "No local apps match the search.") : t("按讀取本機 App，檢視 /Applications 與 ~/Applications 的 App 資訊與必要簽章；不掃描個人文件。", "Read local apps to inspect app metadata and relevant signatures in /Applications and ~/Applications. Personal documents are not scanned.")).foregroundStyle(.secondary)
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(localApps) { app in
                        HStack(alignment: .top, spacing: 12) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 32, height: 32)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(app.name).font(.headline)
                                Text((app.version ?? t("版本未提供", "Version unavailable")) + " · " + sourceTitle(app.source)).font(.caption).foregroundStyle(.secondary)
                                Text(app.url.path).font(.caption.monospaced()).textSelection(.enabled)
                                if let feed = app.publisherFeed {
                                    Text(t("App 宣告的 feed：", "App-declared feed: ") + feed.absoluteString).font(.caption).textSelection(.enabled)
                                } else if app.feedWasWithheld {
                                    Text(t("偵測到 feed 設定，但簽章／URL 不符合顯示條件，未傳送或顯示網址。", "A feed setting exists, but its signature or URL is unsuitable for display. The URL was neither sent nor displayed.")).font(.caption).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Button(t("Finder", "Finder")) { controller.reveal(app.url.path) }.disabled(!controller.actionsAllowed)
                            if app.source == .appStoreReceipt {
                                Button(t("前往 App Store", "Go to App Store")) { controller.openAppStore() }.disabled(locked)
                            } else {
                                Button(t("開啟 App", "Open App")) { controller.openApp(app) }.disabled(locked)
                            }
                        }.padding(.vertical, 11)
                        Divider()
                    }
                }
                if !controller.localInventoryNote.isEmpty { Text(controller.localInventoryNote).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                Text(t("「App Store 收據存在」只是本機來源線索；Sparkle 設定也可能由 App 執行時改變。開啟 App 後，請使用它自己的「檢查更新」。", "An App Store receipt is local source evidence, and an app may change its Sparkle settings at runtime. After opening an app, use its own Check for Updates command.")).font(.caption).foregroundStyle(.secondary)
            }.padding(12)
        }
    }

    private func stateTitle(_ state: BrewUpdateState) -> String {
        switch state {
        case .available: return t("可預覽更新", "Update preview available")
        case .current: return t("符合目前索引", "Matches current metadata")
        case .selfManaged: return t("由 App 自行更新", "App manages updates")
        case .unversioned: return t("上游使用 latest；無法比較版本", "Upstream uses latest; version comparison unavailable")
        case .pinned: return t("版本已釘選", "Pinned")
        case .disabled: return t("Homebrew 已停用此 cask", "Disabled by Homebrew")
        case .unsupported: return t("需由來源 App／Homebrew 處理", "Handle in the source app or Homebrew")
        }
    }
    private func sourceTitle(_ source: LocalUpdateApp.Source) -> String {
        switch source {
        case .appStoreReceipt: return t("App Store 收據存在", "App Store receipt present")
        case .sparkle: return t("Sparkle 設定存在；尚未查版", "Sparkle setting present; version not checked")
        case .manual: return t("未找到可識別的自動更新來源", "No recognized automatic update source")
        }
    }
}

private struct AppUpdateConfirmationView: View {
    @ObservedObject var controller: AppUpdatesController
    let preview: AppUpdatePreview
    let language: String
    @State private var acknowledged = false
    private func t(_ zh: String, _ en: String) -> String { language == "en" ? en : zh }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(t("確認單一 App 更新", "Confirm One App Update"), systemImage: "exclamationmark.shield").font(.title2.bold())
            Text(preview.plan.title).font(.headline)
            Text(preview.plan.installedVersion + " → " + preview.plan.availableVersion).font(.title3.monospaced())
            Text(preview.plan.identity.qualifiedToken).font(.caption.monospaced()).textSelection(.enabled)
            Text(t("新版配方與安裝時的 JSON 卸載紀錄均已驗證；確認後會再次比對收據與設定。", "Both the current recipe and installed JSON uninstall records were checked. Receipts and configuration are compared again after confirmation.")).font(.caption).foregroundStyle(.secondary)
            Text(t("Homebrew 將下載並替換 App。請先儲存工作並自行關閉 App；MoPanel 不會強制結束。停用自動 Homebrew 更新、清理與無關套件升級，並要求 checksum。Homebrew 保留自身驗證與確認；中斷後不保證完全復原。", "Homebrew will download and replace the app. Save your work and close the app first; MoPanel will not force-quit it. Implicit Homebrew updates, cleanup and unrelated dependent upgrades are disabled, and a checksum is required. Homebrew retains its own checks and prompts. Cancellation does not guarantee full rollback."))
            ScrollView {
                Text(preview.output.isEmpty ? t("Homebrew 未輸出預覽說明。", "Homebrew returned no preview text.") : preview.output)
                    .font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }.frame(minHeight: 150, maxHeight: 260).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            Text("brew " + BrewUpdateCommand.upgrade(preview.plan.identity).arguments.joined(separator: " ")).font(.caption.monospaced()).textSelection(.enabled)
            Toggle(t("我已閱讀官方預覽並確認更新這個 App。", "I reviewed the official preview and confirm this app update."), isOn: $acknowledged)
            HStack {
                Button(t("取消", "Cancel"), role: .cancel) { controller.pendingPreview = nil }
                Spacer()
                Button(t("確認更新", "Confirm Update")) { Task { await controller.confirmUpdate(preview) } }
                    .buttonStyle(.borderedProminent).disabled(!acknowledged || controller.isBusy)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).moPanelGlass(cornerRadius: 18)
    }
}

struct AppUpdateOperationView: View {
    @ObservedObject var controller: AppUpdatesController
    @ObservedObject var session: ManagedProcess
    let language: String
    private func t(_ zh: String, _ en: String) -> String { language == "en" ? en : zh }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(controller.operationTitle).font(.headline)
                Spacer()
                Button(t(controller.operationDetailsExpanded ? "收合詳細資訊" : "詳細資訊", controller.operationDetailsExpanded ? "Hide Details" : "Details")) {
                    controller.operationDetailsExpanded.toggle()
                }
                if session.running { Button(t("要求取消", "Request Cancellation"), role: .destructive) { controller.requestCancellation() } }
                Button(t("關閉", "Close")) { controller.showOperation = false }.disabled(session.running || controller.isBusy)
            }
            if session.running || controller.isBusy { ProgressView().progressViewStyle(.linear) }
            ExecutionCommandView(command: controller.operationCommand)
            if !controller.lastOutcome.isEmpty { Text(controller.lastOutcome).font(.callout).textSelection(.enabled) }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    TerminalPanel(session: session, english: language == "en", engineName: "Homebrew",
                                  isVisible: controller.operationDetailsExpanded, minimumTerminalHeight: 200)
                    Text(t("停止會等待 Homebrew 的安全步驟。已完成的變更可能保留；密碼不會被記錄，互動畫面不會匯出。", "Cancellation waits for Homebrew's safe boundary. Completed changes may remain; passwords are not logged and the interactive screen is not exported."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(height: controller.operationDetailsExpanded ? 320 : 0, alignment: .top)
            .clipped().opacity(controller.operationDetailsExpanded ? 1 : 0).accessibilityHidden(!controller.operationDetailsExpanded)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).moPanelGlass(cornerRadius: 18)
    }
}
