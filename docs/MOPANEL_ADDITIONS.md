# MoPanel 自行實作的部分

更新日期：2026-10-24。這份文件回應「自己新增的功能要告訴我」。**來源實作、測試通過與產品驗收完成是不同狀態**；實際證據見 `TEST_REPORT.md`，官方 GUI 差異見 `docs/GUI_PARITY.md`。

## 責任界線

MoPanel 是非官方原生 GUI。官方 Mole CLI 仍負責其清理、卸載、最佳化、專案清理、安裝檔處理與瘦身核心。MoPanel 不修改已安裝 CLI，不從 GUI checkbox 猜測終端選取編號，不重新推論 App 殘留所有權，也不把缺少的監測值補成假數字。

官方 Mole for Mac 是另一個閉源產品，CLI 與 GUI 能力不同：[官方說明](https://mole.fit/docs)、[官方 README](https://github.com/tw93/Mole/blob/main/README_TW.md)。對其功能進行獨立實作，不代表取得或沿用其私有程式碼。

## 已寫入程式碼的 MoPanel 實作

| 部分 | 使用者得到什麼 | 執行責任／程式碼 | 限制與驗證界線 |
|---|---|---|---|
| 原生導覽與偏好 | 十個主要 CLI 功能頁、繁中／英文、系統／淺／深色、快捷鍵、原生 Liquid Glass | `Sources/MoPanelApp/` | 自有 UI；不是官方付費 App 畫面或素材。VoiceOver、Retina、全按鈕尚須真 Mac 完整驗收 |
| 原生資料頁 | Status 圖表、App 清單、Analyze 層級圖、History 搜尋與內容 | `DashboardView.swift`、`UninstallView.swift`、`AnalyzeView.swift`、`HistoryView.swift` | 資料來自正式 CLI；圖表不是新掃描引擎。某些操作仍進官方 PTY |
| CLI 探索 | Homebrew／官方腳本／PATH／自訂路徑、symlink 與實際資源位置判斷 | `MoleDiscovery.swift`、`CLIProbe.swift` | 來源不明或身分無法確認時失敗，不隨意回退到另一個執行檔 |
| 相容層 | 版本、正式 help 契約、JSON 型別、未知掃描狀態檢查；更新後重新探測 | `Compatibility.swift`、`MoleCommand.swift`、`MoleModels.swift` | 是介面相容性檢查，不是對所有未來 CLI 核心行為的保證 |
| Nightly／dev 復原入口 | 合條件的官方腳本安裝可以確認後回到 stable | `Compatibility.swift`、`SettingsView.swift` | 實際更新仍由官方 `mo update`；不將 Homebrew HEAD 冒充可直接切 stable，不寫自己的更新引擎 |
| 破壞性操作確認 | 執行前說明範圍、永久刪除／垃圾桶影響、保留官方二次確認 | `AppModel.swift`、`ContentView.swift` | 不代替官方路徑驗證；取消不能復原已經刪除的資料 |
| 內嵌互動終端 | 使用按鈕與鍵盤操作官方 TUI；不必自行組 shell 指令 | `Sources/MoPanelTerminal/TerminalPanel.swift` | 使用 MIT 授權 SwiftTerm 1.20.0。它是正式備援操作介面，不宣稱原生逐項計畫已完成 |
| 程序執行與輸出限制 | 安全 argv、受控環境變數、逾時、非零退出、bounded output、單一 Watch | `Sources/MoPanelProcess/ManagedProcess.swift` | 不使用 shell 拼接使用者參數；不記錄輸入。互動輸出是否 echo 由終端／CLI 控制，密碼遵循原 sudo 的無 echo 流程 |
| 程序生命週期 guardian | GUI 消失後處理其所啟動程序；正常取消與逾時有訊號策略 | `Sources/MoPanelGuardian/main.c` | 非 root、非常駐安裝服務。Slim 實際替換階段採合作式取消，不保證兩秒強殺；可能等官方安全邊界後退出 |
| Purge 原生路徑編輯器 | 加入資料夾、編輯／儲存／取消，不必操作 vim | `Sources/MoPanelEditor/main.swift`、`PurgePathsDocument.swift` | 透過官方 `EDITOR` 擴充點。限制正式使用者設定檔、擋 symlink、容量上限、檢查外部修改；不是修改掃描引擎 |
| 操作紀錄與匯出 | 查看入口與結果；非互動輸出可匯出，互動作業只匯出執行摘要 | `OperationExport.swift`、`AppModel.swift`、`SettingsView.swift` | 不記錄鍵盤／密碼輸入，不保留完整 PTY 逐字日誌。互動內容只在終端有限回捲；Mole 自己的可用歷史另列。含路徑的非互動輸出由使用者決定是否匯出 |
| 權限與安裝引導 | 缺 CLI、無 FDA、來源不明、相容性錯誤、官方安裝及更新入口 | `SettingsView.swift`、`CLIProbe.swift` | 不代替系統授權，不偷偷下載執行腳本，不停用 Gatekeeper |
| Keep Awake | 原生顯示／系統閒置喚醒、可選時限、低電量暫停、接電續行、停止／睡眠／退出釋放 | `SystemToolsController.swift`、`SystemToolsPolicy.swift` | **MoPanel 新實作**，使用 IOPMAssertion；不保證關蓋、不跨重啟恢復、不改 pmset。7 個政策測試通過；IOKit 實機 smoke 待 CI |
| Clean Screen | 原生多螢幕純色遮罩、Esc／按鈕／切換 App／5分鐘保底退出 | `SystemToolsController.swift`、`SystemToolsView.swift` | **MoPanel 新實作**，沒有全域輸入鎖，不需要輔助使用授權；尚待 AppKit 實際事件與多螢幕驗收 |
| 外接磁碟退出 | 讀掛載中繼資料、保護根／內建／家目錄／App 所在磁碟、確認後交給 NSWorkspace | `SystemToolsController.swift`、`SystemToolsPolicy.swift` | **MoPanel 新實作**，無強制退出；純政策已測，CI 不退出任何真實 volume |
| Doctor 唯讀報告 | 明確來源的 OS／硬體／電源／顯示器／磁碟中繼資料，可複製或儲存 | `SystemToolsController.swift`、`SystemToolsView.swift` | **MoPanel 新實作**；不掃描目錄內容、不探測私人檔案，不知道的 FDA／安全狀態明示未檢查，非官方完整 Doctor |
| App Updates | Homebrew 結構化版本、官方預覽、逐項確認、計畫重驗及結果；其他 App 來源辨識與 handoff | `AppUpdatesController.swift`、`AppUpdatesView.swift`、`AppUpdateModels.swift` | **MoPanel 新實作**；直接更新僅符合安全條件的一般官方 cask。Sparkle／App Store 不代管下載安裝；詳見 APP_UPDATES.md |
| Startup | 有界 plist 清單、搜尋、來源、實際狀態、受保護 user LaunchAgent 預覽與確認 | `StartupController.swift`、`StartupView.swift`、`StartupModels.swift` | **MoPanel 新實作**；不刪 plist、不用 sudo、不讀私有 BTM DB；系統與其他登入項目交由系統設定。14項Core測試與隔離mock流程，真Mac結果以Reports為準 |
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
| AI session／worktree／閒置工具處理 | MoPanel 額外工具整合；對話索引、保留副本、Git 未提交／獨有內容與使用中資料不能靠猜測 |
| Menu Bar、程序控制、Doctor 擴充 | MoPanel UI／診斷／系統整合；按需工作，程序操作要重新驗證身分。Doctor 基礎報告已有實作，官方完整條件集合仍未完成 |
| Keep Screen On／Clean Screen 的完整對等與隱私提醒 | Keep Awake、基本遮罩與裝置退出已新增；閉蓋、跨重啟恢復、全域輸入保護及隱私訊號仍未完成，不能把基礎版本稱為完全對等 |
| 風扇模式、Battery Care、AWDL | MoPanel 新硬體／系統控制，已在最新需求範圍內；需要受支援硬體、窄授權、狀態讀回與故障恢復，不放置假控制項 |
| Parallels 磁碟回收 | 透過 Parallels 官方工具整合；需要關機 VM、可辨識磁碟與不中斷保護 |

這些模組不能承諾只靠未來更新 Mole CLI 就自動獲得。Mole CLI 與 MoPanel 新增的原生／第三方整合各有自己的相容性與更新責任。

## 沒有做的事

目前沒有自建清理規則引擎、沒有用磁碟大就認定垃圾、沒有自動清空垃圾桶、沒有修改官方 Mole 已安裝原始碼、沒有建立預設 LaunchAgent／Login Item、沒有操作 BuhoCleaner 的設定或資料庫，也沒有複製官方付費 GUI 的私有程式碼、圖示或商標。

新增對等功能後，也必須維持來源透明：官方 CLI 的結果標示來自 Mole；原生系統 API 的結果標示來源；缺少支援就顯示不可用，不作估造。

