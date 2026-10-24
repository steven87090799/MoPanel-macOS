import SwiftUI
import MoPanelCore

struct MaintenanceView: View {
    @EnvironmentObject private var model: AppModel
    let section: AppSection
    @State private var debug = false
    @State private var external = false
    @State private var volume = ""
    @State private var includeEmpty = false
    @State private var unattended = false
    private var command: MoleCommand { section.command ?? .help }
    private var options: [MoleOption] {
        var value: [MoleOption] = debug ? [.debug] : []
        if section == .clean && external { value.append(.externalVolume(volume)) }
        if section == .purge && includeEmpty { value.append(.includeEmpty) }
        return value
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeading(title: model.t(section.zh, section.en), subtitle: subtitle, symbol: section.symbol)
                GlassEffectContainer(spacing: 18) {
                    GlassCard {
                        Label(model.t("先看結果，再決定", "Preview before making changes"), systemImage: "eye").font(.title3.bold())
                        Text(model.t("預覽由官方 Mole 執行，介面保留它實際提供的項目、容量、保護狀態與原因。部分路徑或略過原因需開啟下方「詳細診斷（--debug）」；官方未提供的明細不會補造。", "Mole performs the preview. The interface preserves the items, sizes, protection status and reasons it actually reports. Some paths or skip reasons require Detailed Diagnostics (--debug) below; missing details are not invented."))
                            .foregroundStyle(.secondary)
                        HStack {
                            NativeActionButton(model.t("掃描並預覽", "Scan and Preview"),
                                               identifier: "mopanel.maintenance.\(command.rawValue).preview",
                                               systemImage: "magnifyingglass", appearance: .prominent) {
                                model.request(command, options: options + [.dryRun], title: model.t("安全預覽 · ", "Preview · ") + model.t(section.zh, section.en))
                            }.controlSize(.large)
                            NativeActionButton(model.t("檢查並開始操作", "Review and Start"),
                                               identifier: "mopanel.maintenance.\(command.rawValue).review",
                                               systemImage: "play.fill") {
                                model.request(command, options: options + (section == .purge && unattended ? [.yes] : []), title: model.t(section.zh, section.en))
                            }.controlSize(.large)
                            Spacer()
                            Button(model.t("官方說明", "CLI Help")) { model.request(command, options: [.help]) }
                        }.disabled(!model.canStart || (section == .clean && external && volume.isEmpty))
                    }
                }
                Notice(text: safetyText, warning: section != .optimize)
                GroupBox(model.t("操作選項", "Options")) {
                    VStack(alignment: .leading, spacing: 16) {
                        if section == .clean {
                            Toggle(model.t("清理指定外接磁碟的系統中繼資料", "Clean OS metadata on an external volume"), isOn: $external)
                            if external {
                                HStack {
                                    Text(volume.isEmpty ? model.t("尚未選擇磁碟", "No volume selected") : volume).font(.callout.monospaced()).textSelection(.enabled)
                                    Spacer()
                                    Button(model.t("選擇磁碟…", "Choose Volume…")) { model.chooseFolder { volume = $0.path } }
                                }
                                Text(model.t("只接受 /Volumes 下的掛載位置；是否為外接磁碟及可清理項目仍由官方 CLI 驗證。", "Choose a mount beneath /Volumes. Mole still validates whether it is external and what can be removed."))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button(model.t("管理清理白名單／保護垃圾桶", "Manage Clean Whitelist / Protect Trash")) { model.request(.clean, options: [.whitelist]) }.disabled(!model.canStart)
                        }
                        if section == .optimize {
                            Button(model.t("管理最佳化白名單", "Manage Optimization Whitelist")) { model.request(.optimize, options: [.whitelist]) }.disabled(!model.canStart)
                        }
                        if section == .purge {
                            Toggle(model.t("顯示零容量的專案產物目錄（--include-empty）", "Show zero-size artifact directories (--include-empty)"), isOn: $includeEmpty)
                            Button(model.t("選擇與編輯專案掃描路徑…", "Choose and Edit Project Search Paths…")) { model.request(.purge, options: [.purgePaths], title: model.t("專案掃描路徑", "Project Search Paths")) }.disabled(!model.canStart)
                            Text(model.t("官方 --paths 會啟動 MoPanel 原生路徑編輯器；可用資料夾選擇器新增路徑並儲存。", "Mole's --paths command opens MoPanel's native path editor. Add folders with a picker and save the configuration."))
                                .font(.caption).foregroundStyle(.secondary)
                            DisclosureGroup(model.t("進階：無人值守參數", "Advanced: Unattended Flag")) {
                                Toggle(model.t("執行時傳入 --yes，省略部分 CLI 確認", "Pass --yes to skip some CLI confirmations"), isOn: $unattended)
                                Notice(text: model.t("此選項會套用 Mole 的預設合格項目，不代表 GUI 有逐項選取。預設關閉；執行前仍有 MoPanel 的明確確認。", "This applies Mole's default eligible set, not a per-item GUI selection. It is off by default, and MoPanel still asks for explicit confirmation."), warning: true)
                            }
                        }
                        Toggle(model.t("顯示詳細診斷（--debug）", "Show detailed diagnostics (--debug)"), isOn: $debug)
                    }.padding(12)
                }
                GroupBox(model.t("官方工作範圍", "Official Scope")) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(scope, id: \.self) { item in Label(item, systemImage: "checkmark.shield").frame(maxWidth: .infinity, alignment: .leading) }
                        Text(model.t("這是功能說明；實際可處理項目以這台 Mac 的掃描結果為準。", "These describe supported categories. Actual eligibility depends on the scan of this Mac."))
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(12)
                }
                Notice(text: model.t("這些指令沒有穩定的逐項 JSON 刪除 API。MoPanel 保留官方選取與確認，不會把文字解析成自訂刪除計畫，也不會代送選取編號。", "These commands have no stable per-item JSON deletion API. MoPanel preserves official selection and confirmation and never converts text or guessed item numbers into a deletion plan."))
                HStack {
                    Button(model.t("查看操作歷史與實際結果", "View History and Actual Results")) { model.section = .history; Task { await model.loadHistory() } }
                        .disabled(!model.canStart)
                    Spacer()
                    Text(model.t("執行中的停止按鈕位於操作視窗。", "Stop is available in the operation window.")).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(26)
        }
    }
    private var subtitle: String {
        switch section {
        case .clean: return model.t("依官方保護規則處理快取、日誌與暫存資料。", "Clean caches, logs and temporary data under Mole's protection rules.")
        case .optimize: return model.t("由 Mole 判斷是否需要維護，保留不可用與略過原因。", "Mole determines which maintenance is needed and reports unavailable or skipped tasks.")
        case .purge: return model.t("清理可重建的開發產物，保留原始碼與 Git 資料。", "Review rebuildable development artifacts with source and Git protection.")
        case .installer: return model.t("找出不再需要的安裝檔，逐項確認後清理。", "Find installers and review them before removal.")
        case .slim: return model.t("官方 Apple Silicon 瘦身流程，先驗證再替換。", "Mole's Apple Silicon thinning workflow validates copies before replacing apps.")
        default: return ""
        }
    }
    private var safetyText: String {
        switch section {
        case .clean: return model.t("Clean 可能永久刪除檔案並清空家目錄垃圾桶。想保留 Trash，請先在白名單中保護它。", "Clean can permanently delete files and empty your home Trash. Protect Trash in the whitelist first if you want to retain it.")
        case .purge: return model.t("Purge 是永久刪除。它會重新檢查專案邊界、近期使用與 Git 資料；請確認最後的官方清單。", "Purge permanently deletes artifacts after rechecking project boundaries, recent use and Git data. Review the final official list.")
        case .installer: return model.t("Installer 使用永久刪除；ZIP 不一定都是安裝程式，請特別確認清單。", "Installer deletes permanently. A ZIP may contain more than an installer; inspect the list carefully.")
        case .slim: return model.t("只處理 Mole 判定可用的 Universal App。簽章或 Gatekeeper 檢查失敗會保留原 App；不保證每款 App 都可瘦身。", "Only eligible Universal apps are processed. Failed signature or Gatekeeper checks preserve the original app.")
        default: return model.t("部分維護會改變系統狀態或要求管理員權限。MoPanel 不使用 root 啟動，也不修改其他清理軟體的設定。", "Some maintenance changes system state or requests administrator access. MoPanel itself runs as your user and does not change other cleaners' settings.")
        }
    }
    private var scope: [String] {
        switch section {
        case .clean: return [model.t("使用者快取、日誌、暫存與垃圾桶", "User caches, logs, temporary files and Trash"), model.t("應用程式與瀏覽器可清理快取", "Eligible application and browser caches"), model.t("開發工具快取與可確認的應用程式殘留", "Development caches and verified app leftovers")]
        case .optimize: return [model.t("Finder／QuickLook／圖示快取維護", "Finder, QuickLook and icon-cache maintenance"), model.t("網路快取與安全的資料庫維護", "Network cache and safe database maintenance"), model.t("官方結果：已套用、未變更、略過、不可用、失敗", "Official outcomes: applied, unchanged, skipped, unavailable, failed")]
        case .purge: return [model.t("Xcode、Node.js、Rust、Python 等專案產物", "Xcode, Node.js, Rust, Python and other project artifacts"), model.t("近期產物預設保守處理", "Conservative handling of recent artifacts"), model.t("Git 追蹤資料、巢狀倉庫與專案邊界檢查", "Tracked-file, nested-repository and project-boundary checks")]
        case .installer: return ["DMG · PKG · ISO · XIP · ZIP", model.t("官方選單顯示路徑及容量", "Official selection shows paths and sizes"), model.t("依 Mole 的掃描位置與排除規則", "Mole-defined discovery locations and exclusions")]
        case .slim: return [model.t("掃描 Universal App 與預估可回收容量", "Universal app discovery and reclaimable-space preview"), model.t("在副本處理，執行簽章及 Gatekeeper 驗證", "Thin a copy and validate signature and Gatekeeper assessment"), model.t("通過驗證才替換，原 App 移至垃圾桶", "Replace only verified copies; move originals to Trash")]
        default: return []
        }
    }
}
