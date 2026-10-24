# MoPanel 自行實作的部分

更新日期：2026-10-24。這份文件回應「自己新增的功能要告訴我」。**來源實作、測試通過與產品驗收完成是不同狀態**；實際證據見 `TEST_REPORT.md`，官方 GUI 差異見 `docs/GUI_PARITY.md`。

以下保留歷史驗證紀錄，**不是目前版的最新驗收結論；本版結果以 `TEST_REPORT.md` 與發行包 `Reports/` 為準**。[Mac CI run 40077546222](https://github.com/steven87090799/MoPanel-macOS/actions/runs/40077546222)（commit `e4181f754ce4a9bdc3b28efc60d2100d49403ba8`）實證 **140／140 XCTest 通過**（116 Core、24 Process／Editor／Streaming，0 失敗、0 略過），並完成 ARM64 release 編譯與 ad-hoc bundle 完整性驗證。正式 App 已正常建立視窗、截圖與 smoke JSON，未再出現初始 SIGSEGV 或 Publishing changes 警告；**20 項 smoke 檢查中 19 項通過**。該歷史 run 的唯一失敗為 AX 首個 snapshot 控制查找，最大 169 節點、0 個識別碼、0 次按鈕動作；該次整體 UI gate 失敗，當時後續效能、Guardian 驗收與 ZIP 發行被阻擋，不能用來判定本版發布結果。該 run 所測的新增模組單元測試已包含在 140 中，不能把內部測項或 19／20 smoke 再加總為新的 XCTest 數量。

該歷史 run 已測的原生範圍是 IOPM assertion 建立／讀回／釋放、遮罩視窗建立／關閉但不呈現、Doctor 18 項中繼資料，以及 Startup 私有 mock 的啟用／停用讀回、取消和未知格式拒絕。該 run 的 CLI 資料頁及 watch 使用 bundled fixture；當時 13 個路由的選取只證明過程中視窗仍存活，並不證明所有頁面與按鈕已完整驗收。沒有真實清理、App 更新、launchctl 變更、磁碟退出或硬體控制。

## 責任界線

MoPanel 是非官方原生 GUI。官方 Mole CLI 仍負責其清理、卸載、最佳化、專案清理、安裝檔處理與瘦身核心。MoPanel 不修改已安裝 CLI，不從 GUI checkbox 猜測終端選取編號，不重新推論 App 殘留所有權，也不把缺少的監測值補成假數字。

官方 Mole for Mac 是另一個閉源產品，CLI 與 GUI 能力不同：[官方說明](https://mole.fit/docs)、[官方 README](https://github.com/tw93/Mole/blob/main/README_TW.md)。對其功能進行獨立實作，不代表取得或沿用其私有程式碼。

## 已寫入程式碼的 MoPanel 實作

| 部分 | 使用者得到什麼 | 執行責任／程式碼 | 限制與驗證界線 |
|---|---|---|---|
| 原生導覽與偏好 | 十個主要 CLI 功能頁及四個新增頁、繁中／英文、系統／淺／深色、快捷鍵、原生 Liquid Glass | `Sources/MoPanelApp/` | 自有 UI；歷史 run 的 13 個路由不包含新增 Git 頁。新版本路由及 AX 按鈕結果須看本版 TEST_REPORT／Reports；VoiceOver、Retina、全按鈕仍須完整驗收 |
| 原生資料頁 | Status 圖表、App 清單、Analyze 層級圖、History 搜尋與內容 | `DashboardView.swift`、`UninstallView.swift`、`AnalyzeView.swift`、`HistoryView.swift` | 正式使用時資料來自官方 CLI；該歷史 run smoke 的 bundled fixture 解碼、watch 接收與切頁停止已通過，不冒充真硬體 benchmark。圖表不是新掃描引擎，某些操作仍進官方 PTY |
| CLI 探索 | Homebrew／官方腳本／PATH／自訂路徑、symlink 與實際資源位置判斷 | `MoleDiscovery.swift`、`CLIProbe.swift` | 明確自訂路徑失敗不回退；自動探索逐一檢查候選。資源／身分／契約無法確認時封鎖相關變更；可信自訂官方 checkout 可分類為 custom，來源分類不等於密碼學發行認證 |
| 相容層 | 版本、正式 help 契約、JSON 型別、未知掃描狀態檢查；更新後重新探測 | `Compatibility.swift`、`MoleCommand.swift`、`MoleModels.swift` | 是介面相容性檢查，不是對所有未來 CLI 核心行為的保證 |
| Nightly／dev 復原入口 | 合條件的官方腳本安裝可以確認後回到 stable | `Compatibility.swift`、`SettingsView.swift` | 實際更新仍由官方 `mo update`；不將 Homebrew HEAD 冒充可直接切 stable，不寫自己的更新引擎 |
| 破壞性操作確認 | 執行前說明範圍、永久刪除／垃圾桶影響、保留官方二次確認 | `AppModel.swift`、`ContentView.swift` | 不代替官方路徑驗證；取消不能復原已經刪除的資料 |
| 內嵌互動終端 | 使用按鈕與鍵盤操作官方 TUI；不必自行組 shell 指令 | `Sources/MoPanelTerminal/TerminalPanel.swift` | 使用 MIT 授權 SwiftTerm 1.20.0。它是正式備援操作介面，不宣稱原生逐項計畫已完成 |
| 程序執行與輸出限制 | 安全 argv、受控環境變數、逾時、非零退出、bounded output、單一 Watch | `Sources/MoPanelProcess/ManagedProcess.swift` | 不使用 shell 拼接使用者參數；不記錄輸入。互動輸出是否 echo 由終端／CLI 控制，密碼遵循原 sudo 的無 echo 流程 |
| 程序生命週期 guardian | GUI 消失後處理其所啟動程序；正常取消與逾時有訊號策略 | `Sources/MoPanelGuardian/main.c` | 非 root、非常駐安裝服務。Slim 實際替換階段採合作式取消，不保證兩秒強殺；可能等官方安全邊界後退出 |
| Purge 原生路徑編輯器 | 加入資料夾、編輯／儲存／取消，不必操作 vim | `Sources/MoPanelEditor/main.swift`、`PurgePathsDocument.swift` | 透過官方 `EDITOR` 擴充點。限制正式使用者設定檔、擋 symlink、容量上限、檢查外部修改；不是修改掃描引擎 |
| 操作紀錄與匯出 | 查看入口與結果；非互動輸出可匯出，互動作業只匯出執行摘要 | `OperationExport.swift`、`AppModel.swift`、`SettingsView.swift` | 不記錄鍵盤／密碼輸入，不保留完整 PTY 逐字日誌。互動內容只在終端有限回捲；Mole 自己的可用歷史另列。含路徑的非互動輸出由使用者決定是否匯出 |
| 權限與安裝引導 | 缺 CLI、無 FDA、來源不明、相容性錯誤、官方安裝及更新入口 | `SettingsView.swift`、`CLIProbe.swift` | 不代替系統授權，不偷偷下載執行腳本，不停用 Gatekeeper |
| Keep Awake | 原生顯示／系統閒置喚醒、可選時限、低電量暫停、接電續行、停止／睡眠／退出釋放 | `SystemToolsController.swift`、`SystemToolsPolicy.swift` | **MoPanel 新實作**，使用 IOPMAssertion；7 個政策測試及真實 system-idle assertion 建立、讀回、釋放與確認不存在已通過。定時、低電量／接電、睡眠等完整情境未驗收；不保證關蓋、不跨重啟恢復、不改 pmset |
| Clean Screen | 原生多螢幕純色遮罩、Esc／按鈕／切換 App／5分鐘保底退出 | `SystemToolsController.swift`、`SystemToolsView.swift` | **MoPanel 新實作**；該歷史 run 1 個螢幕的遮罩視窗建立並關閉，未呈現、未攔截輸入。沒有全域輸入鎖、不需輔助使用授權；實際顯示、事件與多螢幕仍待驗收 |
| 外接磁碟退出 | 讀掛載中繼資料、保護根／內建／家目錄／App 所在磁碟、確認後交給 NSWorkspace | `SystemToolsController.swift`、`SystemToolsPolicy.swift` | **MoPanel 新實作**，無強制退出；純政策已測，CI 不退出任何真實 volume |
| Doctor 唯讀報告 | 明確來源的 OS／硬體／電源／顯示器／磁碟中繼資料，可複製或儲存 | `SystemToolsController.swift`、`SystemToolsView.swift` | **MoPanel 新實作**；該歷史 run 實際讀到 18 項中繼資料，複製／儲存按鈕仍待驗收。不掃描目錄內容、不探測私人檔案，不知道的 FDA／安全狀態明示未檢查，非官方完整 Doctor |
| App Updates | Homebrew 結構化版本、官方預覽、逐項確認、計畫重驗及結果；其他 App 來源辨識與 handoff | `AppUpdatesController.swift`、`AppUpdatesView.swift`、`AppUpdateModels.swift` | **MoPanel 新實作**；直接更新僅符合安全條件的一般官方 cask。30 個 Core 與 2 個環境測試已在 Mac 通過，沒有真實 App 升級驗收。Sparkle／App Store 不代管下載安裝；詳見 APP_UPDATES.md |
| Startup | 有界 plist 清單、搜尋、來源、實際狀態、受保護 user LaunchAgent 預覽與確認 | `StartupController.swift`、`StartupView.swift`、`StartupModels.swift` | **MoPanel 新實作**；15 項 Core 與 controller 私有 mock 的啟用／停用讀回、取消不變更及未知格式拒絕已通過。真 launchctl 變更／持續工作建立皆為 0，AX 按鈕尚待驗收；不刪 plist、不用 sudo、不讀私有 BTM DB，其他項目交由系統設定 |
| Git 工作目錄與保留分支重建 | 只檢查選定倉庫、逐項保護理由、確認前重驗、保留 HEAD 分支、官方 Git 移除與新位置重建 | `GitWorktreeController.swift`、`GitWorktreeView.swift`、`GitWorktreeService.swift`、`GitWorktreeModels.swift` | **MoPanel 新實作**；真 Git 拋棄式倉庫測試使用合成提交與檔案，不碰個人倉庫。主工作目錄、dirty／untracked／ignored、鎖定、submodule、特殊設定及無法驗證狀態受保護。沒有 AI session／閒置判讀，保留分支不是獨立備份；Mac 驗收與精確案例見本版 TEST_REPORT 及 GIT_WORKTREES.md |
| 選單列監控 | 預設關閉；CPU／記憶體／健康／網速，與總覽共用同一個 watch，手動暫停與 App 退出停止 | `MenuBarPanel.swift`、`AppModel.swift`、`NativeControlPolicy.swift` | **MoPanel 新實作**；沒有另開監控程序、沒有 Login Item、沒有隱藏 Dock。Mac 實際結果以 Reports 為準 |
| 行程搜尋／排序／置頂及 App 結束要求 | 官方 top-process 樣本；確認前後核對 App 身分與樣本時效，AppKit 一般或強制結束 | `ProcessInspectorView.swift`、`NativeControlPolicy.swift` | **MoPanel 新實作**；7 項政策測試通過，不對未知 PID、系統 App 或背景程序傳送終止訊號。未實測結束真實使用者 App，非所有程序控制對等 |
| 測試與打包工具 | Mock CLI、schema fixtures、程序生命週期測試、ARM64 簽章／ZIP 驗證流程 | `Tests/`、`scripts/`、`.github/workflows/` | 僅測試模式使用合成資料；正式 UI 不以 fixture 當 fallback。成功必須由實際 run 證明 |

本表說「MoPanel 自行實作」是交代程式責任，不表示每項功能都超出原始要求；例如原生圖表、取消與權限引導本來就是使用者要求。

## 已納入新範圍，但目前尚未完成的額外模組

使用者已要求與官方付費 GUI 功能對齊，以下不再當作永久排除事項。它們在免費 CLI 中沒有完整等價入口；若新增，必須明示 **「MoPanel 新實作」** 或 **「MoPanel 透過其他官方工具整合」**，附上權限、資料來源、版本與測試範圍。

| 待補部分 | 責任歸屬及完成條件 |
|---|---|
| 跨來源第三方 App 更新 | MoPanel 新更新協調模組；不能用 `mo update` 代替。每種來源須有識別、驗證、取消與恢復測試 |
| Startup／背景項目管理 | MoPanel 原生系統整合；保護 Apple／企業管理項目，確認身分與可操作性 |
| AI session／閒置工具處理與 AI 專用 worktree 規則 | 通用 Git worktree 保護與分支重建已有獨立實作；對話索引、AI 工具所有權、閒置規則與 session 清理仍未完成，不能靠猜測 |
| Menu Bar、程序控制、Doctor 擴充 | MoPanel UI／診斷／系統整合；按需工作，程序操作要重新驗證身分。Doctor 基礎報告已有實作，官方完整條件集合仍未完成 |
| Keep Screen On／Clean Screen 的完整對等與隱私提醒 | Keep Awake、基本遮罩與裝置退出已新增；閉蓋、跨重啟恢復、全域輸入保護及隱私訊號仍未完成，不能把基礎版本稱為完全對等 |
| 風扇模式、Battery Care、AWDL | MoPanel 新硬體／系統控制，已在最新需求範圍內；需要受支援硬體、窄授權、狀態讀回與故障恢復，不放置假控制項 |
| Parallels 磁碟回收 | 透過 Parallels 官方工具整合；需要關機 VM、可辨識磁碟與不中斷保護 |

這些模組不能承諾只靠未來更新 Mole CLI 就自動獲得。Mole CLI 與 MoPanel 新增的原生／第三方整合各有自己的相容性與更新責任。

## 沒有做的事

目前沒有自建清理規則引擎、沒有用磁碟大就認定垃圾、沒有自動清空垃圾桶、沒有修改官方 Mole 已安裝原始碼、沒有建立預設 LaunchAgent／Login Item、沒有操作 BuhoCleaner 的設定或資料庫，也沒有複製官方付費 GUI 的私有程式碼、圖示或商標。

新增對等功能後，也必須維持來源透明：官方 CLI 的結果標示來自 Mole；原生系統 API 的結果標示來源；缺少支援就顯示不可用，不作估造。

