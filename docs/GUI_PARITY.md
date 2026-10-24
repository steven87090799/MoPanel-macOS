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

最新實際證據是 [run 40077546222](https://github.com/steven87090799/MoPanel-macOS/actions/runs/40077546222)，commit `e4181f754ce4a9bdc3b28efc60d2100d49403ba8`：macOS 27.0.1／Xcode 27.1／Apple Swift 6.4 ARM64 的 **140／140 XCTest 通過**（116 Core、24 Process／Editor／Streaming，0 失敗、0 略過），主 App 與兩個 helper 的 release 編譯、ARM64 及 ad-hoc 完整性驗證也通過。先前的啟動 SIGSEGV 在本輪未再出現，也沒有 Publishing changes 警告；正式 App 產生視窗、截圖與 smoke JSON，**20 項 smoke 檢查中 19 項通過**，22.345 秒內以測試失敗狀態退出，並非逾時。

通過範圍包括真實 IOPM assertion 建立／讀回／釋放、AppKit 遮罩視窗建立／關閉（未呈現）、Doctor 18 項中繼資料、Startup 私有 mock 控制流程、bundled CLI fixture 的 status／apps／analyze／history 解碼及 watch 接收／切頁停止，以及選取 13 個路由後視窗仍存活。**路由選取不等於每頁完整渲染或按鈕驗收。** 唯一失敗是 AX 測試找不到 `mopanel.dashboard.snapshot` 控制項：觀察到最多 169 個節點、0 個識別碼、0 次按鈕動作，沒有直接呼叫 model 冒充按鈕成功。效能、後續 Guardian 驗收與 ZIP 發行仍被 UI gate 阻擋。140 個 XCTest 與 19／20 smoke 是不同層次的證據，不合併成新的測試總數，也不代表真實清理、App 更新或硬體控制已驗收。

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
| S03 | 跨來源 App 更新、重試與取消 [S4][S1] | `mo update` 只更新 Mole CLI，不會更新任意 App | **部分原生新實作＋Homebrew PTY／原生流程待驗收**；`AppUpdatesController.swift`、`AppUpdatesView.swift` | 官方一般 cask 結構化查詢、預覽、確認、同計畫重驗與更新後檢查已寫；加入舊配方／收據／設定比對，不能只信任新版。Sparkle／App Store 只有來源辨識與原 App handoff。30 個 Core 與 2 個環境測試已包含在通過的 Mac 140 案例中；未升級真實 App，非所有來源完整對等 |
| S04 | Login Items、LaunchAgents、LaunchDaemons、背景項目管理 [S4] | CLI 卸載／最佳化有相關工作，沒有同等通用管理介面 | **部分原生新實作／私有 mock smoke 通過**；`StartupController.swift`、`StartupView.swift` | 15 個 Core 測試及本輪 controller 私有 mock 的啟用／停用讀回、取消不變更、未知格式拒絕已通過；真 launchctl 變更與持續工作建立均為 0。未知身分禁止變更，其他項目使用系統設定；真實 launchd、AX 按鈕及完整背景項目管理仍待驗收 |
| O01 | macOS 維護、任務結果與略過原因 [S5] | `optimize`、Dry Run、Whitelist；官方承認任務集合可能不同 [S2] | **PTY／待驗收**；`MaintenanceView.swift` | 逐項核對 1.17 GUI 任務；不能宣稱兩套預設維護流程完全相同 |
| O02 | 管理員授權重用及工作結束後停止 [S5] | 官方 CLI sudo／Touch ID 流程 | **PTY／待驗收**；`ManagedProcess.swift`、`TerminalPanel.swift` | 真 Mac sudo、Touch ID、取消及授權過期；不保存密碼 |
| D01 | 階層磁碟圖、搜尋、大小、Finder、重新掃描 [S6] | `analyze --json` | **原生／待驗收**；`AnalyzeView.swift` | 圖僅畫篩選後最大 30 個可測項目並明示；不等同官方全部細節、快取與視覺排列 |
| D02 | 不完整掃描、不可讀資料、APFS 空間解釋 [S6] | `complete`／`partial`／`unavailable`；未必提供逐項原因 | **原生／待驗收**；`MoleModels.swift`、`AnalyzeView.swift` | 權限不足、TCC、外接磁碟、APFS clone／sparse 等真 Mac fixture |
| D03 | 安全移至垃圾桶與保護路徑 [S6] | 官方 `analyze` 互動操作 | **PTY／待驗收** | 原生圖表不直接刪除；需在官方介面重新選擇，不猜索引。這不是官方 GUI 的即點即移體驗 |
| M01 | 健康、CPU／每核、GPU、記憶體、Swap、磁碟、網路與趨勢 [S7] | `status --json --watch` | **原生／fixture 資料與 watch smoke 通過**；`DashboardView.swift`、`AppModel.swift` | 本輪 bundled fixture 的解碼、NDJSON 接收及切頁停止通過；真實硬體資料的 GUI benchmark、前景／選單列完整生命週期與三種效能量測仍待驗收 |
| M02 | 溫度、功耗、風扇轉速、本機及配件電池 [S7][S8] | CLI 本來就有 `thermal`、`sensors`、`batteries`、`bluetooth` [C3][C4] | **部分**；顯示 CLI 有提供的數值 | 未提供訊號不能估造；配對 iPhone／iPad、頻率、個別程序能耗等不等於目前 CLI 資料 |
| M03 | 程序搜尋、排序、固定、說明、退出／強制退出 [S7] | CLI 有程序樣本、watch、alerts，非完整 GUI 控制介面 | **部分原生新實作／操作流程待驗收**；`ProcessInspectorView.swift`、`NativeControlPolicy.swift` | 已有搜尋、排序、置頂、精確 App 身分重驗與 AppKit 結束／強制結束；只使用官方有限樣本，不終止任意背景／系統程序，沒有用途說明庫。7 項政策測試包含身分重用與過期樣本，未結束使用者 App |
| B01 | 選單列監測、可選指標、網速、隱藏 Dock、啟動偏好 [S7] | 無 CLI UI | **部分原生新實作／操作流程待驗收**；`MenuBarPanel.swift`、`AppModel.swift` | 預設關閉、啟用後共用單一 watch，CPU／記憶體／健康／網速、暫停與關閉生命週期已有程式；沒有隱藏 Dock／登入啟動與官方全部自選指標 |
| B02 | Keep Screen On、定時與停止 [S9] | 無對等 Mole CLI 命令 | **原生新實作／IOPM 生命週期 smoke 通過**；`SystemToolsController.swift`、`SystemToolsView.swift`、`SystemToolsPolicy.swift` | 本輪真實 system-idle assertion 建立、讀回、釋放及確認不存在通過。定時、低電量／接電與睡眠情境仍待驗收；沒有閉蓋保證或跨重啟恢復，非完整對等 |
| B03 | Clean Screen 與可選輸入保護 [S7] | 無對等 Mole CLI 命令 | **部分原生新實作／視窗建立關閉 smoke 通過**；`SystemToolsController.swift` | 本輪 1 個螢幕的遮罩視窗建立及關閉通過，未呈現遮罩、未攔截輸入。已寫 Esc／按鈕／切換 App／5 分鐘退出；實際呈現、事件及多螢幕仍待驗收，沒有全域輸入鎖 |
| B04 | 攝影機／麥克風狀態、通知 [S7] | 無對等 Mole CLI 命令 | **未實作** | 可取得訊號的真實性、通知權限；不得猜測 macOS 不提供的擁有者 |
| B05 | 退出外接磁碟／磁碟映像 [S7] | 分析路徑支援不等於退出功能 | **原生新實作／實際退出待驗收**；`SystemToolsController.swift` | 只列正向確認的外接可退出 volume、重新核對身分、NSWorkspace 非強制退出及掛載結果檢查；本輪 smoke 未呼叫退出 API，需隔離裝置／DMG 驗收 |
| H01 | 風扇 Auto／Cool／Max [S10] | CLI 讀值不等於風扇控制 | **未實作；現在範圍內** | 支援硬體偵測、窄授權、模式讀回、退出／崩潰後回復；無風扇機型不可顯示可用控制 |
| H02 | Battery Care 充電限制 [S2] | 無 CLI 控制入口 | **未實作；現在範圍內** | 內建電池支援判斷、充放電邊界、授權、退出／重新開機／睡眠恢復 |
| H03 | WiFi Low Latency／AWDL 暫停與恢復 [S11] | 無 CLI 控制入口 | **未實作；現在範圍內** | 原狀保存、AirDrop 等影響提示、網路變動／睡眠／退出／失敗重試，不聲稱保證加速 |
| V01 | 關機 Parallels VM 未用磁碟空間回收 [S3][S1] | 無等價正式命令 | **未實作** | 使用 Parallels 官方工具、驗證 VM 狀態與磁碟身分、不可中斷階段及真實回收量 |
| X01 | Doctor、操作紀錄、權限及問題引導 [S2] | CLI `history --json`；GUI 狀態診斷需自建 | **部分新實作／Doctor 中繼資料 smoke 通過**；`HistoryView.swift`、`CLIProbe.swift`、`SystemToolsController.swift` | 本輪 Doctor 讀到 18 項實際中繼資料；History fixture 解碼通過。複製／匯出與完整權限情境仍待驗收；FDA／安全設定未檢查就明示，不是官方完整診斷條件集合 |
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

**目前沒有可以誠實標成 100% 官方 GUI 功能對等的結果。** 既有 Core、Process、Guardian 測試驗證的是我們的介面契約與安全層，不是官方 GUI 全套行為。公開 macOS CI 的編譯、簽章與 UI 結果須依該版 `TEST_REPORT.md`／Reports 判斷。System Tools 的 7 個純政策測試包含在上述 Mac 140 案例中；本輪另取得真實 IOPM／AppKit 生命週期與 Doctor 的有限 smoke 證據，不能延伸為實體硬體或完整互動驗收。整體 UI smoke 仍因 AX 控制查找失敗而不通過。

| 驗收層 | 必須證明的內容 | 此文件建立時的證據／缺口 |
|---|---|---|
| 官方資料盤點 | 1.17 穩定、1.18 Preview、CLI V1.62.0 分開 | 公開文件及固定 CLI 原始碼已盤點；官方 GUI 未作二進位實測 |
| CLI Adapter | argv、身分、來源、版本、help、JSON／NDJSON | 已有實際 XCTest；總數及最新 log 見 TEST_REPORT |
| 子程序安全 | PTY、無密碼紀錄、取消、逾時、父程序消失 | Linux fixtures 已測；macOS libproc、App 強制退出、sudo 需各自證據 |
| 原生 App 建置 | macOS 27 ARM64 SwiftUI／AppKit／Charts／SwiftTerm | run 40077546222 的 release 編譯與 140／140 Mac XCTest 通過；App 啟動、視窗與 19／20 smoke 通過，未再出現初始崩潰或 Publishing changes 警告 |
| App 包裝 | Mach-O ARM64、helper、codesign、ZIP 解壓再驗證 | 本輪已驗證主程式與兩個 helper 的 ARM64 及 ad-hoc bundle 完整性；整體 UI gate 仍失敗，ZIP 封裝、解壓再驗證與發行尚未完成 |
| UI 流程 | 所有真按鈕、返回、空白／失敗／取消、鍵盤、VoiceOver | 13 個路由選取後視窗仍存活；AX 首個 snapshot 控制未找到，0 次按鈕動作。尚未證明全部頁面渲染、實際按鈕、鍵盤或 VoiceOver 流程 |
| 清理／卸載 | 同隔離資料集的預覽、確認、實際結果與保護 | 不對使用者個人資料測試；尚須可丟棄 VM／獨立測試帳號完整流程 |
| 原生新增模組 | 每項功能行為、失敗恢復與來源安全 | 真 IOPM assertion 建立／讀回／釋放、未呈現遮罩視窗建立／關閉、Doctor 18 項資料及 Startup 私有 mock 已通過；未呼叫退出磁碟 API、未修改真 launchd、未更新真 App，其他未實作項仍保留 |
| 權限 | 無 FDA、拒絕 sudo、Touch ID、通知、輔助使用權限 | 需真 Mac 環境逐情境執行，CI mock 不能取代系統權限驗收 |
| 硬體控制 | 支援／不支援機型、讀回、睡眠／崩潰恢復 | 尚未實作及實機驗收；不能用虛擬 runner 聲稱物理風扇／充電已驗證 |
| 更新來源 | Sparkle、App Store、Homebrew、其他可支援來源 | 已有受限 Homebrew 更新與來源 handoff、Core／程序測試及真 Mac Homebrew 唯讀契約；未執行真 App 更新，Sparkle／App Store 不代管安裝，不能算跨來源全面驗收 |
| 資源 | 閒置、監控、掃描的 CPU、RSS、背景退出 | 需真 Mac 三狀態量測與執行條件；不填假數值 |
| 功能等同性 | 針對每個 ID，比較相同輸入、設定與結果 | 尚未完成；沒有官方 GUI 原始碼／公開規格的細節必須保留不確定性 |

安全條件仍有效：GUI 不以 root 執行、不關閉 Gatekeeper／SIP、不存管理員密碼、不對真實個人資料做破壞性測試、不修改 BuhoCleaner 的設定或資料庫。追加功能不能自動放寬這些限制。

### System Tools 安全驗證入口

`await SystemToolsController.runSafeSmokeTest()` 回傳 Codable 報告。它短暫建立一個最長 5 秒的 system-idle IOPM assertion，讀回後立即釋放，再確認該 ID 不存在；建立並關閉真實 AppKit 遮罩視窗，但不呈現、不啟用視窗、不攔截鍵盤或滑鼠。Doctor 僅讀中繼資料，不遍歷目錄內容。測試不呼叫退出磁碟 API，不取得管理員或輔助使用授權。

run 40077546222 的實際報告中，上述 assertion 四項條件均通過、釋放回傳碼為 0；1 個螢幕對應的 1 個遮罩視窗建立並關閉，Doctor 回傳 18 項資料，`errors` 為空。`overlayWasPresented`、`inputWasIntercepted`、`ejectWasCalled` 均為 false。這是正式 App 的有限 API smoke 證據，不是可見遮罩互動、裝置退出或完整電源情境的驗收。

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

