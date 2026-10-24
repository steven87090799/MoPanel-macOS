# 官方 Mole for Mac 功能對照與驗收缺口

查核日期：2026-10-24。這是**功能與驗收追蹤表，不是完成聲明**。

## 目前採用的範圍

使用者已選定「官方付費 GUI 全功能」。比較基準為 **Mole for Mac 1.17.0 正式版**；1.18.0 Preview 另列。原先排除風扇控制、電池充電限制、WiFi AWDL 調整的限制已撤回，這三項現在都是待完成與驗收的需求。

免費 CLI 基準仍為 **Mole V1.62.0**，固定 commit `91a7bf44f96995361b10b5a0e9efae36a1490bf9`。GUI 版本與 CLI 版本是不同產品的版本號，不能相互替代。

官方 [發行紀錄][S1] 將 v1.17.0 Vega 列於 2026-10-18，並將 v1.18.0 build 341 標成 Preview。官網頁尾可能直接顯示 Preview 版本，不能單憑頁尾判定正式版本。官方 [文件][S2] 也提醒有些內容只在 Preview 提供。

官方 [README_TW][C1] 將 Mole for Mac 說明為獨立閉源 App；[官方文件][S2] 明確表示 CLI 和 GUI 功能不完全相同。本專案沒有官方 GUI 私有原始碼，也沒有取得可重用全部付費功能的公開 GUI SDK。`michaelcspeed/mole-ui` 是第三方專案，不是官方 Mole for Mac。

## 判讀方式

- **原生／待驗收**：已有直接連到 CLI 資料或操作的原生介面，尚不等於已在真實 Mac 完成驗收。
- **PTY／待驗收**：操作透過內嵌官方互動介面完成；必須如實標示，不能算成完整原生選取體驗。
- **部分**：有共用基礎，但尚缺官方 GUI 的一部分行為或資料。
- **未實作**：本文件建立時沒有對應產品功能，不能以假按鈕、固定資料或開啟說明網頁充數。
- **Preview**：公開預覽差異；不納入 1.17 穩定對等率，也不宣稱已完成。

本表反映建立時的程式碼。新模組加入後，負責人必須更新其程式碼位置、實際測試證據與狀態。不可只把「未實作」改成「完成」而不附驗收結果。最終測試總結以根目錄 `TEST_REPORT.md` 與發行包 `Reports/` 的實際紀錄為準。

## 1.17 正式功能與 MoPanel 現況

以下是從官方公開資料可以確認的功能集合。分類名稱與行為摘要是對照用途，不複製官方介面素材。產品頁可能隨 Preview 更新；精細規則未能從正式發行紀錄確認時，另註「版本邊界待實機確認」，不把最新文案直接當成 1.17 的全部細節。

| ID | 官方功能／依據 | 免費 CLI 能力與邊界 | MoPanel 現況與程式碼 | 尚需完成或驗收 |
|---|---|---|---|---|
| C01 | 快取、日誌、系統及 App 清理，逐項審查 [S3] | `clean`、Dry Run、Whitelist；沒有公開的任意逐項 JSON 刪除計畫入口 | **PTY／待驗收**；`MaintenanceView.swift`、`AppModel.swift` | 原生項目級計畫尚缺；不得將文字輸出或 checkbox 假裝成官方可執行計畫 |
| C02 | 顯示項目路徑、容量、略過與保護，清理後實際結果 [S3] | CLI 文字及正式日誌，部分結果不是結構化資料 | **部分**；官方終端輸出與 `HistoryView.swift` | 原生分類明細、逐項理由及真實清理前後比對 |
| C03 | 快取永久刪除／垃圾桶偏好 [S3] | 各 CLI 命令刪除語義不同，不能用 GUI 任意改寫 | **部分**；已揭露不可逆風險，沒有完整全域改用垃圾桶功能 | 必須在不繞過官方保護的前提下取得可執行方案；未支援時明示 |
| C04 | System Data 分組、快照與較高影響工作分開審查 [S3] | CLI 有相關清理流程，選取粒度不同 | **PTY／待驗收** | 真實隔離 fixture 驗證各類操作及確認流程，不能只比總釋放空間 |
| C05 | 開發工具快取與產物審查 [S3] | `clean`／`purge`；CLI 的時限及選取規則不必然等於 GUI | **PTY／待驗收**；`MaintenanceView.swift` | 樣本專案的原始碼、Git、憑證保留與官方 GUI 規則差異 |
| A01 | AI 快取、舊工具版本整理 [S3] | CLI 已涵蓋多個 AI 工具的快取、舊版本 | **部分**；由 `clean` 執行，沒有獨立 AI 原生審查頁 | 工具覆蓋表與每類資料所有權驗證 |
| A02 | AI sessions、worktrees、閒置 AI CLI 的專用審查 [S1][S3] | CLI worktrees 是報告用途；Codex session/state 預設受保護 [C5][C6] | **未實作** | 需要新增工具整合、可恢復副本、索引一致性及 Git 唯一內容保護；不得直接刪目錄替代 |
| S01 | App 清單、圖示、大小、搜尋、多選卸載 [S4] | `uninstall --list`、名稱參數及官方選取器 | **原生＋PTY／待驗收**；`UninstallView.swift` | 重名 App、cask 名稱歧義、特殊檔名與實際確認範圍的端到端測試 |
| S02 | App 殘留、共享資料、個人資料與系統擴充的審查 [S4] | 官方卸載分析及確認；CLI 殘留計畫並非完整公開 JSON | **部分**；個人資料預選預設關閉，最終審查在 PTY | 原生逐項審查、共享資料安全、特殊卸載器 handoff；不能猜測所有權 |
| S03 | 跨來源 App 更新、重試與取消 [S4][S1] | `mo update` 只更新 Mole CLI，不會更新任意 App | **部分原生新實作＋Homebrew PTY／最新修復待 macOS CI**；`AppUpdatesController.swift`、`AppUpdatesView.swift` | 官方一般 cask 結構化查詢、預覽、確認、同計畫重驗與更新後檢查已寫；加入舊配方／收據／設定比對，不能只信任新版。Sparkle／App Store 只有來源辨識與原 App handoff。30個Core與2個環境測試在 Linux 通過；未升級真實 App，非所有來源完整對等 |
| S04 | Login Items、LaunchAgents、LaunchDaemons、背景項目管理 [S4] | CLI 卸載／最佳化有相關工作，沒有同等通用管理介面 | **部分原生新實作／最新修復待 macOS CI**；`StartupController.swift`、`StartupView.swift` | 已有有限中繼資料清單、可驗證 user LaunchAgent 啟用／停用與確認；未知身分禁止變更，其他項目使用正式系統設定入口。15個Core測試在 Linux 通過，涵蓋目錄URL回歸與真Mac唯讀launchctl樣本；CI用私有mock，不修改真launchd工作 |
| O01 | macOS 維護、任務結果與略過原因 [S5] | `optimize`、Dry Run、Whitelist；官方承認任務集合可能不同 [S2] | **PTY／待驗收**；`MaintenanceView.swift` | 逐項核對 1.17 GUI 任務；不能宣稱兩套預設維護流程完全相同 |
| O02 | 管理員授權重用及工作結束後停止 [S5] | 官方 CLI sudo／Touch ID 流程 | **PTY／待驗收**；`ManagedProcess.swift`、`TerminalPanel.swift` | 真 Mac sudo、Touch ID、取消及授權過期；不保存密碼 |
| D01 | 階層磁碟圖、搜尋、大小、Finder、重新掃描 [S6] | `analyze --json` | **原生／待驗收**；`AnalyzeView.swift` | 圖僅畫篩選後最大 30 個可測項目並明示；不等同官方全部細節、快取與視覺排列 |
| D02 | 不完整掃描、不可讀資料、APFS 空間解釋 [S6] | `complete`／`partial`／`unavailable`；未必提供逐項原因 | **原生／待驗收**；`MoleModels.swift`、`AnalyzeView.swift` | 權限不足、TCC、外接磁碟、APFS clone／sparse 等真 Mac fixture |
| D03 | 安全移至垃圾桶與保護路徑 [S6] | 官方 `analyze` 互動操作 | **PTY／待驗收** | 原生圖表不直接刪除；需在官方介面重新選擇，不猜索引。這不是官方 GUI 的即點即移體驗 |
| M01 | 健康、CPU／每核、GPU、記憶體、Swap、磁碟、網路與趨勢 [S7] | `status --json --watch` | **原生／待驗收**；`DashboardView.swift`、`AppModel.swift` | 真實指標、單一 watch、前景／頁面切換生命週期與三種效能量測 |
| M02 | 溫度、功耗、風扇轉速、本機及配件電池 [S7][S8] | CLI 本來就有 `thermal`、`sensors`、`batteries`、`bluetooth` [C3][C4] | **部分**；顯示 CLI 有提供的數值 | 未提供訊號不能估造；配對 iPhone／iPad、頻率、個別程序能耗等不等於目前 CLI 資料 |
| M03 | 程序搜尋、排序、固定、說明、退出／強制退出 [S7] | CLI 有程序樣本、watch、alerts，非完整 GUI 控制介面 | **部分原生新實作／待 macOS CI**；`ProcessInspectorView.swift`、`NativeControlPolicy.swift` | 已有搜尋、排序、置頂、精確 App 身分重驗與 AppKit 結束／強制結束；只使用官方有限樣本，不終止任意背景／系統程序，沒有用途說明庫。7項政策測試包含身分重用與過期樣本，未結束使用者 App |
| B01 | 選單列監測、可選指標、網速、隱藏 Dock、啟動偏好 [S7] | 無 CLI UI | **部分原生新實作／待 macOS CI**；`MenuBarPanel.swift`、`AppModel.swift` | 預設關閉、啟用後共用單一 watch，CPU／記憶體／健康／網速、暫停與關閉生命週期已有程式；沒有隱藏 Dock／登入啟動與官方全部自選指標 |
| B02 | Keep Screen On、定時與停止 [S9] | 無對等 Mole CLI 命令 | **原生新實作／待 macOS CI**；`SystemToolsController.swift`、`SystemToolsView.swift`、`SystemToolsPolicy.swift` | 已寫顯示／系統閒置模式、1/2/4/8/12h/直到停止、低電量暫停與接電續行、睡眠／退出釋放。沒有閉蓋保證或跨重啟恢復；仍非完整對等 |
| B03 | Clean Screen 與可選輸入保護 [S7] | 無對等 Mole CLI 命令 | **部分原生新實作／待 macOS CI**；`SystemToolsController.swift` | 已寫多螢幕遮罩、Esc／按鈕／切換 App／5分鐘退出。沒有全域輸入鎖，也不暴露假權限按鈕；多螢幕與事件仍需真 Mac 驗收 |
| B04 | 攝影機／麥克風狀態、通知 [S7] | 無對等 Mole CLI 命令 | **未實作** | 可取得訊號的真實性、通知權限；不得猜測 macOS 不提供的擁有者 |
| B05 | 退出外接磁碟／磁碟映像 [S7] | 分析路徑支援不等於退出功能 | **原生新實作／待 macOS CI**；`SystemToolsController.swift` | 只列正向確認的外接可退出 volume、重新核對身分、NSWorkspace 非強制退出及掛載結果檢查；測試未退出真實磁碟，需隔離裝置／DMG 驗收 |
| H01 | 風扇 Auto／Cool／Max [S10] | CLI 讀值不等於風扇控制 | **未實作；現在範圍內** | 支援硬體偵測、窄授權、模式讀回、退出／崩潰後回復；無風扇機型不可顯示可用控制 |
| H02 | Battery Care 充電限制 [S2] | 無 CLI 控制入口 | **未實作；現在範圍內** | 內建電池支援判斷、充放電邊界、授權、退出／重新開機／睡眠恢復 |
| H03 | WiFi Low Latency／AWDL 暫停與恢復 [S11] | 無 CLI 控制入口 | **未實作；現在範圍內** | 原狀保存、AirDrop 等影響提示、網路變動／睡眠／退出／失敗重試，不聲稱保證加速 |
| V01 | 關機 Parallels VM 未用磁碟空間回收 [S3][S1] | 無等價正式命令 | **未實作** | 使用 Parallels 官方工具、驗證 VM 狀態與磁碟身分、不可中斷階段及真實回收量 |
| X01 | Doctor、操作紀錄、權限及問題引導 [S2] | CLI `history --json`；GUI 狀態診斷需自建 | **部分新實作／待 macOS CI**；`HistoryView.swift`、`CLIProbe.swift`、`SystemToolsController.swift` | Doctor 只讀實際系統／電源／顯示器／磁碟中繼資料，可複製／匯出；FDA／安全設定未檢查就明示。不是官方完整診斷條件集合 |
| X02 | 原生外觀、語言、深淺模式、快捷鍵、VoiceOver [S1][S8] | 無 CLI UI | **部分／待驗收**；原生 SwiftUI、繁中／英文、Liquid Glass | 全頁鍵盤與 VoiceOver 仍需逐項實測。僅支援本任務指定兩種語言，不宣稱官方全部語系 |

### CLI 特有入口依然保留

`purge`、`installer`、`slim`、`history`、`touchid`、`completion`、CLI 自身 `update`／`remove` 與其他正式參數仍屬原始任務範圍。官方 GUI 可能把部分能力整合進 Clean 或其他頁面，不能因沒有同名頁面就說官方完全沒有該類功能。完整逐指令表見根目錄 `CLI_COVERAGE.md`。

## 1.18 Preview：另列，不混入正式完成度

官方發行頁目前將以下改進放在 Preview 章節 [S1]：

| 領域 | 公開預覽差異摘要 | 本專案狀態 |
|---|---|---|
| Clean／開發／AI | 新增部分工具殘留與審查類別，調整部分年齡門檻及保留條件 | 未宣稱已對等；需逐規則核對 release 後的正式界線 |
| Software | 更新辨識、來源與執行改進；App 資料清除等細部能力 | Homebrew 受限更新與來源 handoff 已實作，完整來源及 Preview 細部行為尚未對等；不能從最新 Docs 推定 1.17 全部具備 |
| Analyze | 對比前一天的容量成長並指出變大的項目 | 未實作 |
| 監測／介面 | 指標、配件通知、互動與可讀性改進 | 未進行與 Preview 的實機對照 |

精細節點請直接核對官方發行紀錄，不在此複製整份 changelog。未來正式版發布後，應重新確定比較基準與驗收資料。

## 測試矩陣與完成門檻

**目前沒有可以誠實標成 100% 官方 GUI 功能對等的結果。** 既有 Core、Process、Guardian 測試驗證的是我們的介面契約與安全層，不是官方 GUI 全套行為。公開 macOS CI 的編譯、簽章與 UI 結果須依該版 `TEST_REPORT.md`／Reports 判斷。新增 System Tools 的 7 個純政策測試已在 Swift 6.4.1 Linux 實際通過（0 失敗，`docs/SYSTEM_TOOLS_POLICY_TEST_OUTPUT.txt`）；這不是 IOKit／AppKit 驗收。

| 驗收層 | 必須證明的內容 | 此文件建立時的證據／缺口 |
|---|---|---|
| 官方資料盤點 | 1.17 穩定、1.18 Preview、CLI V1.62.0 分開 | 公開文件及固定 CLI 原始碼已盤點；官方 GUI 未作二進位實測 |
| CLI Adapter | argv、身分、來源、版本、help、JSON／NDJSON | 已有實際 XCTest；總數及最新 log 見 TEST_REPORT |
| 子程序安全 | PTY、無密碼紀錄、取消、逾時、父程序消失 | Linux fixtures 已測；macOS libproc、App 強制退出、sudo 需各自證據 |
| 原生 App 建置 | macOS 27 ARM64 SwiftUI／AppKit／Charts／SwiftTerm | 最新公開 CI 已編譯新增模組的 debug App；該次 XCTest 仍有失敗，後續修復必須重新取得完整 release／smoke／封裝證據 |
| App 包裝 | Mach-O ARM64、helper、codesign、ZIP 解壓再驗證 | 必須由成功 CI 產物證明，不由來源樹推定 |
| UI 流程 | 所有真按鈕、返回、空白／失敗／取消、鍵盤、VoiceOver | 尚未全量完成；Smoke test 不等於完整人工流程驗收 |
| 清理／卸載 | 同隔離資料集的預覽、確認、實際結果與保護 | 不對使用者個人資料測試；尚須可丟棄 VM／獨立測試帳號完整流程 |
| 原生新增模組 | 每項功能行為、失敗恢復與來源安全 | System Tools 已有 7 項政策測試及安全 Mac smoke 入口；其他未實作項仍保留，沒有以開網頁算完成 |
| 權限 | 無 FDA、拒絕 sudo、Touch ID、通知、輔助使用權限 | 需真 Mac 環境逐情境執行，CI mock 不能取代系統權限驗收 |
| 硬體控制 | 支援／不支援機型、讀回、睡眠／崩潰恢復 | 尚未實作及實機驗收；不能用虛擬 runner 聲稱物理風扇／充電已驗證 |
| 更新來源 | Sparkle、App Store、Homebrew、其他可支援來源 | 已有受限 Homebrew 更新與來源 handoff、Core／程序測試及真 Mac Homebrew 唯讀契約；未執行真 App 更新，Sparkle／App Store 不代管安裝，不能算跨來源全面驗收 |
| 資源 | 閒置、監控、掃描的 CPU、RSS、背景退出 | 需真 Mac 三狀態量測與執行條件；不填假數值 |
| 功能等同性 | 針對每個 ID，比較相同輸入、設定與結果 | 尚未完成；沒有官方 GUI 原始碼／公開規格的細節必須保留不確定性 |

安全條件仍有效：GUI 不以 root 執行、不關閉 Gatekeeper／SIP、不存管理員密碼、不對真實個人資料做破壞性測試、不修改 BuhoCleaner 的設定或資料庫。追加功能不能自動放寬這些限制。

### System Tools 安全驗證入口

`await SystemToolsController.runSafeSmokeTest()` 回傳 Codable 報告。它短暫建立一個最長 5 秒的 system-idle IOPM assertion，讀回後立即釋放，再確認該 ID 不存在；建立並關閉真實 AppKit 遮罩視窗，但不呈現、不啟用視窗、不攔截鍵盤或滑鼠。Doctor 僅讀中繼資料，不遍歷目錄內容。測試不呼叫退出磁碟 API，不取得管理員或輔助使用授權。

需要檢查 `assertionCreated`、`assertionReadableBeforeRelease`、`assertionReleaseCode`、`assertionAbsentAfterRelease`、overlay 數量與 `errors`；不能只看函式沒有 throw。`overlayWasPresented`、`inputWasIntercepted`、`ejectWasCalled` 必須為 false。這證明 API 生命週期基礎，不代表實際閉蓋、低電量、全螢幕操作及實體裝置退出已測過。

實作依據是 Apple 正式 [IOPM assertion API](https://developer.apple.com/documentation/iokit/1557078-iopmassertioncreatewithdescripti)、[IOKit 公開 header](https://github.com/apple-oss-distributions/IOKitUser/blob/main/pwr_mgt.subproj/IOPMLib.h)、[IOPowerSources](https://github.com/apple-oss-distributions/IOKitUser/blob/main/ps.subproj/IOPowerSources.h)、[NSWorkspace 退出 API](https://developer.apple.com/documentation/appkit/nsworkspace/unmountandejectdevice(at:)) 及 [NSScreen](https://developer.apple.com/documentation/appkit/nsscreen/screens)。公開 idle assertions 不保證阻止關蓋或使用者要求的睡眠；MoPanel 不改寫 pmset。

## 官方來源

查核時只使用官方公開來源判斷官方產品，不使用第三方 GUI 當作付費版功能規格。付費 App 的公開行為可作為獨立實作參考；不宣稱可取得或可複製其私有程式碼、商標、圖示與素材。

[S1]: https://mole.fit/releases
[S2]: https://mole.fit/docs
[S3]: https://mole.fit/mac-cleaner
[S4]: https://mole.fit/mac-app-uninstaller
[S5]: https://mole.fit/mac-optimizer
[S6]: https://mole.fit/mac-disk-analyzer
[S7]: https://mole.fit/mac-system-monitor
[S8]: https://mole.fit/
[S9]: https://mole.fit/blog/keep-mac-screen-on-without-draining-battery
[S10]: https://mole.fit/tw/blog/apple-silicon-thermal-throttling-mac-fan
[S11]: https://mole.fit/blog/mac-wifi-stutter-awdl
[C1]: https://github.com/tw93/Mole/blob/main/README_TW.md
[C3]: https://github.com/tw93/Mole/blob/V1.62.0/cmd/status/metrics.go
[C4]: https://github.com/tw93/Mole/blob/V1.62.0/cmd/status/metrics_bluetooth.go
[C5]: https://github.com/tw93/Mole/blob/V1.62.0/lib/clean/user.sh
[C6]: https://github.com/tw93/Mole/blob/V1.62.0/lib/clean/dev.sh

