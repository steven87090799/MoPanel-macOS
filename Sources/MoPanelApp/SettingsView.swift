import SwiftUI
import AppKit
import MoPanelCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var forceUpdate = false
    @State private var completionShell: CompletionShell = .zsh
    @State private var diagnosticCommand: MoleCommand = .status
    @State private var diagnosticPreview = true
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeading(title: model.t("設定與工具", "Settings and Tools"), subtitle: model.t("介面與 CLI 分別更新。系統變更仍交由官方 Mole 執行。", "The interface and CLI update independently. Mole remains responsible for system changes."), symbol: "gearshape")
                appearance
                engine
                monitor
                permissions
                systemTools
                diagnostics
                advanced
                activity
                about
            }.padding(26)
        }
    }
    private var appearance: some View {
        GroupBox(model.t("外觀與語言", "Appearance and Language")) {
            VStack(spacing: 14) {
                Picker(model.t("介面語言", "Interface Language"), selection: $model.language) { Text("繁體中文").tag("zh-Hant"); Text("English").tag("en") }.pickerStyle(.segmented)
                Picker(model.t("外觀", "Appearance"), selection: $model.appearance) { Text(model.t("跟隨系統", "System")).tag("system"); Text(model.t("淺色", "Light")).tag("light"); Text(model.t("深色", "Dark")).tag("dark") }.pickerStyle(.segmented)
                Text(model.t("官方 CLI 的原始輸出保留其語言，MoPanel 不翻譯或改寫刪除確認內容。", "Official CLI output remains in its original language so deletion prompts are not rewritten."))
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(12)
        }
    }
    private var engine: some View {
        GroupBox(model.t("官方 Mole CLI", "Official Mole CLI")) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    TextField(model.t("自訂執行檔路徑；留空自動偵測", "Custom executable path; blank for automatic detection"), text: $model.customPath).textFieldStyle(.roundedBorder)
                    Button(model.t("選擇…", "Choose…")) { model.chooseCLI() }
                    Button(model.t("套用並偵測", "Apply and Detect")) { Task { await model.detect() } }
                }.disabled(model.hasRunningOperation || model.isDetecting)
                Text(model.t("自訂路徑必須是可信任的官方執行檔；偵測時會執行 --version 與 --help。", "A custom path must identify a trusted official executable; detection executes --version and --help."))
                    .font(.caption).foregroundStyle(.secondary)
                if let cli = model.installation {
                    LabeledContent(model.t("已安裝版本", "Installed Version"), value: cli.version)
                    LabeledContent(model.t("安裝來源", "Installation Source"), value: cli.source.rawValue)
                    LabeledContent(model.t("呼叫位置", "Invoked Path"), value: cli.executable.path)
                    LabeledContent(model.t("符號連結目標", "Resolved Target"), value: cli.resolved.path)
                    LabeledContent(model.t("已辨識資源位置", "Recognized Resources"), value: cli.resourceLocation ?? model.t("未確認；由官方 launcher 解析", "Unknown; resolved by the official launcher"))
                    Notice(text: cli.compatibility.reason, warning: !cli.compatibility.allowsDestructive)
                    DisclosureGroup(model.t("指令相容性檢查", "Command Compatibility Checks")) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(MoleCommand.allCases) { command in
                                let state = cli.compatibility.commands[command]
                                HStack {
                                    Label(command.rawValue, systemImage: state?.available == true && cli.incompatible[command] == nil ? "checkmark.circle" : "exclamationmark.circle")
                                    Spacer()
                                    Button(model.t("查看說明", "Help")) { model.request(command == .menu || command == .version ? .help : command, options: command == .menu || command == .version || command == .help ? [] : [.help]) }
                                }
                                if let reason = cli.incompatible[command] ?? state?.reason { Text(reason).font(.caption).foregroundStyle(.orange) }
                            }
                            Text(model.t("通過代表版本與公開指令格式吻合，不等同於對新版清理引擎完成實機驗收。每次 JSON 都會另外驗證。", "Passing means version and public flags match, not that a newer engine has been hardware-tested. Every JSON response is separately validated."))
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(8)
                    }
                    HStack {
                        Button("mo --version") { model.request(.version) }
                        Button("mo --help") { model.request(.help) }
                        Button(model.t("官方互動主選單", "Official Main Menu")) { model.request(.menu) }
                    }.disabled(!model.canStart)
                } else { Text(model.t("尚未找到可用的 Mole。", "No usable Mole installation found.")).foregroundStyle(.secondary) }
                Divider()
                HStack {
                    LabeledContent(model.t("官方最新穩定版", "Latest Official Stable"), value: model.release?.tagName ?? model.t("尚未取得", "Not checked"))
                    Button(model.t("檢查更新", "Check for Updates")) { Task { await model.checkRelease() } }
                }
                if let error = model.releaseError { Text(error).font(.caption).foregroundStyle(.orange) }
                HStack {
                    Button(model.canRecoverStable ? model.t("返回官方穩定版…", "Return to Official Stable…") : model.t("更新官方 CLI…", "Update Official CLI…")) { model.request(.update, options: forceUpdate ? [.force] : []) }.disabled(!model.canStart || model.installation?.source == .nix)
                    Button(model.t("安裝 Mole…", "Install Mole…")) { model.homebrewConfirmation = true }.disabled(model.brewURL == nil || model.hasRunningOperation)
                    Link(model.t("官方 Releases", "Official Releases"), destination: URL(string: "https://github.com/tw93/Mole/releases")!)
                }
                if model.canRecoverStable {
                    Notice(text: model.t("已辨識官方腳本的 Nightly／開發通道。可由上方按鈕透過官方 mo update 返回穩定版；其他未驗證的變更功能仍保持停用。", "A verified official-script Nightly/development installation can return to stable through Mole's own update command. Other unverified changes remain disabled."))
                }
                if model.installation?.compatibility.channel == .homebrewHEAD {
                    Notice(text: model.t("目前是 Homebrew HEAD。官方 mo update 不會將 HEAD 切換成穩定版，因此這個恢復入口不適用；需先依官方安裝文件改用穩定版，再重新偵測。", "This is Homebrew HEAD. Mole's update command does not switch HEAD to stable, so stable recovery is unavailable here. Follow the official installation guide to change channels, then re-detect."), warning: true)
                }
                DisclosureGroup(model.t("進階更新選項", "Advanced Update Options")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(model.t("強制重新安裝穩定版（--force）", "Force reinstall the stable version (--force)"), isOn: $forceUpdate)
                        Button(model.t("更新至 Nightly…", "Update to Nightly…")) { model.request(.update, options: [.nightly]) }.disabled(!model.canStart || model.installation?.source != .script)
                        Text(model.t("Nightly 僅限官方指令碼安裝，更新後未驗證的破壞性功能會停用。Homebrew 使用官方更新流程；Nix 必須由 Nix 管理。", "Nightly is restricted to official script installations; unverified destructive features are disabled afterward. Homebrew follows its supported path, while Nix remains Nix-managed."))
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
            }.textSelection(.enabled).padding(12)
        }
    }
    private var monitor: some View {
        GroupBox(model.t("低負載監控", "Monitoring")) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(model.t("在選單列顯示即時監控（MoPanel 新實作）", "Show live monitoring in menu bar (MoPanel addition)"), isOn: $model.menuBarEnabled)
                Text(model.t("預設關閉。開啟後，即使切換頁面或使用其他 App，也會共用現有的單一監控串流。關閉最後一個 MoPanel 視窗或結束 App 時全部停止。", "Off by default. When enabled, the existing single stream continues across pages and while using other apps. Closing the last MoPanel window or quitting stops it."))
                    .font(.caption).foregroundStyle(.secondary)
                Picker(model.t("更新間隔", "Update Interval"), selection: $model.monitoringInterval) { ForEach([1, 2, 5, 10], id: \.self) { Text("\($0) s").tag($0) } }.pickerStyle(.segmented)
                Toggle(model.t("官方高 CPU 行程警示", "Mole high-CPU process alerts"), isOn: $model.processAlertsEnabled)
                Stepper(value: $model.processCPUThreshold, in: 0...3200, step: 25) { Text(model.t("CPU 門檻：", "CPU Threshold: ") + DisplayFormat.percent(model.processCPUThreshold)) }
                Picker(model.t("持續時間視窗", "Sustained Window"), selection: $model.processCPUWindow) { ForEach([60, 120, 300, 600], id: \.self) { Text("\($0) s").tag($0) } }.pickerStyle(.segmented)
                Text(model.t("暫停後重新開始監控即可套用。最多保留 120 筆樣本；未開啟選單列監控時，離開總覽或視窗失去前景就會停止。", "Pause and resume to apply changes. Retains at most 120 samples. Without menu bar monitoring, the stream stops away from Dashboard or the foreground."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(model.t("開啟官方 TUI 儀表板", "Open Official TUI Dashboard")) { model.request(.status) }.disabled(!model.canStart)
            }.padding(12)
        }
    }
    private var permissions: some View {
        GroupBox(model.t("權限與隱私", "Permissions and Privacy")) {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.t("MoPanel 以一般使用者執行。需要管理員權限時，官方 CLI 會在互動視窗使用 sudo／Touch ID；密碼與鍵盤輸入不會寫入 MoPanel 日誌。", "MoPanel runs as your user. Mole requests sudo or Touch ID through the interactive session when needed. Passwords and keystrokes are not written to MoPanel logs."))
                Text(model.t("macOS 沒有可靠的公開 API 可一次證明所有資料夾都有完整磁碟存取權。掃描遇到限制時會保留錯誤或 partial／unavailable 狀態。", "A single public API cannot prove access to every protected folder. Scan failures retain errors or partial/unavailable states."))
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button(model.t("開啟完整磁碟存取權設定", "Open Full Disk Access Settings")) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) }
                    Button(model.t("選擇資料夾測試讀取", "Test a Folder's Read Access")) { model.chooseFolder { url in model.section = .analyze; Task { await model.analyze(path: url.path) } } }.disabled(!model.canStart)
                }
                Notice(text: model.t("請在系統設定自行加入並授權 MoPanel，必要時重新開啟 App。MoPanel 不修改 SIP、Gatekeeper、BuhoCleaner 設定或其他工具的白名單。", "Add and authorize MoPanel in System Settings, then reopen it if needed. MoPanel does not change SIP, Gatekeeper, BuhoCleaner settings or other tools' whitelists."))
            }.padding(12)
        }
    }
    private var systemTools: some View {
        GroupBox(model.t("官方設定工具", "Official Configuration Tools")) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Touch ID").font(.headline)
                HStack {
                    Button(model.t("狀態", "Status")) { model.request(.touchid, options: [.touchID(.status)]) }
                    Button(model.t("預覽啟用", "Preview Enable")) { model.request(.touchid, options: [.touchID(.enable), .dryRun]) }
                    Button(model.t("啟用…", "Enable…")) { model.request(.touchid, options: [.touchID(.enable)]) }
                    Button(model.t("預覽停用", "Preview Disable")) { model.request(.touchid, options: [.touchID(.disable), .dryRun]) }
                    Button(model.t("停用…", "Disable…")) { model.request(.touchid, options: [.touchID(.disable)]) }
                    Button(model.t("官方選單", "Official Menu")) { model.request(.touchid) }
                }
                Divider()
                Text(model.t("Shell 自動補全", "Shell Completion")).font(.headline)
                HStack {
                    Picker("Shell", selection: $completionShell) { ForEach(CompletionShell.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 180)
                    Button(model.t("顯示補全腳本", "Show Completion Script")) { model.request(.completion, options: [.completionShell(completionShell)]) }
                    Button(model.t("預覽安裝", "Preview Installation")) { model.request(.completion, options: [.dryRun]) }
                    Button(model.t("安裝至預設 Shell…", "Install to Default Shell…")) { model.request(.completion) }
                }
                Divider()
                HStack {
                    Button(model.t("清理白名單", "Clean Whitelist")) { model.request(.clean, options: [.whitelist]) }
                    Button(model.t("最佳化白名單", "Optimize Whitelist")) { model.request(.optimize, options: [.whitelist]) }
                    Button(model.t("專案掃描路徑", "Project Search Paths")) { model.request(.purge, options: [.purgePaths]) }
                }
            }.disabled(!model.canStart).padding(12)
        }
    }
    private var advanced: some View {
        GroupBox {
            DisclosureGroup(model.t("進階：移除 CLI", "Advanced: Remove CLI")) {
                VStack(alignment: .leading, spacing: 12) {
                    Notice(text: model.t("移除 Mole 後，MoPanel 會失去核心功能，需重新安裝官方 CLI。這不是解除安裝 MoPanel。", "Removing Mole disables MoPanel's core features until you reinstall the CLI. This does not uninstall MoPanel."), warning: true)
                    HStack {
                        Button(model.t("預覽移除範圍", "Preview Removal")) { model.request(.remove, options: [.dryRun]) }
                        Button(model.t("移除官方 CLI…", "Remove Official CLI…"), role: .destructive) { model.request(.remove) }
                    }.disabled(!model.canStart || model.installation?.source == .nix)
                }.padding(.top, 12)
            }.padding(12)
        }
    }
    private var diagnostics: some View {
        GroupBox(model.t("進階診斷入口", "Advanced Diagnostic Commands")) {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.t("以官方 --debug 啟動指定功能，保留官方介面與所有確認。也可檢查未在原生資料頁顯示的細節。", "Launch a command with official --debug diagnostics, retaining its interface and confirmations. This exposes details not shown by native data pages."))
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Picker(model.t("指令", "Command"), selection: $diagnosticCommand) {
                        ForEach(MoleCommand.allCases.filter { ![.menu, .help, .version].contains($0) }) { command in Text(command.rawValue).tag(command) }
                    }.frame(width: 230)
                    if diagnosticCommand.hasDryRun { Toggle(model.t("先預覽", "Dry Run"), isOn: $diagnosticPreview) }
                    Spacer()
                    Button(model.t("官方說明", "Help")) { model.request(diagnosticCommand, options: [.help]) }
                    Button(model.t("開啟診斷", "Open Diagnostics")) {
                        model.request(diagnosticCommand, options: [.debug] + (diagnosticCommand.hasDryRun && diagnosticPreview ? [.dryRun] : []))
                    }
                }.disabled(!model.canStart)
            }.padding(12)
        }
    }
    private var activity: some View {
        GroupBox(model.t("本次 MoPanel 作業紀錄", "Current MoPanel Session")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text(model.t("只記錄指令與結束狀態，不記錄互動輸入。最多保留 200 筆於記憶體。", "Records command and exit status, not interactive input. At most 200 entries stay in memory.")).font(.caption).foregroundStyle(.secondary); Spacer(); Button(model.t("匯出", "Export")) { model.exportActivity() } }
                if model.activities.isEmpty { Text(model.t("目前沒有作業紀錄。", "No operations recorded yet.")).foregroundStyle(.secondary) }
                ForEach(model.activities.prefix(20)) { item in
                    HStack(alignment: .top) { Text(item.date, style: .time).font(.caption.monospacedDigit()); Text(item.command).font(.caption.monospaced()); Spacer(); Text(item.outcome).font(.caption).foregroundStyle(.secondary) }
                }
            }.padding(12)
        }
    }
    private var about: some View {
        GroupBox(model.t("關於 MoPanel", "About MoPanel")) {
            VStack(alignment: .leading, spacing: 10) {
                Text("MoPanel 0.1.0 · macOS 27+ · Apple Silicon").font(.headline)
                Text(model.t("非官方原生 GUI，與 Mole／Mole for Mac 無隸屬或背書關係。獨立名稱及圖示；官方 CLI 不內建、不修改。", "An unofficial native GUI, not affiliated with or endorsed by Mole or Mole for Mac. Independent name and icon; the official CLI is neither bundled nor modified."))
                Text(model.t("程式碼採 GPL-3.0-or-later；原生終端使用 MIT 授權 SwiftTerm。授權與對應原始碼包含於交付包。", "GPL-3.0-or-later source with the MIT-licensed SwiftTerm native terminal. Licenses and corresponding source accompany the distribution."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.t("本機測試版使用 ad-hoc 簽章；不代表 Developer ID 簽章或 Apple 公證。GUI 更新須更換整個 App；CLI 更新可在上方獨立進行。", "Local builds use ad-hoc signing, not Developer ID or Apple notarization. Replace the app to update MoPanel; update the CLI independently above."))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(12)
        }
    }
}
