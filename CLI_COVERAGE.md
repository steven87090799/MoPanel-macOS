# 官方 Mole CLI 功能覆蓋表

盤點基準：官方 macOS 穩定版 **V1.62.0**，commit `91a7bf44f96995361b10b5a0e9efae36a1490bf9`。本表區分「有可操作入口」與「純原生資料介面」；以 PTY 呈現的官方選取器、確認畫面及結果，沒有被宣稱成原生項目級 API。實際已執行的測試請見 `TEST_REPORT.md`。

## 共用程式位置

| 簡稱 | 程式位置與責任 |
| --- | --- |
| Commands | `Sources/MoPanelCore/MoleCommand.swift`：所有指令／參數的型別、組合驗證、argv 與風險分類 |
| Models | `Sources/MoPanelCore/MoleModels.swift`：JSON／NDJSON 解碼、掃描覆蓋狀態、歷史歸屬、App 清單 |
| Compatibility | `Sources/MoPanelCore/Compatibility.swift`：版本與 help 能力檢查、卸載名稱唯一性驗證 |
| Probe | `Sources/MoPanelApp/CLIProbe.swift`：CLI 搜尋、版本、來源、資源目錄、指紋與更新檢查 |
| Model | `Sources/MoPanelApp/AppModel.swift`：讀取、預覽、確認、執行、取消與官方 CLI 呼叫 |
| Native dashboard | `Sources/MoPanelApp/DashboardView.swift`：原生監控及圖表 |
| Maintenance | `Sources/MoPanelApp/MaintenanceView.swift`：清理／最佳化／Purge／Installer／Slim 操作入口 |
| Operation sheet | `Sources/MoPanelApp/ContentView.swift`：風險確認、官方互動視窗、方向／選取／確認按鈕 |
| Terminal | `Sources/MoPanelTerminal/TerminalPanel.swift`：SwiftTerm 原生 AppKit 終端，不使用 WebView 或 Node |
| Process | `Sources/MoPanelProcess/ManagedProcess.swift`、`Sources/MoPanelGuardian/main.c`：直接 argv、PTY、父程序壽命、逾時及子程序管理 |
| Paths editor | `Sources/MoPanelEditor/main.swift`、`Sources/MoPanelProcess/PurgePathsDocument.swift`：透過官方 `EDITOR` 入口開啟原生路徑編輯器，由官方指令重新載入 |

## 指令與有意義的參數

| 官方入口 | GUI 入口／操作 | 介面型態 | Adapter 與限制 |
| --- | --- | --- | --- |
| `mo` | 設定中的官方主選單 | 內嵌 PTY | `.menu`。可進入破壞性操作，會先顯示風險確認；不自動傳送選項或同意 |
| `mo status` | 總覽的官方互動監控 | PTY 備援 | `.status`；保留官方 TUI 的核心顯示切換與快捷鍵 |
| `mo status --json` | 總覽單次更新 | 原生 JSON | `.json`、`MoleJSON.decodeStatus`；沒有資料的感測器顯示不可用 |
| `mo status --watch` | 總覽即時監控開關 | 原生 NDJSON | `.watch`、`NDJSONFramer`；總覽與選單列共用一個子程序。預設離開頁面／視窗不活躍時停止；使用者另行啟用選單列監控時保留同一串流，暫停或退出 App 後停止 |
| `mo status --interval DURATION` | 監控更新間隔 | 原生控制項 | `.intervalSeconds`；GUI 限制 1–3600 秒，送出正式 Go duration，例如 `2s` |
| `--proc-cpu-alerts[=false]` | 高 CPU 程序提醒開關 | 原生控制項 | `.procCPUAlerts`；傳入 `--proc-cpu-alerts=true/false` |
| `--proc-cpu-threshold PERCENT` | CPU 提醒門檻 | 原生控制項 | `.procCPUThreshold`；非負有限值，程序多核心 CPU 可超過 100% |
| `--proc-cpu-window DURATION` | CPU 提醒持續時間 | 原生控制項 | `.procCPUWindowSeconds`；大於零 |
| `mo clean` | 系統清理：執行 | 原生啟動＋官方輸出／PTY | `.clean`。必須確認永久刪除風險；可能包含清空家目錄垃圾桶 |
| `mo clean --dry-run` / `-n` | 系統清理：掃描預覽 | 原生啟動＋官方文字結果 | `.dryRun`。沒有官方結構化刪除計畫，不能把文字轉成可承諾的項目勾選 |
| `mo clean --external PATH` | 選擇外接磁碟後預覽／清理 | 原生資料夾選擇＋官方驗證 | `.externalVolume`；只接受 `/Volumes/` 下的絕對路徑；實際磁碟資格與保護交由 Mole |
| `mo clean --whitelist` | 系統清理／設定：白名單 | 官方 PTY 編輯器 | `.whitelist`；不改寫另一套保護設定；不可與 dry-run 混用冒充預覽 |
| `mo uninstall --list` | 解除安裝：重新掃描 App | 原生清單／圖示／搜尋 | `.uninstallList`、`MoleJSON.decodeApps`。stdout 使用管線時官方自動輸出 JSON；**不傳不存在的 `--json` 參數** |
| `mo uninstall [APP_NAME ...]` | 選取 App 後移除 | 原生選取＋官方 PTY 最終確認 | `.apps`、`InstalledAppSelection.validatedNames`。只允許唯一 exact-name 對應；重複名稱、Cask 別名或模糊比對改用官方選取器 |
| `mo uninstall` | 官方 App 選取器 | 官方 PTY | 無名稱參數。保留完整官方選單、資料檔案 `D` 檢查及確認 |
| `mo uninstall --dry-run` / `-n` | 預覽卸載計畫 | 官方文字／必要時 PTY | `.dryRun`。有名稱時使用管線讀取正式預覽，不靠文字解析決定下一次刪除 |
| `mo uninstall --with-data` | 包含個人資料開關，預設關閉 | 原生開關＋官方資料審查 | `.withData`。實際資料路徑仍需官方最後畫面確認 |
| `mo uninstall --permanent` | 永久刪除開關，預設關閉 | 原生開關＋加強警示 | `.permanent`；開啟後不經垃圾桶 |
| `mo optimize` | 系統最佳化：執行 | 原生啟動＋官方 PTY 結果 | `.optimize`；不加入官方未提供的調校；各工作狀態以官方輸出為準 |
| `mo optimize --dry-run` | 最佳化預覽 | 官方文字結果 | `.dryRun`。沒有公開的結構化工作結果 API，MoPanel 不假造每項狀態 |
| `mo optimize --whitelist` | 最佳化／設定：保護項目 | 官方 PTY 編輯器 | `.whitelist` |
| `mo analyze [PATH] --json` | 磁碟分析：總覽、選擇資料夾、逐層進入 | 原生 JSON | `.json`、`.analyzePath`、`MoleJSON.decodeAnalyze`。所有 flags 排在 PATH 之前以符合 Go flag parser |
| `mo analyze [PATH]` | 在官方分析器檢查／移至垃圾桶 | 官方 PTY | `.analyze`。這個 TUI 有檔案操作能力，按破壞性入口處理；不繞過官方刪除保護 |
| `mo purge` | 專案清理：掃描／選擇／執行 | 官方 PTY | `.purge`；由原版判定可重建資料、近期活動、Git 與敏感資料保護 |
| `mo purge --dry-run` / `-n` | 專案清理預覽 | 官方 PTY | `.dryRun`；不另行遞迴掃描整台電腦 |
| `mo purge --paths` | 編輯專案掃描範圍、資料夾選擇器 | 官方設定流程＋原生編輯器 | `.purgePaths`。**這個參數不是接受 PATH 的命令列參數**；透過官方支援的 `EDITOR` 開啟 MoPanelEditor，儲存後交回 CLI 重新載入 |
| `mo purge --include-empty` | 顯示零容量產物 | 原生開關＋官方 PTY | `.includeEmpty` |
| `mo purge --yes` | 進階：同意清理符合條件的產物 | 原生明確選項＋風險確認 | `.yes`。預設不傳；與預覽分離，不能作為隱藏自動同意 |
| `mo installer` | 安裝檔：掃描／選取／清理 | 官方 PTY | `.installer`；由官方分類 DMG、PKG、ISO、XIP 與符合條件的 ZIP |
| `mo installer --dry-run` / `-n` | 安裝檔預覽 | 官方 PTY／文字 | `.dryRun`；官方沒有 JSON 清單 API；不重建另一套安裝檔辨識器 |
| `mo slim` | App 瘦身：選取／執行 | 官方 PTY | `.slim`；官方在副本上操作、驗證簽章與 Gatekeeper，再移換符合條件的 App |
| `mo slim --dry-run` / `-n` | 瘦身候選與節省空間預覽 | 官方 PTY／文字 | `.dryRun`；略過原因可搭配 `--debug`，不自行修改 App bundle |
| `mo history` | 歷史：原始輸出 | 官方文字 | `.history` |
| `mo history --json` | 原生歷史清單與搜尋 | 原生 JSON | `.json`、`MoleJSON.decodeHistory`；保留 `run`／`command`／`ambiguous` 歸屬和未結束作業 |
| `mo history --limit N` | 歷史筆數 | 原生控制項 | `.historyLimit`，1–200 |
| `mo --version` / `-V` / `version` | 設定：CLI 版本與來源 | 原生顯示＋完整原始輸出 | `.version`、Probe；取得整份輸出以辨認 Nightly 與 Homebrew HEAD |
| `mo --help` / `-h` / `help` | 設定：官方說明 | 原生文字 | `.help`；其他命令的 `--help` 也有操作入口 |
| `mo update` | 設定：更新官方穩定版 | 官方 PTY | `.update`；完成後重做版本與 help 檢查；GUI 與引擎分開更新 |
| `mo update --force` / `-f` | 設定：強制重新安裝 | 原生明確選項＋官方 PTY | `.force`；不暗中傳入 |
| `mo update --nightly` | 設定：Nightly | 官方 PTY，來源受限 | `.nightly`；只有已確認的官方腳本安裝來源才開放；更新後清理等變更停用，符合已知介面的腳本安裝可用不含 `--nightly` 的更新按鈕返回 stable |
| `mo touchid` | 設定：Touch ID 選單 | 官方 PTY | `.touchid`；管理員密碼不由 GUI 儲存 |
| `mo touchid status` | 設定：查看 Touch ID 狀態 | 官方文字 | `.touchID(.status)`，唯讀 |
| `mo touchid enable` / `disable` | 設定：啟用／停用 | 原生按鈕＋官方授權／PTY | `.touchID`，會修改 sudo 驗證設定，需確認 |
| `mo touchid --dry-run` / `-n` | Touch ID 變更預覽 | 官方文字／PTY | `.dryRun`，可搭配明確子命令 |
| `mo completion` | 設定：安裝 Shell 補全 | 官方 PTY | `.completion`；可能修改 shell 啟動設定，需確認 |
| `mo completion --dry-run` / `-n` | 補全設定預覽 | 官方文字 | `.dryRun` |
| `mo completion bash` / `zsh` / `fish` | 設定：顯示補全腳本 | 原生文字結果 | `.completionShell`；只取得腳本內容，**不 eval、不 source** |
| `mo remove` | 進階設定：移除 CLI | 官方 PTY＋額外輸入 `REMOVE` | `.remove`；明確說明 GUI 引擎依賴會消失；GUI 本身保留 |
| `mo remove --dry-run` / `-n` | 進階設定：移除預覽 | 官方文字 | `.dryRun` |
| `--debug` | 支援頁面的詳細輸出開關 | 原生控制項＋官方輸出 | `.debug`。這是 `mole` 頂層解析器支援的全域旗標 |
| `--help` / `-h` | 每個功能的官方說明 | 原生文字 | `.help` option；不與實際操作參數混用 |
| `optimise`、`analyse` | 對應既有「最佳化」與「分析」頁 | 相同 GUI 功能 | 官方拼字別名，不另建重複功能；GUI 呼叫 canonical `optimize`、`analyze` |

## 明確不提供的假介面

- V1.62.0 的 `clean` 明確拒絕 `--select`、`--categories`、`--exclude`。MoPanel 不建立假的逐項刪除承諾，改用原版白名單及完整預覽。
- `uninstall --whitelist` 官方明確不支援。保護清單只放在 Clean 與 Optimize。
- Clean、Optimize、Purge、Installer、Slim 沒有可供 GUI 任意提交刪除計畫的公開 JSON API。MoPanel 保留原版 TUI／文字，沒有使用猜測的列號，也沒有對顯示的路徑直接呼叫 `rm`。
- 在原生分析清單按「官方分析器」會打開指定範圍，檔案選取與刪除仍由官方介面完成；不聲稱原生清單勾選就是 Mole 已確認的計畫。
- CLI 未輸出的數值、跳過原因或歷史細節不會補成假數值。歷史中 `command` 歸屬不是唯一執行識別；未結束及 `ambiguous` 紀錄不能宣稱完整成功。
- Shell 的環境變數、測試開關與內部函式不是穩定 GUI API。MoPanel 不暴露任意 Shell 指令／環境注入入口。

## 更新與相容性邊界

1. 啟動時執行實際 `--version`、頂層 `--help` 及各命令 `--help`，查核必要 flags。
2. 維持官方 CLI 獨立安裝，GUI 不修改其核心原始碼，不內嵌固定 Mole 引擎。
3. 同一 major 的新穩定版可重新協商公開介面；這表示「接口仍符合」，不等同新版本的每個實作均經過完整安全審查。
4. JSON 每次都嚴格解碼。未知掃描狀態、缺必要欄位、截斷資料與不合理路徑會使相關結果失敗；受影響的破壞性入口暫停。
5. Nightly／dev／HEAD、新 major、舊於基準版本預設禁止破壞性操作。窄限例外是已確認官方腳本來源、同 major 且數字版本不舊於基準、update help 合約完整時，允許原版 `mo update`（無 `--nightly`）返回穩定版；其餘變更仍封鎖。Homebrew HEAD 的 updater 保留原安裝選項，不偽裝成可切 stable。沒有通用「忽略」開關。
6. 更新、移除或檔案指紋改變後重新偵測；正式執行前再次驗證 CLI 身分。

## 官方來源

- [V1.62.0 路由與版本](https://github.com/tw93/Mole/blob/V1.62.0/mole)
- [指令目錄](https://github.com/tw93/Mole/blob/V1.62.0/lib/core/commands.sh)
- [Clean／Uninstall／Optimize／Installer／Touch ID help](https://github.com/tw93/Mole/blob/V1.62.0/lib/core/help.sh)
- [Status 旗標](https://github.com/tw93/Mole/blob/V1.62.0/cmd/status/main.go) 與 [JSON 欄位](https://github.com/tw93/Mole/blob/V1.62.0/cmd/status/metrics.go)
- [Analyze JSON](https://github.com/tw93/Mole/blob/V1.62.0/cmd/analyze/json.go)
- [Uninstall 清單及名稱比對](https://github.com/tw93/Mole/blob/V1.62.0/bin/uninstall.sh)
- [History JSON](https://github.com/tw93/Mole/blob/V1.62.0/lib/core/history.sh)
- [Purge](https://github.com/tw93/Mole/blob/V1.62.0/bin/purge.sh)、[Installer](https://github.com/tw93/Mole/blob/V1.62.0/bin/installer.sh)、[Slim](https://github.com/tw93/Mole/blob/V1.62.0/bin/slim.sh)、[Completion](https://github.com/tw93/Mole/blob/V1.62.0/bin/completion.sh)
